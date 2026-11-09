import Foundation
import os

let log = Logger(subsystem: "com.alessandrorebosio.HyperSpace", category: "app")

enum AppInfo {
    /// The app's version; "dev" when run outside the bundle (`swift run`).
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
