import Foundation

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    /// Roots handed to the shared FSEvents stream.
    func watchRoots() -> [URL]
    func isInstalled() -> Bool
    /// False for a provider that can be detected but whose usage can't be read
    /// (Antigravity, for one). Such a provider gets a one-line explanation in the
    /// menu instead of empty gauges.
    var canReportUsage: Bool { get }
    /// Never throws for "no data" — that is a `.unavailable` reading, not an error.
    func snapshot() throws -> Snapshot
}

extension UsageProvider {
    var canReportUsage: Bool { true }
}
