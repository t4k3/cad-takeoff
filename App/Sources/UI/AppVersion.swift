import Foundation

/// Version of the running app: marketing version, build number, the Git commit it was built from
/// ("+" = with uncommitted changes) and when (stamped by the "Stamp version" build phase).
enum AppVersion {
    private static func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

    static var version: String { info("CFBundleShortVersionString") ?? "?" }
    static var build: String { info("CFBundleVersion") ?? "?" }
    static var commit: String { info("FTKCommit") ?? "?" }
    static var buildDate: String { info("FTKBuildDate") ?? "?" }

    /// "v0.1.0 · 681541b".
    static var short: String { "v\(version) · \(commit)" }
    /// For tooltips and the About panel.
    static var long: String { "Versione \(version) (build \(build)) · commit \(commit) · compilata il \(buildDate)" }
}
