import Foundation

/// What one full rate-limit window costs in weighted tokens.
///
/// Anthropic doesn't publish this and Claude Code doesn't write it down, so we
/// learn it: when a `quotaLimits` rejection appears, the weighted consumption
/// over the preceding window *is* 100% of that window, observed empirically.
/// Until that happens we run on a seed constant and say so.
struct Calibration: Codable, Sendable {
    var shortCapacity: Double
    var longCapacity: Double
    /// Number of real rejection events folded in. 0 == still on the seed.
    var shortObservations: Int
    var longObservations: Int

    /// Claude's weekly limit resets on a fixed weekday and hour (the usage page
    /// says e.g. "Resets Fri 6:00 AM"), not on a rolling seven days. 1 = Sunday.
    var weeklyResetWeekday: Int = 6      // Friday
    var weeklyResetHour: Int = 6

    /// Epoch seconds of the newest rejection already folded in. Without this the
    /// same historical rejection is re-learned on every launch, dragging the
    /// capacity toward that one window a little further each time.
    var lastRejectionFolded: Double = 0

    /// Epoch seconds of the newest `utilization` observation already folded in.
    /// Same reason as above: without it, every launch re-learns the same points.
    var lastUtilizationFolded: Double = 0

    /// Hand-written so that adding a field never invalidates a saved file.
    ///
    /// Swift's synthesized `Codable` throws when a key is missing rather than
    /// falling back to the property's default, so simply adding
    /// `weeklyResetWeekday` silently reset every existing user to the seed and
    /// threw away their calibration. New fields must always be optional on read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shortCapacity = try c.decode(Double.self, forKey: .shortCapacity)
        longCapacity = try c.decode(Double.self, forKey: .longCapacity)
        shortObservations = try c.decodeIfPresent(Int.self, forKey: .shortObservations) ?? 0
        longObservations = try c.decodeIfPresent(Int.self, forKey: .longObservations) ?? 0
        weeklyResetWeekday = try c.decodeIfPresent(Int.self, forKey: .weeklyResetWeekday) ?? 6
        weeklyResetHour = try c.decodeIfPresent(Int.self, forKey: .weeklyResetHour) ?? 6
        lastRejectionFolded = try c.decodeIfPresent(Double.self, forKey: .lastRejectionFolded) ?? 0
        lastUtilizationFolded = try c.decodeIfPresent(Double.self, forKey: .lastUtilizationFolded) ?? 0
    }

    init(shortCapacity: Double, longCapacity: Double,
         shortObservations: Int, longObservations: Int,
         weeklyResetWeekday: Int = 6, weeklyResetHour: Int = 6,
         lastRejectionFolded: Double = 0, lastUtilizationFolded: Double = 0) {
        self.shortCapacity = shortCapacity
        self.longCapacity = longCapacity
        self.shortObservations = shortObservations
        self.longObservations = longObservations
        self.weeklyResetWeekday = weeklyResetWeekday
        self.weeklyResetHour = weeklyResetHour
        self.lastRejectionFolded = lastRejectionFolded
        self.lastUtilizationFolded = lastUtilizationFolded
    }

    /// Deliberately a guess, and labelled as one everywhere it surfaces.
    /// Order of magnitude only — the first real rejection replaces it.
    static let seed = Calibration(shortCapacity: 22_000_000,
                                  longCapacity: 140_000_000,
                                  shortObservations: 0,
                                  longObservations: 0,
                                  weeklyResetWeekday: 6,
                                  weeklyResetHour: 6)

    func capacity(for window: QuotaWindow) -> Double {
        window == .short ? shortCapacity : longCapacity
    }

    func observations(for window: QuotaWindow) -> Int {
        window == .short ? shortObservations : longObservations
    }

    /// Confidence rises with evidence. Drives the dashed-vs-solid meniscus.
    func confidence(for window: QuotaWindow) -> Double {
        switch observations(for: window) {
        case 0:     return 0.25          // seed only
        case 1:     return 0.6
        case 2:     return 0.75
        default:    return 0.9
        }
    }

    /// Calibrate against a figure the user read off Claude's own usage page.
    ///
    /// This beats waiting for a rate-limit rejection in every way: it needs no
    /// outage to happen, it works on the first run, and the user is reporting the
    /// same number the vendor is enforcing. `observedUsedPercent` is what their
    /// settings screen says; `weightedSum` is what we measured over the same
    /// window, so capacity falls straight out.
    mutating func calibrate(observedUsedPercent: Double, weightedSum: Double,
                            for window: QuotaWindow) {
        guard observedUsedPercent > 0, weightedSum > 0 else { return }
        let capacity = weightedSum / (observedUsedPercent / 100)
        switch window {
        case .short: shortCapacity = capacity; shortObservations = max(shortObservations, 2)
        case .long:  longCapacity = capacity;  longObservations = max(longObservations, 2)
        }
    }

    /// EWMA so one weird window can't throw the estimate off permanently.
    mutating func fold(_ observed: Double, into window: QuotaWindow) {
        guard observed > 0 else { return }
        switch window {
        case .short:
            shortCapacity = shortObservations == 0
                ? observed
                : shortCapacity * 0.7 + observed * 0.3
            shortObservations += 1
        case .long:
            longCapacity = longObservations == 0
                ? observed
                : longCapacity * 0.7 + observed * 0.3
            longObservations += 1
        }
    }
}

/// Persisted beside the app's other support files so calibration survives
/// restarts — the whole point is that it improves over weeks.
enum CalibrationStore {

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Headroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("calibration.json")
    }

    /// The app was called NotchGauge before it was called Headroom, so anyone
    /// who calibrated under the old name has a file in the old directory. Move it
    /// across once rather than silently starting them over — losing a saved
    /// calibration to a rename is exactly the kind of quiet data loss that a
    /// schema change already caused once in this project.
    private static func migrateLegacyStoreIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchGauge", isDirectory: true)
            .appendingPathComponent("calibration.json")
        guard fm.fileExists(atPath: legacy.path) else { return }
        try? fm.copyItem(at: legacy, to: url)
    }

    static func load() -> Calibration {
        migrateLegacyStoreIfNeeded()
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Calibration.self, from: data)
        else { return .seed }
        return c
    }

    static func save(_ c: Calibration) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
