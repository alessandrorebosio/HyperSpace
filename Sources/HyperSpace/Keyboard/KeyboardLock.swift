import Foundation

/// How long the keyboard lock lasts before it lifts by itself, so a closed settings window
/// or a hidden menu bar item never leaves you without a keyboard. A preference of this Mac.
enum KeyboardLock {
    /// Minutes; 0 means until unlocked by hand.
    static let choices = [1, 3, 5, 10, 0]
    private static let key = "keyboardLockMinutes"

    static var minutes: Int {
        get { UserDefaults.standard.object(forKey: key) as? Int ?? 3 }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func label(minutes: Int) -> String {
        minutes == 0 ? "Never" : "After \(minutes) min"
    }

    /// "2:41" left until `date`.
    static func remaining(until date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
