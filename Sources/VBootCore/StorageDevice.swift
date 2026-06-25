import Foundation

public enum DeviceClassification: String, Sendable, Codable {
    case systemDisk
    case internalDisk
    case externalRemovable
    case externalFixed
    case unknown

    public var label: String {
        switch self {
        case .systemDisk: return "SYSTEM DISK"
        case .internalDisk: return "Internal disk"
        case .externalRemovable: return "External / removable"
        case .externalFixed: return "External (fixed)"
        case .unknown: return "Unknown"
        }
    }
}

public struct StorageDevice: Sendable, Identifiable, Hashable, Codable {
    public var id: String { bsdName }

    public let bsdName: String
    public let devicePath: String
    public let rawDevicePath: String

    public let mediaName: String?
    public let vendor: String?
    public let model: String?

    public let sizeBytes: UInt64
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isWritable: Bool
    public let busProtocol: String?

    public let classification: DeviceClassification

    public init(
        bsdName: String,
        devicePath: String,
        rawDevicePath: String,
        mediaName: String?,
        vendor: String?,
        model: String?,
        sizeBytes: UInt64,
        isInternal: Bool,
        isRemovable: Bool,
        isEjectable: Bool,
        isWritable: Bool,
        busProtocol: String?,
        classification: DeviceClassification
    ) {
        self.bsdName = bsdName
        self.devicePath = devicePath
        self.rawDevicePath = rawDevicePath
        self.mediaName = mediaName
        self.vendor = vendor
        self.model = model
        self.sizeBytes = sizeBytes
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isWritable = isWritable
        self.busProtocol = busProtocol
        self.classification = classification
    }

    public var isWriteEligible: Bool {
        guard isWritable else { return false }
        switch classification {
        case .externalRemovable, .externalFixed:
            return true
        case .systemDisk, .internalDisk, .unknown:
            return false
        }
    }

    public var requiresExtraConfirmation: Bool {
        classification == .externalFixed
    }

    public var displayName: String {
        let name = [vendor, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let base = name.isEmpty ? (mediaName ?? bsdName) : name
        return "\(base) — \(ByteFormat.humanize(sizeBytes))"
    }
}
