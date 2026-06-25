import Foundation

public final class DiskEnumerator {

    public init() {}

    public func enumerateDevices() -> [StorageDevice] {
        let rootWhole = Self.rootWholeDisk()

        let listR = Shell.run("/usr/sbin/diskutil", ["list", "-plist"])
        guard listR.ok, let data = listR.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let wholes = dict["WholeDisks"] as? [String] else {
            return []
        }

        var devices: [StorageDevice] = []
        for bsd in wholes {
            if let dev = Self.info(bsd: bsd, rootWhole: rootWhole) { devices.append(dev) }
        }
        return devices.sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
    }

    public func writeEligibleDevices() -> [StorageDevice] {
        enumerateDevices().filter { $0.isWriteEligible }
    }

    static func info(bsd: String, rootWhole: String?) -> StorageDevice? {
        let r = Shell.run("/usr/sbin/diskutil", ["info", "-plist", bsd])
        guard r.ok, let data = r.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let d = plist as? [String: Any] else {
            return nil
        }

        let isInternal = (d["Internal"] as? Bool) ?? false
        let removable = (d["RemovableMedia"] as? Bool)
            ?? (d["Removable"] as? Bool)
            ?? (d["RemovableMediaOrExternalDevice"] as? Bool) ?? false
        let ejectable = (d["Ejectable"] as? Bool) ?? false
        let writable = (d["WritableMedia"] as? Bool) ?? true
        let size = (d["Size"] as? NSNumber)?.uint64Value
            ?? (d["TotalSize"] as? NSNumber)?.uint64Value ?? 0
        let media = (d["MediaName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proto = (d["BusProtocol"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let classification = DeviceClassifier.classify(
            bsdName: bsd, rootWholeDiskBSD: rootWhole,
            isInternal: isInternal, isRemovable: removable, isEjectable: ejectable
        )

        return StorageDevice(
            bsdName: bsd,
            devicePath: "/dev/\(bsd)",
            rawDevicePath: "/dev/r\(bsd)",
            mediaName: (media?.isEmpty ?? true) ? nil : media,
            vendor: nil,
            model: (media?.isEmpty ?? true) ? nil : media,
            sizeBytes: size,
            isInternal: isInternal,
            isRemovable: removable,
            isEjectable: ejectable,
            isWritable: writable,
            busProtocol: (proto?.isEmpty ?? true) ? nil : proto,
            classification: classification
        )
    }

    static func rootWholeDisk() -> String? {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return nil }
        let devNode = withUnsafeBytes(of: &fs.f_mntfromname) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        var bsd = devNode.hasPrefix("/dev/") ? String(devNode.dropFirst(5)) : devNode
        if let m = bsd.range(of: #"^disk[0-9]+"#, options: .regularExpression) {
            bsd = String(bsd[m])
        }
        return bsd.isEmpty ? nil : bsd
    }
}
