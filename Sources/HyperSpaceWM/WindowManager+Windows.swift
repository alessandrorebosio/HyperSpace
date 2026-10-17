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
            if apps[pid] == nil { watch(pid) } else { scheduleRefresh(pid); syncFocus(pid) }
        case let .hidden(pid, true):
            if settings.automaticallyUnhideMacosHiddenApps { system.unhide(pid) } else { setHidden(pid, true) }
        case let .hidden(pid, false):
            setHidden(pid, false)
        case .displaysChanged:
            displaysConnected()
            monitorsChanged()
            // A display just connected: its input matters now, not in 2 s.
            if inputPolling != nil { readMonitorInputs() }
        }
    }

    func watch(_ pid: pid_t) {
        guard apps[pid] == nil, let app = system.app(pid) else {
            appStarted(pid)
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
            if self.system.frontmost == pid { self.syncFocus(pid) }
            self.apply()
            self.appStarted(pid)
        }
    }

    /// One of the apps present at launch has reported its windows, or is gone.
    private func appStarted(_ pid: pid_t) {
        guard isStartingUp, startingApps.remove(pid) != nil, startingApps.isEmpty else { return }
        startedUp()
    }

    private func forget(app pid: pid_t) {
        if let app = apps[pid] { rememberWorkspace(of: app) }
        apps.removeValue(forKey: pid)?.stop()
        refreshes.removeValue(forKey: pid)?.cancel()
        appStarted(pid) // quit before reporting its windows
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
    func monitorsChanged() {
        guard let model else { return }
        model.setMonitors(shownMonitors())
        apply(force: true)
        announce()
    }

    // MARK: - Windows

    private func handle(_ event: WindowEvent, of app: WindowApp) {
        switch event {
        case let .created(record):
            guard records[record.id] == nil else { return }
            add([record], of: app, managed: true)
            apply()
            // Put on another workspace (a rule, or where the app was last with
            // reopen-apps-in-last-workspace): follow it if the app is in front, i.e. the user
            // just opened it.
            followIfFrontmost(record.id, of: app)
        case let .destroyed(id):
            if model?.windows[id] != nil { rememberWorkspace(of: app, closing: id) }
            forget(window: id)
            apply()
        case .focusChanged:
            // Switching tabs moves focus: the shown tab changed, or a tab missed on creation.
            if reconcileTabs(app.pid) { apply() }
            scheduleRefresh(app.pid)
            syncFocus(app.pid)
        case let .minimized(id, isMinimized):
            setManaged(id, !isMinimized)
            apply()
            // Restored from the Dock onto its workspace: follow it there.
            if !isMinimized { followIfFrontmost(id, of: app) }
        case let .moved(id):
            moved(id)
        case let .titleChanged(id, title):
            records[id]?.record.title = title
        }
    }

    /// A window just managed, of the app in front, is on another workspace: show it.
    private func followIfFrontmost(_ id: WindowID, of app: WindowApp) {
        if system.frontmost == app.pid, let model, let workspace = model.workspace(of: id),
           workspace.name != model.focusedWorkspace.name { syncFocus(app.pid) }
    }

    /// `refresh` a moment after the app's focus settles: re-reading every window of a busy
    /// app can take a second, and it must not hold up the frames of a workspace switch on
    /// the app's queue. Focus changes in a row make one refresh.
    func scheduleRefresh(_ pid: pid_t) {
        refreshes.removeValue(forKey: pid)?.cancel()
        refreshes[pid] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.refreshes[pid] = nil
            self.refresh(pid)
        }
    }

    /// Catches up with events that never came, when the app gets focus: windows it has that
    /// weren't reported join, and windows the window server no longer has are dropped.
    func refresh(_ pid: pid_t) {
        guard let app = apps[pid] else { return }
        app.windows { [weak self, weak app] new in
            guard let self, let app, self.apps[pid] === app else { return }
            let known = self.records.compactMap { $0.value.app === app ? $0.key : nil }
            let server = self.system.windowServer(known)
            // Nothing at all back is a failed call more likely than every window gone.
            let gone = server.isEmpty ? [] : known.filter { server[$0] == nil }
            let unseen = new.filter { self.records[$0.id] == nil }
            guard !gone.isEmpty || !unseen.isEmpty else { return }
            if !gone.isEmpty { self.log.info("\(app.name): \(gone.count) closed windows missed") }
            if !unseen.isEmpty { self.log.info("\(app.name): \(unseen.count) new windows missed") }
            for id in gone { self.forget(window: id) }
            self.add(unseen, of: app, managed: !self.system.isHidden(pid))
            self.apply()
        }
    }

    /// Registers new windows of one app: native tabs join their group, the rest are managed.
    private func add(_ new: [WindowRecord], of app: WindowApp, managed: Bool) {
        let new = new.filter { records[$0.id] == nil }
        for record in new {
            records[record.id] = (app, record)
            frames[record.id] = record.frame
        }
        guard managed, let model else { return }
        // Opened again (no window left before these, minimized ones included): back to the
        // workspace it was last on, if reopen-apps-in-last-workspace is on.
        let ids = Set(new.map(\.id))
        let reopened = isStartingUp || !settings.reopenAppsInLastWorkspace ? nil : app.bundleID.flatMap { appWorkspaces[$0] }.flatMap { name in
            records.contains { $0.value.app === app && !ids.contains($0.key) } ? nil : name
        }
        reconcileTabs(app.pid, new: ids)
        // Windows an on-window-detected rule sent to a workspace, and which one.
        var placed: [WindowID: String] = [:]
        for record in new where tabs[record.id] == nil {
            manage(record.id)
            if let reopened {
                _ = try? model.run(.moveNodeToWorkspace(.named(reopened), focusFollows: false, wrapAround: false,
                                                        window: record.id, failIfNoop: false))
            }
            if windowDetected(record.id), let name = model.workspace(of: record.id)?.name { placed[record.id] = name }
            publishWindowDetected(record.id)
        }
        adoptScratchpad(new, of: app, placed: placed)
    }

    /// The app's last managed window is `closing`, or the app quits (`nil`): the workspace
    /// its windows are on (the focused one's, if it's theirs) is where it opens next time.
    private func rememberWorkspace(of app: WindowApp, closing: WindowID? = nil) {
        guard let model, !isStartingUp, let bundleID = app.bundleID else { return }
        var window: WindowID?
        for (id, entry) in records where entry.app === app && model.windows[id] != nil {
            if let closing, id != closing { return } // another window stays open
            if window != model.focused, id == model.focused || id < window ?? .max { window = id }
        }
        // A shown scratchpad belongs to the workspace it goes back to.
        guard let name = window.flatMap({ model.scratchpadHomes[$0]?.workspace ?? model.workspace(of: $0)?.name }),
              appWorkspaces[bundleID] != name else { return }
        appWorkspaces[bundleID] = name
        saveAppWorkspaces()
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
    /// next ones too while `check-further-callbacks` is set). Returns whether one of them
    /// moved it to a workspace.
    @discardableResult
    private func windowDetected(_ id: WindowID) -> Bool {
        guard let model, !settings.onWindowDetected.isEmpty else { return false }
        var placed = false
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
            placed = placed || rule.run.commands.contains { if case .moveNodeToWorkspace = $0 { true } else { false } }
            if !rule.checkFurtherCallbacks { break }
        }
        return placed
    }

    /// Minimized or hidden windows leave the model; back, they return to where they were
    /// (a shown scratchpad to the workspace it goes back to), not to the focused workspace.
    private func setManaged(_ id: WindowID, _ managed: Bool) {
        guard let model else { return }
        if managed {
            if let spot = setAside.removeValue(forKey: id), let record = records[id]?.record {
                model.add(WMWindowInfo(id: id, floating: record.floating), at: spot)
            } else {
                manage(id)
            }
        } else {
            if let spot = model.spot(of: id) { setAside[id] = spot }
            model.remove(id)
        }
    }

    private func forget(window id: WindowID) {
        let groupTabs = tabs.filter { $0.value == id }.map(\.key)
        if let heir = shownTab[id].flatMap({ groupTabs.contains($0) ? $0 : nil }) ?? groupTabs.min() {
            // The group's window closed but other tabs remain: the shown one stands in.
            model?.replace(id, with: heir)
            tabs[heir] = nil
            for (tab, group) in tabs where group == id { tabs[tab] = heir }
            shownTab[heir] = shownTab[id] == heir ? nil : shownTab[id]
            targets[heir] = targets[id]
        } else if model?.focused == id {
            // The focused window closed: focus goes to the workspace's next one, and the app
            // macOS activates in its place mustn't take us to its workspace.
            model?.remove(id)
            focusedClosedAt = .now
            focusNative()
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
        setAside[id] = nil
        snapChecks.removeValue(forKey: id)?.cancel()
    }

    // MARK: - Focus and moves

    /// macOS focus moved: follow it (and show its workspace if it was hidden).
    func syncFocus(_ pid: pid_t?) {
        guard let pid, let app = apps[pid] else { return }
        // Its window for `scratchpad` is on the way: the app comes forward for it, and an
        // older window of its mustn't take us to its workspace meanwhile.
        if let pending = pendingScratchpad, pending.bundleID == app.bundleID, ContinuousClock.now < pending.until { return }
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
            if let known, self.isStaleFocus(known) { return }
            if model.nativeFocus(known) {
                self.log.info("following macOS focus to workspace \(model.focusedWorkspace.name) (\(app.name))")
                self.apply()
            }
            self.focusedByUser()
            self.focusChanged(since: before)
            self.announce()
        }
    }

    /// Focus macOS reports late, for a window on a hidden workspace: following it would
    /// switch workspaces under the user. True for
    /// - the window a command just left: its app's activation can arrive after the command
    ///   moved on (`workspace next` pressed in a row went back a step);
    /// - closing the focused window, which makes macOS activate the app used before: just
    ///   after a close, or before the close is reported (the focused window is already
    ///   gone from the window server).
    private func isStaleFocus(_ window: WindowID) -> Bool {
        guard let model, let workspace = model.workspace(of: window), !model.isVisible(workspace.name) else { return false }
        let now = ContinuousClock.now
        if let left = leftByCommand, left.window == window, now - left.at < .seconds(1) { return true }
        if let at = focusedClosedAt, now - at < .seconds(1) { return true }
        guard let focused = model.focused, focused != window, records[focused] != nil else { return false }
        return system.windowServer([focused])[focused] == nil
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
