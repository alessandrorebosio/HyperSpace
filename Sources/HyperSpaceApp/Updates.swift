import AppKit
import HyperSpaceCore

/// "Check for Updates…": asks GitHub for the latest release, only when the person clicks
/// it (HyperSpace makes no network call otherwise), and offers to open its page.
@MainActor
enum Updates {
    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url"
        }
    }

    private static let log = HyperSpace.logger("app")

    static func check() {
        var request = URLRequest(url: HyperSpace.latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                    throw URLError(.badServerResponse)
                }
                show(try JSONDecoder().decode(Release.self, from: data))
            } catch {
                log.error("checking for updates failed: \(error)")
                alert("Couldn't check for updates", "GitHub didn't answer: \(error.localizedDescription)", buttons: ["OK"])
            }
        }
    }

    private static func show(_ release: Release) {
        let latest = release.tagName.drop { $0 == "v" }
        guard HyperSpace.isNewer(release.tagName, than: HyperSpace.version) else {
            alert("HyperSpace is up to date", "Version \(HyperSpace.version) is the latest.", buttons: ["OK"])
            return
        }
        let answer = alert("HyperSpace \(latest) is available", "You have \(HyperSpace.version). Download the zip from the release page and replace the app in /Applications.",
                           buttons: ["Open Release Page", "Later"])
        if answer == .alertFirstButtonReturn { NSWorkspace.shared.open(release.htmlURL) }
    }

    /// A menu bar app isn't active: it comes to the front so the alert isn't hidden.
    @discardableResult
    private static func alert(_ title: String, _ text: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        for button in buttons { alert.addButton(withTitle: button) }
        NSApp.activate()
        return alert.runModal()
    }
}
