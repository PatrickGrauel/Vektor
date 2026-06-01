import Foundation

/// The app's top-level modules. Shared shape with the macOS app: the same
/// six panes, the same three-bucket grouping (General / Aviation /
/// Investing), and the same per-module enable flags — so a user's
/// "Manage panes" choices feel consistent across devices.
enum Pane: String, CaseIterable, Identifiable {
    case calculator   = "Calculator"
    case timezone     = "Timezone"
    case finance      = "Finance"
    case aviation     = "Aviation"
    case map          = "METAR Map"
    case stocks       = "Stocks"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .calculator:   return "function"
        case .timezone:     return "globe"
        case .finance:      return "dollarsign.circle"
        case .aviation:     return "airplane"
        case .map:          return "map"
        case .stocks:       return "chart.line.uptrend.xyaxis"
        }
    }

    /// Always-visible panes — the universal calculator surface plus the
    /// timezone tool everyone uses. The rest are opt-in modules.
    var isCore: Bool {
        switch self {
        case .calculator, .timezone: return true
        default:                     return false
        }
    }

    var moduleDescription: String {
        switch self {
        case .finance:  return "Loan, mortgage, real-estate deal analysis, tip & split."
        case .aviation: return "METAR / TAF / ATIS, E6B flight computer, weight & balance."
        case .map:      return "Interactive airport map with live METAR overlay."
        case .stocks:   return "Score a public company against Buffett's Durable Competitive Advantage framework."
        default:        return ""
        }
    }

    /// Group used to lay panes out in the sidebar / tab list.
    var category: Category {
        switch self {
        case .calculator, .timezone, .finance: return .general
        case .aviation, .map:                  return .aviation
        case .stocks:                          return .investing
        }
    }

    enum Category: String, CaseIterable {
        case general    = "General"
        case aviation   = "Aviation"
        case investing  = "Investing"
    }
}
