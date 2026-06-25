import Foundation

public struct VBootError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum ISOType: String, Sendable, Codable {
    case windows
    case esxi
    case linux
    case unknown

    public var label: String {
        switch self {
        case .windows: return "Windows"
        case .esxi: return "VMware ESXi"
        case .linux: return "Linux"
        case .unknown: return "Unknown"
        }
    }
}

public enum WriteMode: String, Sendable, Codable {
    case dd
    case fileCopy

    public var label: String {
        switch self {
        case .dd: return "DD (raw image)"
        case .fileCopy: return "File copy (FAT32)"
        }
    }
}

public struct ISOAnalysis: Sendable, Codable {
    public let path: String
    public let sizeBytes: UInt64
    public let type: ISOType
    public let isHybrid: Bool
    public let hasUEFIBootloader: Bool
    public let installImageSizeBytes: UInt64?
    public let recommendedMode: WriteMode
    public let notes: [String]

    public init(path: String, sizeBytes: UInt64, type: ISOType, isHybrid: Bool,
                hasUEFIBootloader: Bool, installImageSizeBytes: UInt64?,
                recommendedMode: WriteMode, notes: [String]) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.type = type
        self.isHybrid = isHybrid
        self.hasUEFIBootloader = hasUEFIBootloader
        self.installImageSizeBytes = installImageSizeBytes
        self.recommendedMode = recommendedMode
        self.notes = notes
    }
}

public struct WriteProgress: Sendable {
    public let phase: String
    public let bytesDone: UInt64
    public let bytesTotal: UInt64
    public let bytesPerSec: Double

    public var fraction: Double {
        bytesTotal == 0 ? 0 : min(1.0, Double(bytesDone) / Double(bytesTotal))
    }
    public var etaSeconds: Double? {
        guard bytesPerSec > 0, bytesTotal >= bytesDone else { return nil }
        return Double(bytesTotal - bytesDone) / bytesPerSec
    }
}

public let fat32MaxFileSize: UInt64 = 4_294_967_295

public enum PartitionScheme: String, Sendable, Codable, CaseIterable {
    case mbr = "MBR"
    case gpt = "GPT"
    public var targetSystem: String {
        switch self {
        case .mbr: return "BIOS or UEFI"
        case .gpt: return "UEFI (non-CSM)"
        }
    }
}

public enum FileSystemType: String, Sendable, Codable, CaseIterable {
    case fat32 = "FAT32"
    case exfat = "exFAT"
    var diskutilPersonality: String { self == .fat32 ? "MS-DOS FAT32" : "ExFAT" }
    var maxLabel: Int { self == .fat32 ? 11 : 15 }
}
