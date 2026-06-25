import Foundation
import VBootCore

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : "help"
let progressFilePath: String? = {
    guard let i = arguments.firstIndex(of: "--progress-file"), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}()

switch command {
case "list":
    runList(showAll: hasFlag("--all"), asJSON: hasFlag("--json"))
case "inspect":
    runInspect(isoPath: positional(after: "inspect"))
case "write":
    runWrite()
case "format":
    runFormat()
case "help", "-h", "--help":
    printUsage()
default:
    stderr("Unknown command: \(command)\n")
    printUsage()
    exit(2)
}

func runList(showAll: Bool, asJSON: Bool) {
    let devices = DiskEnumerator().enumerateDevices()
    let visible = showAll
        ? devices
        : devices.filter { $0.classification != .systemDisk && $0.classification != .internalDisk }

    if asJSON {
        emitJSON(visible); return
    }
    if visible.isEmpty {
        print("No writable external device found. (For all: vbootusb list --all)")
        return
    }
    print("\n  vBootUSB — Device list\(showAll ? " (ALL)" : "")")
    print("  " + String(repeating: "─", count: 78))
    for d in visible {
        let marker = d.isWriteEligible ? "✓" : "⛔"
        let warn = d.requiresExtraConfirmation ? "  ⚠ extra confirmation" : ""
        print("  \(marker) \(d.bsdName)   \(d.displayName)")
        print("       Class: \(d.classification.label)   Bus: \(d.busProtocol ?? "?")\(warn)")
        print("       Raw device: \(d.rawDevicePath)   Writable: \(d.isWritable ? "yes" : "no")")
        print("  " + String(repeating: "─", count: 78))
    }
    let eligible = visible.filter { $0.isWriteEligible }.count
    print("  \(visible.count) device(s), \(eligible) write-eligible (✓). ⛔ = system/internal, never written.\n")
}

func runInspect(isoPath: String?) {
    guard let isoPath else { stderr("Usage: vbootusb inspect <iso>\n"); exit(2) }
    do {
        let a = try ISOAnalyzer().analyze(path: isoPath)
        print("\n  ISO Analysis: \(a.path)")
        print("  " + String(repeating: "─", count: 60))
        print("  Size           : \(ByteFormat.humanize(a.sizeBytes))")
        print("  Type           : \(a.type.label)")
        print("  isohybrid (DD) : \(a.isHybrid ? "yes" : "no")")
        print("  UEFI boot      : \(a.hasUEFIBootloader ? "/EFI/BOOT/BOOTX64.EFI present" : "none")")
        if let w = a.installImageSizeBytes {
            print("  install image  : \(ByteFormat.humanize(w))\(w > fat32MaxFileSize ? "  (>4GB — wim-split required)" : "")")
        }
        print("  RECOMMENDED MODE: \(a.recommendedMode.label)")
        if !a.notes.isEmpty {
            print("  Notes:")
            for n in a.notes { print("    • \(n)") }
        }
        print("")
    } catch {
        stderr("Analysis error: \(error)\n"); exit(1)
    }
}

func markProgress(_ fraction: Double, _ phase: String) {
    if let pf = progressFilePath {
        try? "\(fraction)|\(phase)".write(toFile: pf, atomically: true, encoding: .utf8)
    }
}

func runFormat() {
    guard let devArg = option("--device") else { stderr("--device diskN required\n"); exit(2) }
    let bsd = devArg.hasPrefix("/dev/") ? String(devArg.dropFirst(5)) : devArg
    let scheme = PartitionScheme(rawValue: (option("--scheme") ?? "mbr").uppercased()) ?? .mbr
    let fsRaw = (option("--filesystem") ?? "fat32").lowercased()
    let fs: FileSystemType = (fsRaw == "exfat") ? .exfat : .fat32
    let label = option("--label") ?? "VBOOTUSB"
    markProgress(0.05, "Verifying device")
    guard let device = DiskEnumerator().enumerateDevices().first(where: { $0.bsdName == bsd }) else {
        stderr("Device not found: \(bsd)\n"); exit(1)
    }
    guard device.isWriteEligible else {
        stderr("⛔ REFUSED: \(device.bsdName) is not write-eligible (\(device.classification.label)).\n"); exit(1)
    }
    if hasFlag("--dry-run") { print("(dry-run) would format \(device.bsdName) as \(scheme.rawValue)+\(fs.rawValue)"); return }
    guard USBWriter.isRoot else { stderr("root required\n"); exit(1) }
    guard hasFlag("--yes") else { stderr("--yes required\n"); exit(1) }
    do {
        let mount = try USBWriter().partitionAndFormat(device: device, scheme: scheme,
                                                       fileSystem: fs, label: label, progress: renderProgress)
        finishLine()
        Shell.run("/bin/sync", [])
        print("\nMOUNT:\(mount)")
    } catch {
        finishLine(); stderr("  ❌ ERROR: \(error)\n"); exit(1)
    }
}

func runWrite() {
    guard let devArg = option("--device") else { stderr("--device diskN required\n"); exit(2) }
    markProgress(0.01, "Verifying device")
    let isoPath = option("--iso")
    let sourceDevice = option("--source-device")
    let sourceMount = option("--source-mount")
    let sourceSize = option("--source-size").flatMap { UInt64($0) }
    let typeArg = option("--type")
    let bsd = devArg.hasPrefix("/dev/") ? String(devArg.dropFirst(5)) : devArg
    let dryRun = hasFlag("--dry-run")
    let assumeYes = hasFlag("--yes")
    let doVerify = !hasFlag("--no-verify")
    let hasExternalSource = sourceDevice != nil || sourceMount != nil
    let isoDisplay = isoPath ?? sourceMount ?? sourceDevice ?? "(source)"

    guard isoPath != nil || hasExternalSource else {
        stderr("--iso <path> or --source-device/--source-mount required\n"); exit(2)
    }

    guard let device = DiskEnumerator().enumerateDevices().first(where: { $0.bsdName == bsd }) else {
        stderr("Device not found: \(bsd). Check with 'vbootusb-cli list --all'.\n"); exit(1)
    }
    guard device.isWriteEligible else {
        stderr("⛔ REFUSED: \(device.bsdName) is not write-eligible (\(device.classification.label)). System/internal disks are never written.\n")
        exit(1)
    }

    let analysis: ISOAnalysis
    if hasExternalSource {
        let type = ISOType(rawValue: typeArg ?? "") ?? .unknown
        var installSize: UInt64? = nil
        if let sm = sourceMount,
           let wim = ISOAnalyzer.find(sm, ["sources", "install.wim"]) ?? ISOAnalyzer.find(sm, ["sources", "install.esd"]) {
            installSize = ISOAnalyzer.fileSize(wim)
        }
        let total = sourceSize ?? (isoPath.map { ISOAnalyzer.fileSize($0) } ?? 0)
        analysis = ISOAnalysis(path: isoDisplay, sizeBytes: total, type: type, isHybrid: false,
                               hasUEFIBootloader: true, installImageSizeBytes: installSize,
                               recommendedMode: .dd, notes: [])
    } else {
        markProgress(0.03, "Inspecting ISO")
        do { analysis = try ISOAnalyzer().analyze(path: isoPath!) }
        catch { stderr("ISO analysis error: \(error)\n"); exit(1) }
    }

    let mode: WriteMode
    if let m = option("--mode") {
        guard let parsed = WriteMode(rawValue: m == "filecopy" ? "fileCopy" : m) else {
            stderr("--mode must be dd|filecopy\n"); exit(2)
        }
        mode = parsed
    } else {
        mode = analysis.recommendedMode
    }

    print("\n  ════════════ WRITE PLAN ════════════")
    print("  Source  : \(isoDisplay)  (\(analysis.type.label), \(ByteFormat.humanize(analysis.sizeBytes)))")
    print("  TARGET  : \(device.bsdName) — \(device.displayName)")
    print("  Raw path: \(device.rawDevicePath)")
    print("  MODE    : \(mode.label)\(option("--mode") == nil ? " (automatic)" : "")")
    for n in analysis.notes { print("  • \(n)") }
    print("  ⚠️  ALL DATA ON THE TARGET WILL BE ERASED.")
    print("  ═════════════════════════════════════\n")

    if dryRun { print("(--dry-run: nothing was written.)"); return }

    if !USBWriter.isRoot {
        stderr("This operation requires root.\n"); exit(1)
    }
    guard assumeYes else {
        stderr("Add --yes to confirm (destructive operation).\n"); exit(1)
    }

    let writer = USBWriter()
    do {
        switch mode {
        case .dd:
            let srcPath = sourceDevice ?? isoPath!
            let total = sourceSize ?? (isoPath.map { ISOAnalyzer.fileSize($0) } ?? 0)
            try writer.writeDD(sourcePath: srcPath, totalBytes: total, device: device, progress: renderProgress)
            finishLine()
            if doVerify {
                let ok = try writer.verifyDD(sourcePath: srcPath, totalBytes: total, device: device, progress: renderProgress)
                finishLine()
                if ok { print("  ✅ Verification SUCCEEDED — written data matches the source exactly.") }
                else { stderr("  ❌ Verification FAILED — hash mismatch! Do not use the USB.\n"); exit(3) }
            }
            Shell_eject(device)
        case .fileCopy:
            let scheme = PartitionScheme(rawValue: (option("--scheme") ?? "mbr").uppercased()) ?? .mbr
            let fsRaw = (option("--filesystem") ?? "fat32").lowercased()
            let fs: FileSystemType = (fsRaw == "exfat") ? .exfat : .fat32
            let label = option("--label") ?? "VBOOTUSB"
            try writer.writeFileCopy(isoPath: isoPath ?? "", analysis: analysis, device: device,
                                     scheme: scheme, fileSystem: fs, label: label,
                                     preMountedSource: sourceMount, progress: renderProgress)
            finishLine()
            print("  ✅ Files copied and USB prepared (\(scheme.rawValue) + \(fs.rawValue)).")
        }
        print("  🎉 Done: \(device.bsdName) is now bootable.\n")
    } catch {
        finishLine()
        stderr("  ❌ ERROR: \(error)\n"); exit(1)
    }
}

func renderProgress(_ p: WriteProgress) {
    let width = 28
    let filled = Int(p.fraction * Double(width))
    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    let pct = Int(p.fraction * 100)
    let speed = p.bytesPerSec > 0 ? "\(ByteFormat.humanize(UInt64(p.bytesPerSec)))/s" : "—"
    let eta = p.etaSeconds.map { fmtETA($0) } ?? "—"
    let line = "  [\(bar)] \(pct)%  \(speed)  ETA \(eta)  \(p.phase)"
    let padded = line.padding(toLength: 90, withPad: " ", startingAt: 0)
    FileHandle.standardOutput.write(Data(("\r" + padded).utf8))
    if let pf = progressFilePath {
        let speed = p.bytesPerSec > 0 ? " · \(ByteFormat.humanize(UInt64(p.bytesPerSec)))/s" : ""
        try? "\(p.fraction)|\(p.phase)\(speed)".write(toFile: pf, atomically: true, encoding: .utf8)
    }
}
func finishLine() {
    FileHandle.standardOutput.write(Data(("\r" + String(repeating: " ", count: 90) + "\r").utf8))
}
func fmtETA(_ s: Double) -> String {
    let t = Int(s); return String(format: "%02d:%02d", t / 60, t % 60)
}

func hasFlag(_ f: String) -> Bool { arguments.contains(f) }
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
func positional(after cmd: String) -> String? {
    guard let i = arguments.firstIndex(of: cmd), i + 1 < arguments.count else { return nil }
    let v = arguments[i + 1]
    return v.hasPrefix("-") ? nil : v
}
func stderr(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }
func emitJSON(_ devices: [StorageDevice]) {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(devices), let s = String(data: data, encoding: .utf8) { print(s) }
    else { stderr("JSON encoding error\n"); exit(1) }
}
func Shell_eject(_ d: StorageDevice) { Shell.run("/usr/sbin/diskutil", ["eject", d.devicePath]) }

func printUsage() {
    print("""

    vbootusb — macOS boot USB tool

    COMMANDS:
      list [--all] [--json]                       List devices
      inspect <iso>                               Show ISO type + recommended mode
      write --iso <p> --device diskN [options]    Write to USB (root required)
      help

    WRITE OPTIONS:
      --mode dd|filecopy   Force mode (default: automatic based on ISO)
      --yes                Confirm destructive operation (required)
      --no-verify          Skip hash verification after DD
      --dry-run            Only show the plan, do not write

    EXAMPLE:
      vbootusb inspect ~/Downloads/ubuntu.iso
      sudo vbootusb write --iso ~/Downloads/ubuntu.iso --device disk4 --yes
      sudo vbootusb write --iso ~/Win11.iso --device disk4 --mode filecopy --yes

    SAFETY: System/internal disks can never be targets. The disk is unmounted before writing.
    """)
}
