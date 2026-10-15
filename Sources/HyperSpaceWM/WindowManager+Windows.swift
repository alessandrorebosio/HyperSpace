import Foundation
import HyperSpaceCore

/// Apps and windows coming and going, focus and moves: the events that feed the model.
extension WindowManager {
    // MARK: - Apps

    func handle(_ event: SystemEvent) {
        switch event {
        case let .launched(pid):
            watch(pid)
        case let .terminated(pid):
            forget(app: pid)
        case let .activated(pid):
            // An app launched for the first time may not be a regular app yet when it launches.
            if apps[pid] == nil { watch(pid) } else { syncFocus(pid) }
        case let .hidden(pid, true):
            if settings.automaticallyUnhideMacosHiddenApps { system.unhide(pid) } else { setHidden(pid, true) }
        case let .hidden(pid, false):
            setHidden(pid, false)
        case .displaysChanged:
            monitorsChanged()
        }
    }

    func watch(_ pid: pid_t) {
        guard apps[pid] == nil, let app = system.app(pid) else {
            appStarted()
            return
        }
        apps[pid] = app
        let hidden = system.isHidden(pid)
        app.start(events: { [weak self, weak app] event in
            guard let self, let app else { return }
            self.handle(event, of: app)
        }) { [weak self] records in
            guard let self, self.apps[pid] === app else { return }
            self.add(records, of: app, managed: !hidden)
            self.syncFocus(self.system.frontmost)
            self.apply()
            self.appStarted()
        }
    }

    private func appStarted() {
        guard isStartingUp else { return }
        startingApps -= 1
        if startingApps <= 0 { startedUp() }
    }

    private func forget(app pid: pid_t) {
        apps.removeValue(forKey: pid)?.stop()
        for (id, entry) in records where entry.app.pid == pid { forget(window: id) }
        apply()
    }

    private func setHidden(_ pid: pid_t, _ hidden: Bool) {
        for (id, entry) in records where entry.app.pid == pid && tabs[id] == nil { setManaged(id, !hidden) }
        if !hidden { reconcileTabs(pid) }
        apply()
    }

    /// Displays connected, disconnected or woken up: workspaces are redistributed, and every
    /// frame is set again, since macOS moves windows of displays that left on its own.
    private func monitorsChanged() {
        guard let model else { return }
        let before = model.focusedWorkspace.name
        model.setMonitors(system.monitors())
        apply(force: true)
        if model.focusedWorkspace.name != before { handlers.changed() }
    }

    // MARK: - Windows

    private func handle(_ event: WindowEvent, of app: WindowApp) {
        switch event {
        case let .created(record):
            guard records[record.id] == nil else { return }
            add([record], of: app, managed: true)
            apply()
        case let .destroyed(id):
            forget(window: id)
            apply()
        case .focusChanged:
            // Switching tabs moves focus: the shown tab changed, or a tab missed on creation.
            if reconcileTabs(app.pid) { apply() }
            syncFocus(app.pid)
        case let .minimized(id, isMinimized):
            setManaged(id, !isMinimized)
            apply()
        case let .moved(id):
            moved(id)
        case let .titleChanged(id, title):
            records[id]?.record.title = title
        }
    }

    /// Registers new windows of one app: native tabs join their group, the rest are managed.
    private func add(_ new: [WindowRecord], of app: WindowApp, managed: Bool) {
        for record in new {
            records[record.id] = (app, record)
            frames[record.id] = record.frame
        }
        guard managed else { return }
        reconcileTabs(app.pid, new: Set(new.map(\.id)))
        for record in new where tabs[record.id] == nil {
            manage(record.id)
            windowDetected(record.id)
        }
    }

    func manage(_ id: WindowID) {
        guard let model, let record = records[id]?.record else { return }
        // At startup windows stay on the monitor they're on; later ones join the focused workspace.
        let monitor = isStartingUp ? record.frame.flatMap { frame in
            model.monitors.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }?.id
        } : nil
        model.add(WMWindowInfo(id: id, floating: record.floating), monitor: monitor)
    }

    /// `on-window-detected`: the first matching callback runs on the new window (and the
    /// next ones too while `check-further-callbacks` is set).
    private func windowDetected(_ id: WindowID) {
        guard let model, !settings.onWindowDetected.isEmpty else { return }
        let values = variables(window: id)
        let appName = values["app-name"] ?? "", title = values["window-title"] ?? ""
        for rule in settings.onWindowDetected {
            let matches: Bool
            switch rule.condition {
            case .always:
                matches = true
            case let .script(script):
                matches = execute(script, window: id).ok
            case let .legacy(appID, appNameRegex, titleRegex, workspace, duringStartup):
                matches = (appID.map { $0 == values["app-bundle-id"] } ?? true)
                    && (appNameRegex.map { appName.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil } ?? true)
                    && (titleRegex.map { title.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil } ?? true)
                    && (workspace.map { $0 == model.workspace(of: id)?.name } ?? true)
                    && (duringStartup.map { $0 == isStartingUp } ?? true)
            }
            guard matches else { continue }
            if let error = execute(rule.run, window: id).error { log.error("on-window-detected: \(error)") }
            if !rule.checkFurtherCallbacks { break }
        }
    }

    private func setManaged(_ id: WindowID, _ managed: Bool) {
        if managed { manage(id) } else { model?.remove(id) }
    }

    private func forget(window id: WindowID) {
        if let heir = tabs.first(where: { $0.value == id })?.key {
            // The group's window closed but other tabs remain: one of them stands in.
            model?.replace(id, with: heir)
            tabs[heir] = nil
            for (tab, group) in tabs where group == id { tabs[tab] = heir }
            shownTab[heir] = shownTab[id] == heir ? nil : shownTab[id]
            targets[heir] = targets[id]
        } else {
            model?.remove(id)
        }
        tabs[id] = nil
        shownTab[id] = nil
        for (group, tab) in shownTab where tab == id { shownTab[group] = nil }
        records[id] = nil
        frames[id] = nil
        targets[id] = nil
        setAt[id] = nil
        parked[id] = nil
        snapChecks.removeValue(forKey: id)?.cancel()
    }

    // MARK: - Focus and moves

    /// macOS focus moved: follow it (and show its workspace if it was hidden).
    func syncFocus(_ pid: pid_t?) {
        guard let pid, let app = apps[pid] else { return }
        app.focusedWindow { [weak self] id in
            guard let self, let model = self.model, let before = self.focusState else { return }
            // A tab: its group is what the model knows; remember which tab is shown.
            var id = id
            if let tab = id, let group = self.tabs[tab] {
                self.shownTab[group] = tab
                id = group
            } else if let window = id, self.shownTab[window] != nil {
                self.shownTab[window] = nil
            }
            // Still nothing we manage: one of the app's managed windows will do.
            let known = id.flatMap { model.windows[$0] != nil ? $0 : nil }
                ?? self.records.filter { $0.value.app.pid == pid && model.windows[$0.key] != nil }.map(\.key).min()
            if model.nativeFocus(known) { self.apply() }
            self.focusChanged(since: before)
            if model.focusedWorkspace.name != before.workspace { self.handlers.changed() }
        }
    }

    /// A window moved or resized. Floating: remember its frame. Tiled: if the user dragged
    /// it, put it back once the drag is over (our own moves match the known frame).
    private func moved(_ id: WindowID) {
        guard parked[id] == nil, let app = records[id]?.app else { return }
        snapChecks.removeValue(forKey: id)?.cancel()
        snapChecks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            app.frame(of: id) { [weak self] frame in
                guard let self, let frame, self.parked[id] == nil else { return }
                self.snapChecks[id] = nil
                self.frames[id] = frame
                // Right after our own change it's the app settling (e.g. a minimum size).
                let ours = self.setAt[id].map { ContinuousClock.now - $0 < .seconds(1) } ?? false
                // A tab that no longer sits on its group was dragged out: a window now.
                if let group = self.tabs[id], !ours, let target = self.targets[group], !target.isClose(to: frame) {
                    self.tabs[id] = nil
                    self.manage(id)
                    self.apply()
                    return
                }
                guard !ours, let target = self.targets[id], !target.isClose(to: frame),
                      self.model?.windows[id]?.floating == false else { return }
                self.targets[id] = nil // dragged by the user: put it back
                self.apply()
            }
        }
    }
}
