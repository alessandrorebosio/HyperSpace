import AppKit
import HyperSpaceCore
import Security

/// "Check for Updates…": asks GitHub for the latest release, only when the person clicks
/// it (HyperSpace makes no network call otherwise), and offers to install it: the release's
/// zip is downloaded, its app checked to be signed by the same key as this one, put in
/// place of this one, and started.
@MainActor
enum Updates {
    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let url: URL

            enum CodingKeys: String, CodingKey {
                case name, url = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url", assets
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
                await show(try JSONDecoder().decode(Release.self, from: data))
            } catch {
                log.error("checking for updates failed: \(error)")
                alert("Couldn't check for updates", "GitHub didn't answer: \(error.localizedDescription)", buttons: ["OK"])
            }
        }
    }

    private static func show(_ release: Release) async {
        let latest = String(release.tagName.drop { $0 == "v" })
        guard HyperSpace.isNewer(release.tagName, than: HyperSpace.version) else {
            alert("HyperSpace is up to date", "Version \(HyperSpace.version) is the latest.", buttons: ["OK"])
            return
        }
        let zip = release.assets.first { $0.name == "HyperSpace-\(latest).zip" }
        guard let zip else {
            let answer = alert("HyperSpace \(latest) is available", "You have \(HyperSpace.version). Download the zip from the release page and replace the app in /Applications.",
                               buttons: ["Open Release Page", "Later"])
            if answer == .alertFirstButtonReturn { NSWorkspace.shared.open(release.htmlURL) }
            return
        }
        let answer = alert("HyperSpace \(latest) is available", "You have \(HyperSpace.version). HyperSpace can install it and restart.",
                           buttons: ["Install and Restart", "Release Notes", "Later"])
        switch answer {
        case .alertFirstButtonReturn:
            do {
                try await install(zip.url)
            } catch {
                log.error("installing \(latest) failed: \(error)")
                alert("Couldn't install HyperSpace \(latest)", "\(error.localizedDescription)\nYou can download it from the release page.", buttons: ["OK"])
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        default:
            break
        }
    }

    private struct InstallError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Downloads and unpacks the zip, checks the app in it, swaps it for this one and starts it.
    /// A download made here carries no quarantine, so macOS doesn't block the new app.
    private static func install(_ url: URL) async throws {
        let (download, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallError("the download failed") }
        let folder = FileManager.default.temporaryDirectory.appending(path: "HyperSpace-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await run("/usr/bin/ditto", ["-x", "-k", download.path, folder.path])
        let app = folder.appending(path: "HyperSpace.app")
        try checkSignature(app)
        let current = Bundle.main.bundleURL
        _ = try FileManager.default.replaceItemAt(current, withItemAt: app)
        log.info("installed the update in \(current.path), restarting")
        // Started once this process is gone: two HyperSpaces never run at once.
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/bin/sh")
        restart.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", current.path]
        try restart.run()
        NSApp.terminate(nil)
    }

    /// The new app must be validly signed and meet this app's designated requirement: same
    /// bundle id, same signing certificate. Anything else isn't ours.
    private static func checkSignature(_ app: URL) throws {
        var me: SecCode?, mine: SecStaticCode?, requirement: SecRequirement?, staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
        else { throw InstallError("the downloaded app isn't signed like this one") }
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { process in
                done.resume(with: process.terminationStatus == 0 ? .success(()) : .failure(InstallError("unpacking the update failed")))
            }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
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
