import Foundation

/// Reads Codex's server-authoritative quota straight out of the rollout logs.
///
/// Two things make this non-obvious, both learned the hard way from real files:
///
/// 1. Session files get enormous (72 MB observed). Never parse forward — seek to
///    the end and walk backward.
/// 2. Codex emits more than one kind of `rate_limits`. `limit_id: "codex"` carries
///    the `primary`/`secondary` percentages; `limit_id: "premium"` carries credits
///    and leaves both **null**. Taking the last `token_count` event therefore shows
///    an empty gauge about as often as not. We scan backward for the last event
///    that actually has a `primary`.
struct CodexProvider: UsageProvider {

    let id: ProviderID = .codex

    private var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func watchRoots() -> [URL] { [sessionsRoot] }

    func isInstalled() -> Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: sessionsRoot.path, isDirectory: &isDir)
        return ok && isDir.boolValue
    }

    func snapshot() throws -> Snapshot {
        guard isInstalled() else {
            return Snapshot(provider: id, readings: unavailable("Codex not installed"),
                            capturedAt: Date(), sourceDate: nil, planLabel: nil, rawWeighted: nil)
        }
        let files = newestRollouts()
        guard !files.isEmpty else {
            return Snapshot(provider: id, readings: unavailable("No sessions yet"),
                            capturedAt: Date(), sourceDate: nil, planLabel: nil, rawWeighted: nil)
        }
        // The freshest file may hold no quota event at all (a session that only
        // just started), so fall through to the next rather than reporting
        // nothing when perfectly good data sits one file over.
        var found: Hit?
        for file in files {
            if let hit = try? lastQuotaEvent(in: file) { found = hit; break }
        }
        guard let hit = found else {
            return Snapshot(provider: id, readings: unavailable("No quota event in recent sessions"),
                            capturedAt: Date(), sourceDate: nil, planLabel: nil, rawWeighted: nil)
        }

        var readings: [QuotaWindow: Reading] = [:]
        readings[.short] = reading(from: hit.limits.primary)
        readings[.long]  = reading(from: hit.limits.secondary)

        return Snapshot(provider: id,
                        readings: readings,
                        capturedAt: Date(),
                        sourceDate: hit.date,
                        planLabel: hit.limits.planType,
                        rawWeighted: nil)
    }

    // MARK: - Mapping

    private func reading(from w: RateWindow?) -> Reading {
        guard let w, let pct = w.usedPercent else { return .unavailable(reason: "not reported") }
        let reset = w.resetsAt.map { Date(timeIntervalSince1970: $0) }

        // These logs only advance while Codex is running. Once `resetsAt` passes,
        // the window has rolled over server-side and the number on disk is not
        // just stale — it is wrong in the dangerous direction. A cached 100%
        // would say "you are blocked" to someone with a full fresh window.
        // We can't know the new value until Codex next writes, so say so.
        if let reset, reset <= Date() {
            return .unavailable(reason: "window reset — run Codex to refresh")
        }

        // Codex computes this server-side. It is a fact, not an inference.
        return .authoritative(percent: max(0, min(100, pct)), resetsAt: reset)
    }

    private func unavailable(_ reason: String) -> [QuotaWindow: Reading] {
        Dictionary(uniqueKeysWithValues: QuotaWindow.allCases.map { ($0, .unavailable(reason: reason)) })
    }

    // MARK: - Finding the newest session

    /// Newest rollout files by **modification time**, not by directory name.
    ///
    /// The obvious optimisation is to sort the `sessions/YYYY/MM/DD` directories
    /// descending and take the first one with files, since the names are
    /// zero-padded and therefore chronological. That is wrong, and it fails
    /// silently: a *resumed* session keeps appending to its original file, which
    /// still lives in the directory for the day it was created. Resume a
    /// four-day-old session and the freshest quota data on disk sits in the
    /// oldest-looking folder, while the name-sorted winner is days stale — stale
    /// enough that its window has expired, so the gauge reports "window reset"
    /// while Codex is running right now.
    ///
    /// So: stat the files in the most recent handful of day directories and sort
    /// by mtime. Bounded, so this stays a few dozen stats rather than thousands.
    private func newestRollouts(limit: Int = 5) -> [URL] {
        let fm = FileManager.default
        func kids(_ url: URL) -> [URL] {
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            return items
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }

        // Walk the most recent day directories by name — that part is still a
        // fine way to *find candidates* cheaply. It just can't pick the winner.
        var days: [URL] = []
        outer: for year in kids(sessionsRoot) {
            for month in kids(year) {
                for day in kids(month) {
                    days.append(day)
                    if days.count >= 12 { break outer }
                }
            }
        }

        var candidates: [(url: URL, modified: Date)] = []
        for day in days {
            let files = ((try? fm.contentsOfDirectory(at: day,
                            includingPropertiesForKeys: [.contentModificationDateKey],
                            options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
            for f in files {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                candidates.append((f, m))
            }
        }
        return candidates.sorted { $0.modified > $1.modified }.prefix(limit).map(\.url)
    }

    // MARK: - Reverse tail

    private struct Hit { let limits: RateLimits; let date: Date? }

    private static let marker = Data("token_count".utf8)

    private func lastQuotaEvent(in url: URL) throws -> Hit? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        guard size > 0 else { return nil }

        var window: UInt64 = 256 * 1024
        let ceiling: UInt64 = 8 * 1024 * 1024

        while true {
            let take = min(window, size)
            try handle.seek(toOffset: size - take)
            guard var data = try handle.read(upToCount: Int(take)), !data.isEmpty else { return nil }

            // If we started mid-file we almost certainly cut a line in half; drop it.
            if take < size, let nl = data.firstIndex(of: 0x0A) {
                data = data.subdata(in: (nl + 1)..<data.endIndex)
            }
            if let hit = scanBackward(data) { return hit }

            if take >= size || window >= ceiling { return nil }
            window *= 4
        }
    }

    private func scanBackward(_ blob: Data) -> Hit? {
        let lines = blob.split(separator: 0x0A, omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        for line in lines.reversed() {
            let data = Data(line)
            // Cheap byte test before paying for JSON on a 72 MB file's worth of lines.
            guard data.range(of: Self.marker) != nil else { continue }
            guard let row = try? decoder.decode(RolloutLine.self, from: data),
                  row.payload?.type == "token_count",
                  let limits = row.payload?.rateLimits,
                  limits.primary?.usedPercent != nil          // <-- the "premium" guard
            else { continue }
            return Hit(limits: limits, date: row.date)
        }
        return nil
    }
}

// MARK: - Wire format

private struct RolloutLine: Decodable {
    let timestamp: String?
    let payload: Payload?

    var date: Date? {
        guard let timestamp else { return nil }
        return ISO8601DateFormatter.withFractional.date(from: timestamp)
            ?? ISO8601DateFormatter.plain.date(from: timestamp)
    }
}

private struct Payload: Decodable {
    let type: String?
    let rateLimits: RateLimits?
}

struct RateLimits: Decodable, Sendable {
    let limitId: String?
    let planType: String?
    let primary: RateWindow?
    let secondary: RateWindow?
}

struct RateWindow: Decodable, Sendable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Double?
}

extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain = ISO8601DateFormatter()
}
