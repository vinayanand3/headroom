import AppKit

if CommandLine.arguments.contains("--probe") {
    Probe.run()
    exit(0)
}

// main.swift's top level is not main-actor isolated, but it does run on the
// main thread. `app.run()` blocks inside this closure for the process lifetime,
// which also keeps `delegate` alive — NSApplication.delegate is a weak ref.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Agent app: no Dock icon, no app menu. Mirrors LSUIElement for CLI runs.
    app.setActivationPolicy(.accessory)
    app.run()
}
