import Foundation
import Combine

enum Lang: String, CaseIterable, Identifiable {
    case en
    case fr
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .en: return "English"
        case .fr: return "Français"
        }
    }
    var code: String { rawValue.uppercased() }
}

/// Which CBTC standard's terminology the UI presents. The app follows the
/// UI language by default (French cohorts see the European EN 62290
/// wording; English sees IEEE 1474), overridable via `SET STANDARD`.
enum SafetyStandard: String, CaseIterable, Identifiable {
    case ieee
    case en62290
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ieee:    return "IEEE 1474.1"
        case .en62290: return "EN 62290"
        }
    }
}

@MainActor
final class AppLanguage: ObservableObject {
    @Published var current: Lang
    /// Explicit operator override (SET STANDARD IEEE|EN62290). When nil the
    /// terminology follows `current`: FR → EN 62290, EN → IEEE 1474.
    @Published var standardOverride: SafetyStandard?

    init(initial: Lang = AppLanguage.detect()) {
        self.current = initial
        self.standardOverride = nil
    }

    /// The CBTC standard currently in effect, honouring an explicit
    /// override and otherwise following the UI language.
    var standard: SafetyStandard {
        standardOverride ?? (current == .fr ? .en62290 : .ieee)
    }

    /// Looks up a safety term that differs by standard. `base` is a key
    /// stem; the resolved key is "<base>.<ieee|en62290>", localized to
    /// `current`.
    func safetyTerm(_ base: String) -> String {
        Strings.lookup("\(base).\(standard.rawValue)", lang: current)
    }

    nonisolated private static func detect() -> Lang {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("fr") ? .fr : .en
    }

    func t(_ key: String) -> String {
        Strings.lookup(key, lang: current)
    }

    func t(_ key: String, _ args: CVarArg...) -> String {
        let raw = Strings.lookup(key, lang: current)
        return String(format: raw, arguments: args)
    }

    func cycle() {
        let all = Lang.allCases
        guard let idx = all.firstIndex(of: current) else { return }
        current = all[(idx + 1) % all.count]
    }
}
