import AppKit
import HelmCore

/// Applies a `KeyboardPlan`: L0 mappings through `HIDMapper`, L1 through `InputTap`,
/// and keeps the tap's tables in sync with the frontmost app.
@MainActor
public final class KeyboardService {
    public enum TapState: String, Sendable {
        case off, running, failed
    }

    private let log = Helm.logger("keyboard")
    private let mapper = HIDMapper()
    private var tap: InputTap?
    private var plan = KeyboardPlan()
    private var frontmostApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    private var appObserver: (any NSObjectProtocol)?
    private let onWMCommand: @MainActor @Sendable (String) -> Void

    public private(set) var tapState = TapState.off
    public var mappedKeyboards: Int { mapper.mappedKeyboards }

    public init(onWMCommand: @escaping @MainActor @Sendable (String) -> Void) {
        self.onWMCommand = onWMCommand
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.frontmostApp = bundleID
                self?.pushTables()
            }
        }
    }

    public func apply(_ plan: KeyboardPlan, accessibilityGranted: Bool) {
        self.plan = plan
        if plan.needsEventTap, accessibilityGranted {
            startTap()
        } else {
            stopTap()
        }
        // Caps Lock -> F18 only while the tap is there to give F18 a meaning;
        // otherwise Caps Lock would just go dead.
        let layerMapping = Layer.trigger.usage
        mapper.apply(tapState == .running ? plan.hid : plan.hid.filter { $0.to != layerMapping })
        pushTables()
    }

    public func shutdown() {
        stopTap()
        mapper.restore()
    }

    private func startTap() {
        guard tap == nil else { return }
        let onWMCommand = onWMCommand
        let tap = InputTap { output in
            switch output {
            case let .shell(command): ActionRunner.shell(command)
            case let .wm(command): Task { @MainActor in onWMCommand(command) }
            case .key, .drop: break
            }
        }
        if tap.start() {
            self.tap = tap
            tapState = .running
            log.info("event tap running")
        } else {
            tapState = .failed
            log.error("event tap could not be created")
        }
    }

    private func stopTap() {
        tap?.stop()
        tap = nil
        if tapState == .running { tapState = .off }
        if !plan.needsEventTap { tapState = .off }
    }

    private func pushTables() {
        tap?.update(plan.tables(forApp: frontmostApp))
    }
}
