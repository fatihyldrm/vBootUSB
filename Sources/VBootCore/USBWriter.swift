import Foundation
import CryptoKit

public final class USBWriter {

    public typealias ProgressHandler = (WriteProgress) -> Void

    private let bufferSize = 8 * 1024 * 1024

    public init() {}

    public static var isRoot: Bool { geteuid() == 0 }

    public func unmountDisk(_ device: StorageDevice) throws {
        let r = Shell.run("/usr/sbin/diskutil", ["unmountDisk", "force", device.devicePath])
        guard r.ok else {
            throw VBootError("Could not unmount disk (\(device.devicePath)): \(r.stderr.isEmpty ? r.stdout : r.stderr)")
        }
    }

    public func writeDD(sourcePath: String, totalBytes: UInt64, device: StorageDevice, progress: ProgressHandler) throws {
        let total = totalBytes
        guard total > 0 else { throw VBootError("Unknown source size: \(sourcePath)") }
        guard total <= device.sizeBytes else {
            throw VBootError("ISO (\(ByteFormat.humanize(total))) is larger than the target device (\(ByteFormat.humanize(device.sizeBytes))).")
        }

        try unmountDisk(device)

        let inFD = open(sourcePath, O_RDONLY)
        guard inFD >= 0 else { throw VBootError("Could not open source: \(sourcePath) (errno \(errno))") }
        defer { close(inFD) }

        let outFD = open(device.rawDevicePath, O_WRONLY)
        guard outFD >= 0 else {
            throw VBootError("Could not open raw device: \(device.rawDevicePath) — root may be required (errno \(errno))")
        }
        defer { close(outFD) }
        _ = fcntl(outFD, F_NOCACHE, 1)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 4096)
        defer { buffer.deallocate() }

        var written: UInt64 = 0
        let start = Date()
        var lastReport = start

        while written < total {
            let n = read(inFD, buffer, bufferSize)
            if n < 0 { throw VBootError("Source read error (errno \(errno))") }
            if n == 0 { break }
            let use = Int(min(UInt64(n), total - written))
            var off = 0
            while off < use {
                let w = write(outFD, buffer.advanced(by: off), use - off)
                if w <= 0 { throw VBootError("Device write error (errno \(errno)) — after writing \(ByteFormat.humanize(written))") }
                off += w
            }
            written += UInt64(use)

            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.5 || written >= total {
                let elapsed = now.timeIntervalSince(start)
                let bps = elapsed > 0 ? Double(written) / elapsed : 0
                progress(WriteProgress(phase: "Writing", bytesDone: written, bytesTotal: total, bytesPerSec: bps))
                lastReport = now
            }
        }

        if fsync(outFD) != 0 {
            throw VBootError("fsync failed (errno \(errno))")
        }
    }

    public func verifyDD(sourcePath: String, totalBytes: UInt64, device: StorageDevice, progress: ProgressHandler) throws -> Bool {
        let isoHash = try sha256(ofPath: sourcePath, length: totalBytes, phase: "Verifying (source)", progress: progress)
        let devHash = try sha256(ofPath: device.rawDevicePath, length: totalBytes, phase: "Verifying (target)", progress: progress)
        return isoHash == devHash
    }

    private func sha256(ofPath path: String, length: UInt64, phase: String, progress: ProgressHandler) throws -> String {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw VBootError("Could not open for reading: \(path) (errno \(errno))") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 4096)
        defer { buffer.deallocate() }

        var hasher = SHA256()
        var done: UInt64 = 0
        let start = Date()
        var lastReport = start

        while done < length {
            let want = Int(min(UInt64(bufferSize), length - done))
            let toRead = (path.hasPrefix("/dev/")) ? bufferSize : want
            let n = read(fd, buffer, toRead)
            if n < 0 { throw VBootError("Verification read error (\(path), errno \(errno))") }
            if n == 0 { break }
            let use = min(n, want)
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: use))
            done += UInt64(use)

            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.5 || done >= length {
                let elapsed = now.timeIntervalSince(start)
                let bps = elapsed > 0 ? Double(done) / elapsed : 0
                progress(WriteProgress(phase: phase, bytesDone: done, bytesTotal: length, bytesPerSec: bps))
                lastReport = now
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func writeFileCopy(isoPath: String, analysis: ISOAnalysis, device: StorageDevice,
                              scheme: PartitionScheme = .mbr, fileSystem: FileSystemType = .fat32,
                              label: String = "VBOOTUSB", preMountedSource: String? = nil,
                              progress: ProgressHandler) throws {
        let dest = try partitionAndFormat(device: device, scheme: scheme, fileSystem: fileSystem,
                                          label: label, progress: progress)
        let src: String
        var ownMount: MountedImage? = nil
        if let pm = preMountedSource {
            src = pm
        } else {
            let mounted = try ISOMounter.attach(isoPath: isoPath)
            ownMount = mounted
            guard let s = ISOAnalyzer.primaryMountPoint(mounted.mountPoints) else {
                throw VBootError("ISO content root not found")
            }
            src = s
        }
        defer { if let m = ownMount { ISOMounter.detach(m) } }

        try copyContents(fromMount: src, toMount: dest, isWindows: analysis.type == .windows,
                         installImageSize: analysis.installImageSizeBytes, fileSystem: fileSystem,
                         totalBytes: analysis.sizeBytes, progress: progress)
        Shell.run("/usr/sbin/diskutil", ["eject", device.devicePath])
    }

    public func partitionAndFormat(device: StorageDevice, scheme: PartitionScheme,
                                   fileSystem: FileSystemType, label: String,
                                   progress: ProgressHandler) throws -> String {
        progress(WriteProgress(phase: "Unmounting disk", bytesDone: 0, bytesTotal: 1, bytesPerSec: 0))
        try unmountDisk(device)
        progress(WriteProgress(phase: "Partitioning (\(fileSystem.rawValue))", bytesDone: 0, bytesTotal: 1, bytesPerSec: 0))
        let part = try partition(device: device, scheme: scheme, fileSystem: fileSystem,
                                 label: Self.sanitizeLabel(label, fileSystem: fileSystem))
        return try mountPoint(ofPartition: part)
    }

    public func copyContents(fromMount src: String, toMount dest: String, isWindows: Bool,
                             installImageSize: UInt64?, fileSystem: FileSystemType,
                             totalBytes: UInt64, progress: ProgressHandler) throws {
        let needSplit = fileSystem == .fat32 && isWindows && (installImageSize ?? 0) > fat32MaxFileSize
        var excludes: [String] = []
        if needSplit { excludes = ["sources/install.wim", "sources/install.esd"] }

        try copyTreeWithProgress(from: src, to: dest, excludes: excludes, totalBytes: totalBytes, progress: progress)

        if needSplit {
            progress(WriteProgress(phase: "Splitting install.wim", bytesDone: totalBytes, bytesTotal: totalBytes, bytesPerSec: 0))
            try splitInstallImage(srcRoot: src, destRoot: dest)
        }
        progress(WriteProgress(phase: "Flushing", bytesDone: totalBytes, bytesTotal: totalBytes, bytesPerSec: 0))
        Shell.run("/bin/sync", [])
    }

    func copyTreeWithProgress(from src: String, to dest: String, excludes: [String],
                              totalBytes: UInt64, progress: ProgressHandler) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        var args = ["-rlt", "--no-perms", "--no-owner", "--no-group"]
        for ex in excludes { args.append("--exclude=\(ex)") }
        args.append(src.hasSuffix("/") ? src : src + "/")
        args.append(dest.hasSuffix("/") ? dest : dest + "/")
        p.arguments = args
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        do { try p.run() } catch { throw VBootError("Could not start rsync: \(error)") }

        let base = Self.usedBytes(dest)
        var peak: UInt64 = 0
        let start = Date()
        while p.isRunning {
            let used = Self.usedBytes(dest)
            let raw = used > base ? used - base : 0
            if raw > peak { peak = raw }
            let copied = peak
            let elapsed = Date().timeIntervalSince(start)
            let bps = elapsed > 0.2 ? Double(copied) / elapsed : 0
            let speed = bps > 0 ? " · \(ByteFormat.humanize(UInt64(bps)))/s" : ""
            progress(WriteProgress(phase: "Copying files\(speed)", bytesDone: copied, bytesTotal: totalBytes, bytesPerSec: bps))
            usleep(300_000)
        }
        p.waitUntilExit()
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard [0, 23, 24].contains(p.terminationStatus) else {
            throw VBootError("Copy failed (rsync \(p.terminationStatus)): \(err)")
        }
    }

    static func usedBytes(_ path: String) -> UInt64 {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return 0 }
        let total = UInt64(s.f_blocks) * UInt64(s.f_bsize)
        let free = UInt64(s.f_bfree) * UInt64(s.f_bsize)
        return total > free ? total - free : 0
    }

    func partition(device: StorageDevice, scheme: PartitionScheme,
                   fileSystem: FileSystemType, label: String) throws -> String {
        let r = Shell.run("/usr/sbin/diskutil",
                          ["partitionDisk", device.devicePath, scheme.rawValue,
                           fileSystem.diskutilPersonality, label, "100%"])
        guard r.ok else {
            throw VBootError("Partitioning failed: \(r.stderr.isEmpty ? r.stdout : r.stderr)")
        }
        return device.devicePath + (scheme == .gpt ? "s2" : "s1")
    }

    static func sanitizeLabel(_ raw: String, fileSystem: FileSystemType) -> String {
        var s = raw.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        if s.isEmpty { s = "VBOOTUSB" }
        return String(s.prefix(fileSystem.maxLabel))
    }

    func mountPoint(ofPartition part: String) throws -> String {
        Shell.run("/usr/sbin/diskutil", ["mount", part])
        let r = Shell.run("/usr/sbin/diskutil", ["info", "-plist", part])
        guard r.ok, let data = r.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            throw VBootError("Could not get partition info: \(part)")
        }
        if let mp = dict["MountPoint"] as? String, !mp.isEmpty { return mp }
        throw VBootError("Partition mount point not found: \(part)")
    }

    func copyTree(from src: String, to dest: String, excludes: [String]) throws {
        var args = ["-rlt", "--no-perms", "--no-owner", "--no-group"]
        for ex in excludes { args.append("--exclude=\(ex)") }
        args.append(src.hasSuffix("/") ? src : src + "/")
        args.append(dest.hasSuffix("/") ? dest : dest + "/")
        let r = Shell.run("/usr/bin/rsync", args)
        guard r.exitCode == 0 || r.exitCode == 23 || r.exitCode == 24 else {
            throw VBootError("Copy failed (rsync \(r.exitCode)): \(r.stderr)")
        }
    }

    func splitInstallImage(srcRoot: String, destRoot: String) throws {
        guard let wimlib = Shell.which("wimlib-imagex") else {
            throw VBootError("""
            install.wim is larger than 4 GB and does not fit on FAT32. wimlib is required to split it but was not found.
            Install: 'brew install wimlib' (Homebrew) or build from source.
            Alternative: exFAT mode (later phase) or an ISO with a smaller install.esd.
            """)
        }
        guard let wim = ISOAnalyzer.find(srcRoot, ["sources", "install.wim"])
                ?? ISOAnalyzer.find(srcRoot, ["sources", "install.esd"]) else {
            throw VBootError("install.wim/.esd not found in source ISO")
        }
        let outDir = destRoot + "/sources"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let r = Shell.run(wimlib, ["split", wim, outDir + "/install.swm", "3800"])
        guard r.ok else {
            throw VBootError("wimlib split failed: \(r.stderr.isEmpty ? r.stdout : r.stderr)")
        }
    }
}
