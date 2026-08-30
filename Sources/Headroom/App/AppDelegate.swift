import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let providers: [any UsageProvider] = [CodexProvider(), ClaudeProvider(), GeminiProvider()]

    private var watcher: FileWatcher?
    private var statusItem: NSStatusItem!
    private var pending: DispatchWorkItem?
    private var lastScan: Date = .distantPast
    private var safetyTimer: Timer?
    private var snapshots: [ProviderID: Snapshot] = [:]

    /// Built once and kept, so opening the menu never destroys a view mid-animation.
    private var rowViews: [ProviderID: [QuotaWindow: MenuRowView]] = [:]
    private var metaItems: [ProviderID: NSMenuItem] = [:]

    private var installed: [ProviderID] = []
    private var displayOrder: [ProviderID] { [.codex, .claude, .gemini] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installed = displayOrder.filter { id in
            guard let p = providers.first(where: { $0.id == id }) else { return false }
            return p.isInstalled() && p.canReportUsage
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = " ···"
        statusItem.menu = buildMenu()

        let roots = providers.filter { $0.isInstalled() }.flatMap { $0.watchRoots() }
        watcher = FileWatcher(roots: roots) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        watcher?.start()

        // Safety net for anything FSEvents misses. Deliberately slow — the
        // watcher is the real mechanism.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        refresh()

        // `--demo-calibrate` opens the calibration sheet so its layout can be
        // checked without a human clicking through to it.
        if ProcessInfo.processInfo.arguments.contains("--demo-calibrate") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                MainActor.assumeIsolated {
                    NSApp.activate(ignoringOtherApps: true)
                    self?.calibrateAction()
                }
            }
        }

        // `--demo-menu` pops the menu open on its own so the layout can be
        // screenshotted and checked without a human clicking it.
        if ProcessInfo.processInfo.arguments.contains("--demo-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                MainActor.assumeIsolated { self?.statusItem.button?.performClick(nil) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        safetyTimer?.invalidate()
    }

    // MARK: - Menu lifecycle

    /// Opening the menu is an explicit action, so it's the one moment motion is
    /// justified: re-read the logs and replay every capsule from empty.
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        for rows in rowViews.values { for view in rows.values { view.replay() } }
    }

    func menuDidClose(_ menu: NSMenu) {
        for rows in rowViews.values { for view in rows.values { view.stop() } }
    }

    // MARK: - Refresh

    /// Throttled, not just debounced.
    ///
    /// While an agent is actively working, its log is written continuously, so a
    /// plain debounce still fires several times a second — and each Claude scan
    /// costs ~75 ms. Measured at ~17% of a core during a live session, which is
    /// exactly the battery drain this app exists to warn about. A hard floor
    /// between scans caps it at roughly 1%.
    ///
    /// The gauge is allowed to lag a few seconds. It is not allowed to be the
    /// reason your fans spin up.
    private static let minimumScanInterval: TimeInterval = 6

    private func scheduleRefresh() {
        pending?.cancel()
        let since = Date().timeIntervalSince(lastScan)
        let delay = max(0.4, Self.minimumScanInterval - since)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refresh() {
        lastScan = Date()
        let list = providers
        Task.detached(priority: .utility) {
            var out: [ProviderID: Snapshot] = [:]
            for p in list where p.isInstalled() {
                if let snap = try? p.snapshot() { out[p.id] = snap }
            }
            let result = out
            await MainActor.run { [weak self] in self?.apply(result) }
        }
    }

    private func apply(_ snaps: [ProviderID: Snapshot]) {
        snapshots = snaps

        for id in installed {
            guard let snap = snaps[id] else { continue }
            for window in QuotaWindow.allCases {
                guard let view = rowViews[id]?[window] else { continue }
                let reading = snap.readings[window] ?? .unavailable(reason: "no data")
                view.configure(reading: reading, detail: detail(for: reading))
            }
            metaItems[id]?.attributedTitle = secondary(metaLine(for: snap), indent: 21)
        }

        // Which agent the bar speaks for. Preference goes to the one you're
        // actually using — the most recently written log — because that's the
        // number you care about mid-task. If nothing has been touched lately,
        // fall back to whichever agent is closest to running out.
        let candidates = installed.compactMap { id -> (ProviderID, Double, Date?)? in
            guard let snap = snaps[id],
                  let left = worstWindow(of: snap).1.percentRemaining else { return nil }
            return (id, left, snap.sourceDate)
        }
        let recent = candidates
            .filter { $0.2.map { Date().timeIntervalSince($0) < 1800 } ?? false }
            .max { ($0.2 ?? .distantPast) < ($1.2 ?? .distantPast) }
        let chosen = recent ?? candidates.min { $0.1 < $1.1 }

        setStatusPresentation(chosen.map { ($0.0, $0.1) }, isActive: recent != nil)
    }

    /// Whichever window has least left. An unavailable window can't be the
    /// worst — we genuinely don't know where it stands.
    private func worstWindow(of snap: Snapshot) -> (QuotaWindow, Reading) {
        let ranked = QuotaWindow.allCases.compactMap { w -> (QuotaWindow, Reading, Double)? in
            guard let r = snap.readings[w], let left = r.percentRemaining else { return nil }
            return (w, r, left)
        }.sorted { $0.2 < $1.2 }
        if let top = ranked.first { return (top.0, top.1) }
        return (.short, snap.readings[.short] ?? .unavailable(reason: "no data"))
    }

    // MARK: - Status item

    /// The needle is the gauge. `gauge.with.dots.needle.bottom.0percent` is a
    /// variable-value symbol, so the needle sweeps continuously with what's left
    /// rather than snapping between a few fixed images.
    private func setStatusPresentation(_ chosen: (ProviderID, Double)?, isActive: Bool) {
        guard let button = statusItem.button else { return }

        guard let (id, left) = chosen else {
            button.image = symbol(0)
            button.title = " —"
            button.toolTip = "Headroom — no data"
            button.setAccessibilityLabel("Headroom, no data")
            return
        }
        button.image = symbol(left / 100)
        // Name it. "37%" alone can't say which agent it speaks for.
        button.title = " \(id.displayName) \(Int(left.rounded()))%"
        button.toolTip = isActive
            ? "\(id.displayName): \(Int(left.rounded()))% left — the agent you're using now"
            : "\(id.displayName): \(Int(left.rounded()))% left — least of any agent"
        button.setAccessibilityLabel("Headroom, \(id.displayName) \(Int(left.rounded())) percent left")
    }

    private func symbol(_ value: Double) -> NSImage? {
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.0percent",
                            variableValue: max(0, min(1, value)),
                            accessibilityDescription: "Headroom")
        image?.isTemplate = true
        return image
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // Without this, AppKit disables every item that has no action — which is
        // every data row — and the whole menu renders as greyed-out text.
        menu.autoenablesItems = false
        menu.delegate = self

        for id in installed {
            let header = NSMenuItem()
            header.attributedTitle = sectionHeader("\(id.displayName) remaining")
            header.isEnabled = false
            menu.addItem(header)

            var views: [QuotaWindow: MenuRowView] = [:]
            for window in QuotaWindow.allCases {
                let view = MenuRowView(title: window == .short ? "5 hours" : "This week")
                let item = NSMenuItem()
                item.view = view
                item.isEnabled = true
                menu.addItem(item)
                views[window] = view
            }
            rowViews[id] = views

            let meta = NSMenuItem()
            meta.attributedTitle = secondary("", indent: 21)
            meta.isEnabled = false
            menu.addItem(meta)
            metaItems[id] = meta

            // Only Claude needs calibrating — Codex reports real percentages.
            if id == .claude {
                let item = NSMenuItem(title: "Calibrate from Claude's usage page…",
                                      action: #selector(calibrateAction), keyEquivalent: "")
                item.toolTip = "Claude → Settings → Usage shows the real percentages. "
                    + "Entering them anchors this estimate to them."
                item.isEnabled = true
                item.indentationLevel = 1
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // Agents that exist but yield no numbers get one honest line each, so a
        // missing agent reads as "looked for, here's why" rather than as a bug.
        let silent = providers.filter { !$0.canReportUsage || !$0.isInstalled() }
        if !silent.isEmpty {
            for p in silent {
                let reason = (try? p.snapshot())?.readings[.short].flatMap { r -> String? in
                    if case .unavailable(let why) = r { return why }
                    return nil
                } ?? "not detected"
                let item = NSMenuItem()
                item.attributedTitle = secondary("\(p.id.displayName) — \(reason)", indent: 21)
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshAction), keyEquivalent: "r")
        refresh.isEnabled = true
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Headroom", action: #selector(quitAction), keyEquivalent: "q")
        quit.isEnabled = true
        menu.addItem(quit)

        menu.items.forEach { if $0.action != nil { $0.target = self } }
        return menu
    }

    // MARK: - Text

    private func sectionHeader(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }

    private func secondary(_ text: String, indent: CGFloat) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = indent
        p.headIndent = indent
        // A menu item shows one line. Without this, an over-long string wraps and
        // the remainder is silently dropped — the reader sees a sentence that
        // just stops. Truncating at least admits that something was cut.
        p.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: p
        ])
    }

    /// Right-hand text on a row: what's left, plus how much to trust it.
    private func detail(for reading: Reading) -> String {
        switch reading {
        case .authoritative:
            return "\(Int((reading.percentRemaining ?? 0).rounded()))% left"
        case .estimated:
            return "~\(Int((reading.percentRemaining ?? 0).rounded()))% left"
        case .unavailable:
            return "—"
        }
    }

    /// The line under each agent's rows: how much to trust these numbers, and
    /// when they turn over. Kept short — it has to fit the menu without wrapping.
    private func metaLine(for snap: Snapshot) -> String {
        var bits: [String] = []

        // Codex reports real server-side percentages; Claude's are inferred from
        // local token counts. Since the capsules no longer distinguish them, say so.
        let exact = QuotaWindow.allCases.contains { snap.readings[$0]?.isExact == true }
        if exact {
            if let plan = snap.planLabel { bits.append(plan) }
            bits.append("exact")
        } else {
            bits.append(snap.planLabel == "calibrated" ? "estimated · calibrated"
                                                       : "estimated · uncalibrated")
        }

        if let resets = QuotaWindow.allCases.compactMap({ snap.readings[$0]?.resetsAt }).min() {
            bits.append("resets \(RelativeDateTimeFormatter().localizedString(for: resets, relativeTo: Date()))")
        }
        if let age = snap.staleness, age > 1800 {
            // Minutes stop being readable past an hour or so: "stale 1066m"
            // makes the reader do arithmetic to learn "yesterday".
            let mins = Int(age / 60)
            bits.append(mins < 90 ? "stale \(mins)m" : "stale \(Int((age / 3600).rounded()))h")
        }
        return bits.joined(separator: " · ")
    }

    // MARK: - Calibration

    /// Anchor the estimate to the numbers Claude itself reports.
    ///
    /// Better than waiting for a rate-limit rejection: it works on first run,
    /// needs no outage, and re-anchors against the figure the vendor actually
    /// enforces — including claude.ai and desktop-app usage, which shares the
    /// plan limit but never appears in the local Claude Code logs.
    ///
    /// The weekly reset day and hour live here too. They are not cosmetic: the
    /// weekly window is a fixed calendar window, so the wrong anchor sums the
    /// wrong days. It defaults to Friday 6:00 AM, which is one account's
    /// schedule, not everyone's.
    @objc private func calibrateAction() {
        guard let snap = snapshots[.claude] else { return }
        let calibration = CalibrationStore.load()

        let alert = NSAlert()
        alert.messageText = "Calibrate Claude usage"
        alert.informativeText = """
            Open Claude → Settings → Usage. Enter the two "% used" figures, and \
            set the weekly reset to match the "Resets …" line shown there.

            This also captures usage from claude.ai and the Claude desktop app, which \
            share your plan limit but never appear in the local Claude Code logs.
            """
        alert.addButton(withTitle: "Calibrate")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 360, height: 88))
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .trailing

        func row(_ caption: String, _ control: NSView) -> NSStackView {
            let r = NSStackView()
            r.orientation = .horizontal
            r.spacing = 8
            r.addArrangedSubview(NSTextField(labelWithString: caption))
            r.addArrangedSubview(control)
            return r
        }

        func percentField() -> NSTextField {
            let input = NSTextField(string: "")
            input.placeholderString = "% used"
            input.widthAnchor.constraint(equalToConstant: 76).isActive = true
            return input
        }

        let shortField = percentField()
        let longField = percentField()

        let weekdayPopup = NSPopUpButton()
        // Calendar.current, not Calendar(identifier:) — a calendar built with no
        // locale silently hands back abbreviated symbols ("Fri"), which read as a
        // clipped label rather than a deliberate one.
        weekdayPopup.addItems(withTitles: Calendar.current.weekdaySymbols)
        weekdayPopup.selectItem(at: min(6, max(0, calibration.weeklyResetWeekday - 1)))
        // Wide enough for "Wednesday" — otherwise it silently clips to "Wed".
        weekdayPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 116).isActive = true

        let hourPopup = NSPopUpButton()
        hourPopup.addItems(withTitles: (0..<24).map { h in
            let display = h % 12 == 0 ? 12 : h % 12
            return "\(display):00 \(h < 12 ? "AM" : "PM")"
        })
        hourPopup.selectItem(at: min(23, max(0, calibration.weeklyResetHour)))
        hourPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true

        let resetRow = NSStackView()
        resetRow.orientation = .horizontal
        resetRow.spacing = 6
        resetRow.addArrangedSubview(NSTextField(labelWithString: "Weekly resets:"))
        resetRow.addArrangedSubview(weekdayPopup)
        resetRow.addArrangedSubview(hourPopup)

        stack.addArrangedSubview(row("Current session:", shortField))
        stack.addArrangedSubview(row("Weekly (all models):", longField))
        stack.addArrangedSubview(resetRow)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = shortField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newWeekday = weekdayPopup.indexOfSelectedItem + 1     // Calendar: 1 = Sunday
        let newHour = hourPopup.indexOfSelectedItem
        let anchorMoved = newWeekday != calibration.weeklyResetWeekday
                       || newHour != calibration.weeklyResetHour

        // Persist the anchor before deriving anything from it. The weekly total
        // is a function of the window, so a percentage typed in now has to be
        // divided by a sum measured under the *new* window — using the old sum
        // would bake the wrong capacity in at the moment of correcting it.
        var updated = calibration
        updated.weeklyResetWeekday = newWeekday
        updated.weeklyResetHour = newHour
        CalibrationStore.save(updated)

        let shortText = shortField.stringValue
        let longText = longField.stringValue
        let claude = providers.first { $0.id == .claude }
        let fallback = snap.rawWeighted

        Task.detached(priority: .userInitiated) {
            var raw = fallback
            if anchorMoved, let fresh = try? claude?.snapshot(), let r = fresh.rawWeighted {
                raw = r                       // re-measured under the new window
            }
            let measured = raw
            await MainActor.run { [weak self] in
                guard let self, let measured else { return }
                var cal = CalibrationStore.load()
                var changed = false
                for (text, window) in [(shortText, QuotaWindow.short),
                                       (longText, QuotaWindow.long)] {
                    guard let v = Self.percent(from: text), let sum = measured[window] else { continue }
                    cal.calibrate(observedUsedPercent: v, weightedSum: sum, for: window)
                    changed = true
                }
                if changed { CalibrationStore.save(cal) }
                self.refresh()
            }
        }
    }

    /// Accepts "54", "54%", " 54 % " — people paste what they see.
    private static func percent(from text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v > 0, v <= 100 else { return nil }
        return v
    }

    @objc private func refreshAction() { refresh() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}
