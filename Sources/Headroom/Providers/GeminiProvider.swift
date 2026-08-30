import Foundation

/// Gemini, insofar as there is anything to read.
///
/// There are two very different Google things people mean by "Gemini":
///
/// - The **Gemini CLI**, which keeps per-session state under `~/.gemini`.
/// - **Antigravity**, Google's IDE, which also lives under `~/.gemini` and is
///   what's usually there when the CLI isn't.
///
/// Both Google apps *show* quota and neither *stores* it, which was verified
/// rather than assumed:
///
/// - **Antigravity** (Settings → Models) lists "Weekly Limit Remaining" and
///   "Five Hour Limit Remaining". Its stores hold conversations, caches, leveldb
///   and a `state.vscdb` whose only quota-shaped key, `modelCredits`, decodes to
///   credit sentinels — not percentages.
/// - **The Gemini desktop app** (Settings → Usage limits) shows "Current usage"
///   and "Weekly limit". It keeps no LocalStorage or IndexedDB, and its URL cache
///   holds 56 entries, all fonts.
///
/// Both panes carry a refresh button and an "Updated just now" line, which is the
/// tell: the numbers are fetched live per view. Reading them would mean calling
/// Google's endpoint with the user's OAuth token — the undocumented-API route
/// this project declines to take for Claude, and declines here for the same
/// reason.
///
/// This provider therefore does detection honestly and stops there: it says
/// which of the two it found and why there's no number, rather than inventing
/// one or silently vanishing from the menu.
struct GeminiProvider: UsageProvider {

    let id: ProviderID = .gemini

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var geminiRoot: URL { home.appendingPathComponent(".gemini", isDirectory: true) }

    enum Install {
        case none
        case antigravityOnly
        case desktopApp
        case cli(URL)
    }

    /// Looks where a CLI actually lands, rather than trusting `PATH` — a menu bar
    /// agent inherits launchd's environment, not the user's shell.
    var install: Install {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin",
                          ".npm-global/bin", ".local/bin", ".bun/bin"]
        for dir in candidates {
            let base = dir.hasPrefix("/") ? URL(fileURLWithPath: dir)
                                          : home.appendingPathComponent(dir, isDirectory: true)
            let exe = base.appendingPathComponent("gemini")
            if FileManager.default.isExecutableFile(atPath: exe.path) { return .cli(exe) }
        }
        if FileManager.default.fileExists(atPath: "/Applications/Gemini.app") { return .desktopApp }
        let antigravity = geminiRoot.appendingPathComponent("antigravity", isDirectory: true)
        if FileManager.default.fileExists(atPath: antigravity.path) { return .antigravityOnly }
        return .none
    }

    /// Deliberately true for Antigravity too. "Installed but unreadable" is a
    /// different and more useful thing to tell someone than "absent".
    func isInstalled() -> Bool {
        if case .none = install { return false }
        return true
    }

    var canReportUsage: Bool { false }

    func watchRoots() -> [URL] {
        guard case .cli = install else { return [] }
        return [geminiRoot]
    }

    func snapshot() throws -> Snapshot {
        let reason: String
        switch install {
        case .none:
            reason = "not installed"
        case .desktopApp:
            reason = "usage not stored on disk"
        case .antigravityOnly:
            reason = "Antigravity: not stored on disk"
        case .cli:
            // Detection is verified; the log format is not. Shipping an untested
            // parser would produce confident wrong numbers, which is worse than
            // an honest blank.
            reason = "CLI found, not yet supported"
        }
        return Snapshot(provider: id,
                        readings: Dictionary(uniqueKeysWithValues:
                            QuotaWindow.allCases.map { ($0, Reading.unavailable(reason: reason)) }),
                        capturedAt: Date(),
                        sourceDate: nil,
                        planLabel: nil,
                        rawWeighted: nil)
    }
}
