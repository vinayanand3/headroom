import Foundation

/// Claude Code writes exact per-message token counts and never writes the limit
/// those counts are measured against, so this provider computes a numerator and
/// has to learn the denominator — see `Calibration`.
///
/// **Do not binary-search these files by timestamp.** An earlier version did, on
/// the assumption that an append-only JSONL transcript is chronological. It
/// isn't: measured on real data, 86% of records arrive out of order, with
/// backward jumps of up to 21 hours, because sidechains, resumed sessions and
/// compaction all interleave. The search landed near the end of the file and
/// silently under-counted the weekly total by 4.5x.
///
/// So instead: read each file once, then only the bytes appended since last time.
/// Ordering never matters, the first scan is the only expensive one, and a
/// refresh during a live session costs almost nothing.
final class ClaudeProvider: UsageProvider, @unchecked Sendable {

    let id: ProviderID = .claude

    private let lock = NSLock()

    private struct FileState {
        var inode: UInt64
        var offset: UInt64
    }

    private var fileStates: [String: FileState] = [:]
    private var entries: [(date: Date, weight: Double)] = []
    private var seenRequestIds: Set<String> = []
    private var rejections: [(date: Date, window: QuotaWindow)] = []

    /// Keep a little more than a week so a calendar window near its boundary is
    /// still fully covered.
    private let retention: TimeInterval = 9 * 24 * 3600
    private static let sessionLength: TimeInterval = 5 * 3600

    private var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    func watchRoots() -> [URL] { [projectsRoot] }

    func isInstalled() -> Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: projectsRoot.path, isDirectory: &isDir)
        return ok && isDir.boolValue
    }

    // MARK: - Weights

    /// Rate limits aren't a raw token count — a cached read and an output token
    /// cost very different amounts against the budget. These mirror relative
    /// pricing, which is the best available proxy for a formula Anthropic hasn't
    /// published. They're the main reason a calibration drifts over time: as the
    /// mix of token kinds shifts, our proxy tracks the real meter imperfectly.
    private static let wInput = 1.0
    private static let wCacheWrite = 1.25
    private static let wCacheRead = 0.1
    private static let wOutput = 5.0

    private static func tierMultiplier(_ model: String?) -> Double {
        guard let m = model?.lowercased() else { return 1 }
        if m.contains("opus")   { return 3.0 }
        if m.contains("sonnet") { return 1.0 }
        if m.contains("haiku")  { return 0.3 }
        return 1
    }

    // MARK: - Snapshot

    func snapshot() throws -> Snapshot {
        guard isInstalled() else {
            return Snapshot(provider: id, readings: allUnavailable("Claude Code not installed"),
                            capturedAt: Date(), sourceDate: nil, planLabel: nil, rawWeighted: nil)
        }

        lock.lock()
        defer { lock.unlock() }

        ingestNewBytes()

        let now = Date()
        entries.removeAll { now.timeIntervalSince($0.date) > retention }
        entries.sort { $0.date < $1.date }

        var calibration = CalibrationStore.load()

        // The 5-hour limit is a *session* window, not a rolling one: it opens on
        // your first message and runs five hours. Reconstructing those blocks and
        // checking the inferred reset against Claude's own "resets in 2 hr 37 min"
        // agreed to within four minutes.
        let session = currentSession(now: now)
        let weekStart = weeklyWindowStart(now: now, calibration: calibration)
        let weekSum = entries.filter { $0.date >= weekStart }.reduce(0) { $0 + $1.weight }

        learn(&calibration, sessionSum: session.sum, weekSum: weekSum, weekStart: weekStart)

        var readings: [QuotaWindow: Reading] = [:]
        readings[.short] = reading(sum: session.sum, window: .short,
                                   calibration: calibration, resetsAt: session.resetsAt)
        readings[.long] = reading(sum: weekSum, window: .long,
                                  calibration: calibration,
                                  resetsAt: weekStart.addingTimeInterval(7 * 24 * 3600))

        return Snapshot(provider: id,
                        readings: readings,
                        capturedAt: now,
                        sourceDate: entries.last?.date,
                        planLabel: calibration.shortObservations > 0 ? "calibrated" : "estimated",
                        rawWeighted: [.short: session.sum, .long: weekSum])
    }

    // MARK: - Windows

    /// Walks the blocks forward: a block opens at the first message after the
    /// previous one expired. Returns the block we're currently inside, or zero if
    /// the last one has already lapsed.
    private func currentSession(now: Date) -> (sum: Double, resetsAt: Date?) {
        var blockStart: Date?
        var sum = 0.0
        for e in entries {
            if let start = blockStart, e.date < start.addingTimeInterval(Self.sessionLength) {
                sum += e.weight
            } else {
                blockStart = e.date
                sum = e.weight
            }
        }
        guard let start = blockStart else { return (0, nil) }
        let resets = start.addingTimeInterval(Self.sessionLength)
        // Lapsed window: the quota is fresh again, whatever the old block held.
        return now >= resets ? (0, nil) : (sum, resets)
    }

    /// Claude's weekly limit is a fixed calendar window ("Resets Fri 6:00 AM"),
    /// not a rolling seven days. Modelling it as rolling counts usage from before
    /// the last reset.
    private func weeklyWindowStart(now: Date, calibration: Calibration) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.weekday = calibration.weeklyResetWeekday
        components.hour = calibration.weeklyResetHour
        components.minute = 0
        components.second = 0
        return calendar.nextDate(after: now, matching: components,
                                 matchingPolicy: .nextTimePreservingSmallerComponents,
                                 direction: .backward)
            ?? now.addingTimeInterval(-7 * 24 * 3600)
    }

    // MARK: - Calibration from observed rejections

    private func learn(_ calibration: inout Calibration,
                       sessionSum: Double, weekSum: Double, weekStart: Date) {
        var changed = false
        var newest = calibration.lastRejectionFolded
        for r in rejections {
            // Never fold the same rejection twice — it would drag capacity toward
            // that one window a little further on every launch.
            guard r.date.timeIntervalSince1970 > calibration.lastRejectionFolded else { continue }
            // A rejection is ground truth: whatever was spent in that window was
            // 100% of it. Only usable if our retained data covers the whole span.
            let span: TimeInterval = r.window == .short ? Self.sessionLength : 7 * 24 * 3600
            let from = r.date.addingTimeInterval(-span)
            guard let oldest = entries.first?.date, from >= oldest else { continue }
            let observed = entries
                .filter { $0.date >= from && $0.date <= r.date }
                .reduce(0) { $0 + $1.weight }
            guard observed > 0 else { continue }
            calibration.fold(observed, into: r.window)
            newest = max(newest, r.date.timeIntervalSince1970)
            changed = true
        }
        rejections.removeAll()
        if changed {
            calibration.lastRejectionFolded = newest
            CalibrationStore.save(calibration)
        }
    }

    private func reading(sum: Double, window: QuotaWindow,
                         calibration: Calibration, resetsAt: Date?) -> Reading {
        let capacity = calibration.capacity(for: window)
        guard capacity > 0 else { return .unavailable(reason: "not calibrated") }
        // Never `.authoritative` — we did not measure this, we inferred it.
        return .estimated(percent: min(100, max(0, sum / capacity * 100)),
                          confidence: calibration.confidence(for: window),
                          resetsAt: resetsAt)
    }

    private func allUnavailable(_ reason: String) -> [QuotaWindow: Reading] {
        Dictionary(uniqueKeysWithValues: QuotaWindow.allCases.map { ($0, .unavailable(reason: reason)) })
    }

    // MARK: - Incremental ingest

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let quotaMarker = Data("quotaLimits".utf8)

    private func ingestNewBytes() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-retention)

        guard let walker = fm.enumerator(at: projectsRoot,
                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { return }

        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            // A file untouched since the cutoff can't hold records after it.
            guard mod >= cutoff else { continue }

            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
            else { continue }

            // Resume where we left off, unless the file was rotated or truncated.
            var start: UInt64 = 0
            if let state = fileStates[url.path], state.inode == inode, size >= state.offset {
                start = state.offset
            }
            guard size > start else {
                fileStates[url.path] = FileState(inode: inode, offset: size)
                continue
            }

            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: start)
            guard let blob = try? handle.readToEnd(), !blob.isEmpty else { continue }

            // Stop at the last newline: the tail may be a half-written record.
            guard let lastNewline = blob.lastIndex(of: 0x0A) else {
                continue                       // no complete line yet; retry later
            }
            let complete = blob[blob.startIndex...lastNewline]
            parse(complete)
            fileStates[url.path] = FileState(inode: inode,
                                             offset: start + UInt64(complete.count))
        }
    }

    private func parse(_ blob: Data.SubSequence) {
        let decoder = JSONDecoder()
        for line in blob.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let data = Data(line)
            let hasUsage = data.range(of: Self.usageMarker) != nil
            let hasQuota = data.range(of: Self.quotaMarker) != nil
            guard hasUsage || hasQuota else { continue }
            guard let row = try? decoder.decode(ClaudeRow.self, from: data),
                  let date = row.date else { continue }

            if let quota = row.quotaLimits, quota.status == "rejected", let w = quota.window {
                rejections.append((date, w))
            }
            guard let usage = row.message?.usage else { continue }
            // Retries re-log the same request; don't bill it twice.
            if let rid = row.requestId {
                guard seenRequestIds.insert(rid).inserted else { continue }
            }
            entries.append((date, weight(of: usage, model: row.message?.model)))
        }
    }

    private func weight(of u: ClaudeUsage, model: String?) -> Double {
        let base = Double(u.inputTokens ?? 0) * Self.wInput
            + Double(u.cacheCreationInputTokens ?? 0) * Self.wCacheWrite
            + Double(u.cacheReadInputTokens ?? 0) * Self.wCacheRead
            + Double(u.outputTokens ?? 0) * Self.wOutput
        return base * Self.tierMultiplier(model)
    }
}

// MARK: - Wire format

private struct ClaudeRow: Decodable {
    let timestamp: String?
    let requestId: String?
    let message: ClaudeMessage?
    let quotaLimits: ClaudeQuota?

    var date: Date? {
        guard let timestamp else { return nil }
        return ISO8601DateFormatter.withFractional.date(from: timestamp)
            ?? ISO8601DateFormatter.plain.date(from: timestamp)
    }
}

private struct ClaudeMessage: Decodable {
    let model: String?
    let usage: ClaudeUsage?
}

struct ClaudeUsage: Decodable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

private struct ClaudeQuota: Decodable {
    let status: String?
    let rateLimitType: String?
    let resetsAt: Double?

    var window: QuotaWindow? {
        switch rateLimitType {
        case "five_hour": return .short
        case "weekly", "opus_weekly": return .long
        default: return nil
        }
    }
}
