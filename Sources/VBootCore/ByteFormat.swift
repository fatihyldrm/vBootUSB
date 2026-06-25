import Foundation

public enum ByteFormat {
    public static func humanize(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        if bytes < 1000 { return "\(bytes) B" }
        var value = Double(bytes)
        var index = 0
        while value >= 1000 && index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }
}
