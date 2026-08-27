import Foundation

/// `Headroom --probe` — prints what the providers can actually see and exits.
/// Kept permanently: when a vendor changes a log format, this is the fastest way
/// to find out what broke.
enum Probe {
    static func run() {
        let providers: [any UsageProvider] = [CodexProvider(), ClaudeProvider()]
        for p in providers {
            print("── \(p.id.displayName) ──")
            print("installed: \(p.isInstalled())")
            guard p.isInstalled() else { continue }
            let t0 = Date()
            do {
                let snap = try p.snapshot()
                print(String(format: "parsed in %.1f ms", Date().timeIntervalSince(t0) * 1000))
                print("plan: \(snap.planLabel ?? "—")")
                if let s = snap.staleness { print(String(format: "source age: %.1f min", s / 60)) }
                if let raw = snap.rawWeighted {
                    for w in QuotaWindow.allCases where raw[w] != nil {
                        print(String(format: "raw weighted %@: %.0f", w.shortLabel, raw[w]!))
                    }
                }
                for w in QuotaWindow.allCases {
                    guard let r = snap.readings[w] else { continue }
                    switch r {
                    case .authoritative(let pct, let reset):
                        var line = String(format: "  %@  %3.0f%%  exact", w.shortLabel, pct)
                        if let reset {
                            line += "  resets \(RelativeDateTimeFormatter().localizedString(for: reset, relativeTo: Date()))"
                        }
                        print(line)
                    case .estimated(let pct, let c, _):
                        print(String(format: "  %@  %3.0f%%  est (conf %.2f)", w.shortLabel, pct, c))
                    case .unavailable(let why):
                        print("  \(w.shortLabel)    —   \(why)")
                    }
                }
            } catch {
                print("ERROR: \(error)")
            }
        }
    }
}
