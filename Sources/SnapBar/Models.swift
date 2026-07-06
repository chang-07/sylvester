import Foundation

// Lenient models for the SnapTrade partner API — decode only what we render.

struct STAccount: Codable, Identifiable {
    struct Balance: Codable {
        struct Total: Codable {
            var amount: Double?
            var currency: String?
        }
        var total: Total?
    }
    struct SyncStatus: Codable {
        struct Holdings: Codable {
            var initialSyncCompleted: Bool?
            var lastSuccessfulSync: String?
            enum CodingKeys: String, CodingKey {
                case initialSyncCompleted = "initial_sync_completed"
                case lastSuccessfulSync = "last_successful_sync"
            }
        }
        var holdings: Holdings?
    }

    var id: String
    var name: String?
    var number: String?
    var institutionName: String?
    var balance: Balance?
    var syncStatus: SyncStatus?
    var status: String?
    var brokerageAuthorization: String?

    enum CodingKeys: String, CodingKey {
        case id, name, number, balance, status
        case institutionName = "institution_name"
        case syncStatus = "sync_status"
        case brokerageAuthorization = "brokerage_authorization"
    }

    var displayName: String {
        let base = name ?? institutionName ?? "Account"
        if let number, !number.isEmpty {
            let tail = String(number.suffix(4))
            return "\(base) ••\(tail)"
        }
        return base
    }

    var amount: Double { balance?.total?.amount ?? 0 }
    var currency: String { balance?.total?.currency ?? "USD" }

    var lastSync: Date? {
        guard let raw = syncStatus?.holdings?.lastSuccessfulSync else { return nil }
        // API returns "2022-01-24 12:00:00+00:00" style; normalize to ISO8601.
        let iso = raw.replacingOccurrences(of: " ", with: "T")
        let fmt = ISO8601DateFormatter()
        if let d = fmt.date(from: iso) { return d }
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: iso)
    }
}

struct STCurrency: Codable {
    var code: String?
}

// GET /accounts/{id}/balances — one row per currency held as cash.
struct STBalance: Codable {
    var currency: STCurrency?
    var cash: Double?

    enum CodingKeys: String, CodingKey {
        case currency, cash
    }
}

// GET /accounts/{id}/positions — PositionSerializer shape.
struct STPosition: Codable, Identifiable {
    struct SymbolWrapper: Codable {
        struct Universal: Codable {
            var symbol: String?
            var description: String?
            var currency: STCurrency?
        }
        var symbol: Universal?
        var id: String?
        var description: String?
    }

    var symbol: SymbolWrapper?
    var price: Double?
    var units: Double?
    var fractionalUnits: Double?
    var openPnl: Double?
    var currency: STCurrency?

    enum CodingKeys: String, CodingKey {
        case symbol, price, units, currency
        case fractionalUnits = "fractional_units"
        case openPnl = "open_pnl"
    }

    var id: String { symbol?.id ?? ticker }
    var ticker: String { symbol?.symbol?.symbol ?? symbol?.description ?? "?" }
    var name: String? { symbol?.symbol?.description ?? symbol?.description }
    var quantity: Double { units ?? fractionalUnits ?? 0 }
    var value: Double { quantity * (price ?? 0) }
    var currencyCode: String {
        currency?.code ?? symbol?.symbol?.currency?.code ?? "USD"
    }
}

// GET /activities — UniversalActivitySerializer shape.
struct STActivity: Codable, Identifiable {
    struct Symbol: Codable {
        var symbol: String?
        var rawSymbol: String?
        var description: String?
        enum CodingKeys: String, CodingKey {
            case symbol, description
            case rawSymbol = "raw_symbol"
        }
    }
    struct OptionSymbol: Codable {
        var ticker: String?
    }
    struct Account: Codable {
        var id: String?
        var name: String?
        var number: String?
        var institutionName: String?
        enum CodingKeys: String, CodingKey {
            case id, name, number
            case institutionName = "institution_name"
        }
    }

    var id: String
    var symbol: Symbol?
    var optionSymbol: OptionSymbol?
    var account: Account?
    var currency: STCurrency?
    var type: String?
    var description: String?
    var amount: Double?
    var price: Double?
    var units: Double?
    var fee: Double?
    var tradeDate: String?
    var settlementDate: String?
    var institution: String?

    enum CodingKeys: String, CodingKey {
        case id, symbol, account, currency, type, description, amount, price, units, fee, institution
        case optionSymbol = "option_symbol"
        case tradeDate = "trade_date"
        case settlementDate = "settlement_date"
    }

    var ticker: String? { symbol?.symbol ?? symbol?.rawSymbol ?? optionSymbol?.ticker }
    var currencyCode: String { currency?.code ?? "USD" }

    var date: Date? {
        for raw in [tradeDate, settlementDate].compactMap({ $0 }) {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fmt.date(from: raw) { return d }
            fmt.formatOptions = [.withInternetDateTime]
            if let d = fmt.date(from: raw) { return d }
            if let d = Self.dateOnly.date(from: String(raw.prefix(10))) { return d }
        }
        return nil
    }

    private static let dateOnly: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()
}

// GET /accounts/{id}/activities envelope.
struct STActivityPage: Codable {
    var data: [STActivity]
}

// GET /authorizations — brokerage connections; may have zero accounts until first sync lands.
struct STAuthorization: Codable, Identifiable {
    struct Brokerage: Codable {
        var slug: String?
        var name: String?
    }
    var id: String
    var brokerage: Brokerage?
    var disabled: Bool?
    var createdDate: String?

    enum CodingKeys: String, CodingKey {
        case id, brokerage, disabled
        case createdDate = "created_date"
    }

    var displayName: String { brokerage?.name ?? brokerage?.slug ?? "Connection" }

    var created: Date? {
        guard let createdDate else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: createdDate) ?? ISO8601DateFormatter().date(from: createdDate)
    }
}

struct STRegisterUserResponse: Codable {
    var userId: String
    var userSecret: String
}

struct STLoginResponse: Codable {
    var redirectURI: String
}

struct STErrorResponse: Codable {
    var detail: String?
    var message: String?
    var code: AnyCodableValue?
}

// SnapTrade error `code` shows up as string or number depending on endpoint.
enum AnyCodableValue: Codable {
    case string(String), number(Double)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        self = .number(try c.decode(Double.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        }
    }
    var description: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return String(n)
        }
    }
}
