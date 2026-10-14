import os

public enum HyperSpace {
    public static let version = "0.1.0"
    public static let bundleID = "com.alessandrorebosio.HyperSpace"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: bundleID, category: category)
    }
}
