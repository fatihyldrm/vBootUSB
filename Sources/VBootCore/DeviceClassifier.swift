import Foundation

public enum DeviceClassifier {
    public static func classify(
        bsdName: String,
        rootWholeDiskBSD: String?,
        isInternal: Bool,
        isRemovable: Bool,
        isEjectable: Bool
    ) -> DeviceClassification {
        if let root = rootWholeDiskBSD, root == bsdName {
            return .systemDisk
        }
        if isInternal {
            return .internalDisk
        }
        if isRemovable || isEjectable {
            return .externalRemovable
        }
        return .externalFixed
    }
}
