import AppKit
import ApplicationServices

/// Owns the panel and finds it a home in the menu bar.
///
/// Both strips beside the notch are contested, but by different owners:
///
/// - **Right of the notch** belongs to status items, laid out leftward from the
///   screen edge. Measurable exactly via the window server, and stable — it only
///   changes when the user adds or removes a menu bar app.
/// - **Left of the notch** belongs to the frontmost app's menus, which grow
///   rightward and change on every app switch. Measurable only with
///   Accessibility permission; without it we have to guess conservatively.
///
/// So right is preferred even when it's tighter: it's knowable.
@MainActor
final class PanelController {

    enum Placement { case rightOfNotch, leftOfNotch, hidden }

    private let drain = DrainView()
    private let panel: GaugePanel
    private var observers: [NSObjectProtocol] = []

    private(set) var isShowing = false
    private(set) var placement: Placement = .hidden

    /// Full dress: capsule + gap + label, per the motion study.
    private let fullWidth: CGFloat = 132
    /// Below this the label has to go, but colour-coded capsules still read.
    private let labelDropWidth: CGFloat = 96
    /// Below this even the capsules stop being legible.
    private let minimumWidth: CGFloat = 44

    /// Without Accessibility we can't see where the app menus end. Xcode and
    /// Photoshop-class apps reach roughly 700pt, so this is the safe assumption.
    /// It leaves very little room — which is exactly why AX is worth granting.
    private let assumedMenuExtent: CGFloat = 720

    /// User preference: allow falling back to the left strip at all.
    var allowsLeftFallback = true

    var ownStatusItemWindowNumber: Int?

    init() { panel = GaugePanel(contentView: drain) }

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func start() {
        reposition()

        // A status item's window doesn't exist in the window server yet at
        // launch, so the first measurement sees an empty strip and claims the
        // full width — overlapping the moment the item appears. Re-measure once
        // the menu bar has actually settled.
        for delay in [0.4, 1.2, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.reposition() }
            }
        }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Docking, undocking and resolution changes all move the auxiliary
            // rects. Never cache geometry across one of these.
            MainActor.assumeIsolated { self?.reposition() }
        })

        // Menus differ per app, so left placement has to be re-measured whenever
        // the frontmost app changes.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.placement != .rightOfNotch else { return }
                self.reposition()
            }
        })
    }

    func revalidatePlacement() { reposition() }

    func update(rows: [DrainView.Row]) { drain.rows = rows }

    // MARK: - Placement

    private func notchScreen() -> (NSScreen, CGRect, CGRect)? {
        for screen in NSScreen.screens {
            if let right = screen.auxiliaryTopRightArea,
               let left = screen.auxiliaryTopLeftArea,
               screen.safeAreaInsets.top > 0 {
                return (screen, left, right)
            }
        }
        return nil
    }

    private func hide() {
        panel.orderOut(nil)
        isShowing = false
        placement = .hidden
    }

    private func reposition() {
        guard let (screen, left, right) = notchScreen() else {
            // No notch: there is no notch-adjacent strip, so the status item is
            // the only surface. Hide rather than float a stray widget.
            return hide()
        }

        let barHeight = screen.safeAreaInsets.top
        let y = screen.frame.maxY - barHeight

        // 1. Prefer the right strip — its occupants are exactly measurable.
        let rightAnchor = right.minX + 6
        let rightBoundary = leftmostNeighbourX(rightOf: right.minX) ?? screen.frame.maxX
        let rightClear = rightBoundary - 10 - rightAnchor

        if rightClear >= minimumWidth {
            place(x: rightAnchor, y: y, height: barHeight, clear: rightClear, as: .rightOfNotch)
            return
        }

        // 2. Fall back to the left strip, growing leftward from the notch edge.
        guard allowsLeftFallback else { return hide() }
        let menuEnd = measuredMenuExtent() ?? assumedMenuExtent
        let leftAvailable = (left.maxX - 6) - menuEnd

        if leftAvailable >= minimumWidth {
            let width = min(fullWidth, leftAvailable)
            place(x: left.maxX - 6 - width, y: y, height: barHeight,
                  clear: width, as: .leftOfNotch)
            return
        }

        hide()
    }

    private func place(x: CGFloat, y: CGFloat, height: CGFloat,
                       clear: CGFloat, as newPlacement: Placement) {
        let width = min(fullWidth, clear)
        drain.showsLabel = width >= labelDropWidth
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
        isShowing = true
        placement = newPlacement

        if ProcessInfo.processInfo.arguments.contains("--debug-placement") {
            FileHandle.standardError.write(Data(
                "placement: \(newPlacement) x=\(x) w=\(width) label=\(drain.showsLabel) ax=\(accessibilityGranted)\n".utf8))
        }
    }

    // MARK: - Measuring neighbours

    /// Leftmost edge of *someone else's* menu bar item to the right of the notch.
    ///
    /// Two traps, both found the hard way:
    ///
    /// - Every status item, ours and every third-party app's, is a layer-25
    ///   window owned by the **Control Center** process on modern macOS, so
    ///   filtering by our own PID excludes nothing.
    /// - Our own panel is also a layer-25 window in that strip. Without excluding
    ///   it the panel sees itself, computes negative clear space, and hides one
    ///   frame after appearing.
    private func leftmostNeighbourX(rightOf notchRight: CGFloat) -> CGFloat? {
        var mine: Set<Int> = [panel.windowNumber]
        if let n = ownStatusItemWindowNumber { mine.insert(n) }

        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []

        var minX = CGFloat.greatestFiniteMagnitude
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 25,
                  let number = w[kCGWindowNumber as String] as? Int,
                  !mine.contains(number),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let yy = b["Y"], let width = b["Width"],
                  yy < 2,
                  x + width > notchRight
            else { continue }
            minX = min(minX, x)
        }
        return minX == .greatestFiniteMagnitude ? nil : minX
    }

    /// Right edge of the frontmost app's last menu title.
    ///
    /// Returns nil unless Accessibility is already granted — we never trigger the
    /// permission prompt on our own. A gauge does not get to demand "control your
    /// computer" unasked; the menu offers it if the user wants left placement.
    private func measuredMenuExtent() -> CGFloat? {
        guard AXIsProcessTrusted(),
              let front = NSWorkspace.shared.frontmostApplication else { return nil }

        let app = AXUIElementCreateApplication(front.processIdentifier)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let bar = barRef, CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return nil }

        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement,
                                            kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let items = kidsRef as? [AXUIElement], !items.isEmpty
        else { return nil }

        var rightmost: CGFloat = 0
        for item in items {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posRef)
            AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeRef)
            var pt = CGPoint.zero
            var sz = CGSize.zero
            if let posRef, CFGetTypeID(posRef) == AXValueGetTypeID() {
                AXValueGetValue(posRef as! AXValue, .cgPoint, &pt)
            }
            if let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() {
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &sz)
            }
            rightmost = max(rightmost, pt.x + sz.width)
        }
        return rightmost > 0 ? rightmost : nil
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
