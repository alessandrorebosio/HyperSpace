import os

public enum Helm {
    public static let version = "0.1.0"
    public static let bundleID = "com.alessandrorebosio.Helm"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: bundleID, category: category)
    }
}
