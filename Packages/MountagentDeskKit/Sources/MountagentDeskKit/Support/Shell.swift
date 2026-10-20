import Foundation

public enum Shell {
    /// Single-quotes a value for `sh`, so spaces and quotes in paths survive.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
