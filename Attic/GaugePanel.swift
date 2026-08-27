import AppKit

/// A borderless panel that sits at `.statusBar` — CGWindow layer 25, the same
/// layer Control Center's own items occupy. Verified against the live window
/// server: the menu bar background is layer 24, every real status item is 25.
/// This is not drawing "over" the menu bar so much as joining it.
final class GaugePanel: NSPanel {

    init(contentView: NSView) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        // Without .fullScreenAuxiliary the panel vanishes the first time the
        // user goes fullscreen — the most common bug in this class of app.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false

        // ORDER MATTERS. `isFloatingPanel` is a convenience that *sets the window
        // level* to .floating, so assigning it after `level` silently demotes the
        // panel from layer 25 to layer 3 — where AppKit then refuses to let it
        // overlap the menu bar at all. Level goes last.
        isFloatingPanel = true
        level = .statusBar

        self.contentView = contentView
    }

    /// AppKit constrains ordinary windows so they can't cover the menu bar.
    /// That's the right default and exactly wrong here — we *are* menu bar
    /// furniture. Return the frame we asked for.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // Never steal focus from whatever the user is actually working in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
