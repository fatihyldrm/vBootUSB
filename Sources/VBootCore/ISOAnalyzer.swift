import Foundation

public struct MountedImage: Sendable {
    public let devEntry: String
    public let mountPoints: [String]
}

public enum ISOMounter {
    public static func attach(isoPath: String) throws -> MountedImage {
        let r = Shell.run("/usr/bin/hdiutil",
                          ["attach", "-nobrowse", "-readonly", "-noverify", "-plist", isoPath])
        guard r.ok else {
            throw VBootError("Failed to mount ISO (hdiutil): \(r.stderr.isEmpty ? r.stdout : r.stderr)")
        }
        guard let data = r.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else {
            throw VBootError("Failed to parse hdiutil plist output")
        }

        var mountPoints: [String] = []
        var devEntries: [String] = []
        for e in entities {
            if let dev = e["dev-entry"] as? String { devEntries.append(dev) }
            if let mp = e["mount-point"] as? String, !mp.isEmpty { mountPoints.append(mp) }
        }
        let whole = devEntries.min(by: { $0.count < $1.count }) ?? devEntries.first ?? ""
        guard !whole.isEmpty else { throw VBootError("No mounted device found") }
        return MountedImage(devEntry: whole, mountPoints: mountPoints)
    }

    public static func detach(_ image: MountedImage) {
        Shell.run("/usr/bin/hdiutil", ["detach", image.devEntry, "-force"])
    }
}

public struct ISOAnalyzer {
    public init() {}

    public func analyze(path: String) throws -> ISOAnalysis {
        guard FileManager.default.fileExists(atPath: path) else {
            throw VBootError("ISO not found: \(path)")
        }
        let size = Self.fileSize(path)
        let hybrid = Self.detectHybrid(path: path)

        let mounted = try ISOMounter.attach(isoPath: path)
        defer { ISOMounter.detach(mounted) }

        let root = Self.primaryMountPoint(mounted.mountPoints)
        guard let root else {
            throw VBootError("ISO mounted but no readable filesystem found")
        }

        let hasWim = Self.find(root, ["sources", "install.wim"]) != nil
        let hasEsd = Self.find(root, ["sources", "install.esd"]) != nil
        let hasBootmgr = Self.find(root, ["bootmgr"]) != nil || Self.find(root, ["bootmgr.efi"]) != nil
        let hasBootCfg = Self.find(root, ["boot.cfg"]) != nil
        let hasMboot = Self.find(root, ["mboot.c32"]) != nil || Self.find(root, ["efi", "boot", "boot.cfg"]) != nil
        let uefiBoot = Self.find(root, ["efi", "boot", "bootx64.efi"]) != nil
            || Self.find(root, ["efi", "boot", "bootia32.efi"]) != nil

        var type: ISOType = .unknown
        var notes: [String] = []
        var installSize: UInt64? = nil

        if hasWim || hasEsd || hasBootmgr {
            type = .windows
            if let wim = Self.find(root, ["sources", "install.wim"]) {
                installSize = Self.fileSize(wim)
            } else if let esd = Self.find(root, ["sources", "install.esd"]) {
                installSize = Self.fileSize(esd)
            }
            if let s = installSize, s > fat32MaxFileSize {
                notes.append("install image \(ByteFormat.humanize(s)) > 4 GB — will be split with wimlib for FAT32 (.swm).")
            }
        } else if hasBootCfg && (hasMboot || uefiBoot) {
            type = .esxi
            notes.append("ESXi: default file-copy (FAT32 + EFI/BOOT + boot.cfg). DD also works on most versions.")
        } else if Self.find(root, ["casper"]) != nil || Self.find(root, ["live"]) != nil
                    || Self.find(root, ["arch"]) != nil || Self.find(root, ["isolinux"]) != nil
                    || Self.find(root, ["boot", "grub"]) != nil || Self.find(root, [".disk"]) != nil {
            type = .linux
        }

        let mode: WriteMode
        switch type {
        case .windows:
            mode = .fileCopy
            notes.append("Windows does NOT boot via DD — file-copy is required.")
        case .esxi:
            mode = .fileCopy
        case .linux:
            mode = hybrid ? .dd : .fileCopy
            if !hybrid { notes.append("No isohybrid signature; file-copy recommended.") }
        case .unknown:
            mode = hybrid ? .dd : .fileCopy
            notes.append("Type could not be determined; \(hybrid ? "isohybrid signature present, DD" : "no signature, file-copy") recommended.")
        }

        if !uefiBoot { notes.append("WARNING: /EFI/BOOT/BOOTX64.EFI not found — UEFI boot may be unreliable.") }

        return ISOAnalysis(
            path: path, sizeBytes: size, type: type, isHybrid: hybrid,
            hasUEFIBootloader: uefiBoot, installImageSizeBytes: installSize,
            recommendedMode: mode, notes: notes
        )
    }

    public static func fileSize(_ path: String) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)??.uint64Value ?? 0
    }

    public static func primaryMountPoint(_ points: [String]) -> String? {
        let fm = FileManager.default
        return points.max(by: { a, b in
            let ca = (try? fm.contentsOfDirectory(atPath: a).count) ?? 0
            let cb = (try? fm.contentsOfDirectory(atPath: b).count) ?? 0
            return ca < cb
        })
    }

    public static func find(_ root: String, _ components: [String]) -> String? {
        let fm = FileManager.default
        var current = root
        for comp in components {
            guard let entries = try? fm.contentsOfDirectory(atPath: current) else { return nil }
            guard let match = entries.first(where: { $0.caseInsensitiveCompare(comp) == .orderedSame }) else {
                return nil
            }
            current += "/" + match
        }
        return current
    }

    static func detectHybrid(path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let mbr = try? fh.read(upToCount: 512), mbr.count == 512 else { return false }
        let bytes = [UInt8](mbr)
        guard bytes[510] == 0x55, bytes[511] == 0xAA else { return false }
        for i in 0..<4 {
            let base = 446 + i * 16
            let type = bytes[base + 4]
            let sizeLE = UInt32(bytes[base + 12]) | (UInt32(bytes[base + 13]) << 8)
                       | (UInt32(bytes[base + 14]) << 16) | (UInt32(bytes[base + 15]) << 24)
            if sizeLE > 0 || type == 0xEE {
                return true
            }
        }
        return false
    }
}
