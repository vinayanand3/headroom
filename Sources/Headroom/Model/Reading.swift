import Foundation

/// Which rolling window a reading describes.
enum QuotaWindow: String, CaseIterable, Sendable {
    case short   // ~5 hours
    case long    // ~1 week

    var shortLabel: String { self == .short ? "5H" : "WK" }
}

/// How much we actually know about a number.
///
/// Deliberately not a single `percent: Double`. Codex hands us a
/// server-authoritative percentage; Claude hands us raw token consumption and
/// hides the denominator. Collapsing those into one field is how these tools
/// end up inventing numbers.
enum Reading: Sendable {
    case authoritative(percent: Double, resetsAt: Date?)
    case estimated(percent: Double, confidence: Double, resetsAt: Date?)
    case unavailable(reason: String)

    /// Percent of the window **consumed**. This is what every source reports,
    /// so it's what we store — but almost nothing should display it directly.
    var percentUsed: Double? {
        switch self {
        case .authoritative(let p, _):  return p
        case .estimated(let p, _, _):   return p
        case .unavailable:              return nil
        }
    }

    /// Percent of the window **left**. This is what the UI shows, everywhere,
    /// without exception.
    ///
    /// Mixing the two is not a cosmetic slip: a capsule filled to "remaining"
    /// beside a label reading "used" tells the user two contradictory things at
    /// once, and they can't tell which. One polarity, one meaning.
    var percentRemaining: Double? {
        percentUsed.map { 100 - $0 }
    }

    var resetsAt: Date? {
        switch self {
        case .authoritative(_, let r):  return r
        case .estimated(_, _, let r):   return r
        case .unavailable:              return nil
        }
    }

    /// Estimated readings render with a dashed meniscus so the user can always
    /// tell an inference from a fact.
    var isExact: Bool {
        if case .authoritative = self { return true }
        return false
    }
}

struct Snapshot: Sendable {
    let provider: ProviderID
    let readings: [QuotaWindow: Reading]
    let capturedAt: Date
    /// Timestamp of the underlying source event, not of our read.
    let sourceDate: Date?
    let planLabel: String?
    /// Raw weighted consumption per window, for providers that compute one.
    /// Lets the user calibrate against a number they can actually see.
    let rawWeighted: [QuotaWindow: Double]?

    /// A reading whose source event is hours old is not a current reading.
    var staleness: TimeInterval? {
        guard let sourceDate else { return nil }
        return Date().timeIntervalSince(sourceDate)
    }
}

enum ProviderID: String, Sendable, CaseIterable {
    case codex
    case claude
    case gemini

    var displayName: String {
        switch self {
        case .codex:  return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }
}
