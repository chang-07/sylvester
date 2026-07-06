import Foundation

// Converts foreign-currency balances into the base currency.
// Live rates from frankfurter.dev (ECB, no key), falling back to config fxRates, then 1:1.
struct FXConverter {
    var base: String
    // Units of base currency per 1 unit of key currency.
    var multipliers: [String: Double]
    var isLive: Bool

    func toBase(_ amount: Double, from currency: String) -> Double {
        if currency == base { return amount }
        return amount * (multipliers[currency] ?? 1.0)
    }

    func hasRate(for currency: String) -> Bool {
        currency == base || multipliers[currency] != nil
    }
}

enum FXService {
    private struct FrankfurterResponse: Codable {
        var base: String
        var rates: [String: Double]
    }

    private static var cached: (converter: FXConverter, at: Date)?

    static func converter(base: String, fallback: [String: Double]?) async -> FXConverter {
        if let cached, cached.converter.base == base,
           Date().timeIntervalSince(cached.at) < 12 * 3600 {
            return cached.converter
        }
        if let live = try? await fetch(base: base) {
            let conv = FXConverter(base: base, multipliers: live, isLive: true)
            cached = (conv, Date())
            return conv
        }
        return FXConverter(base: base, multipliers: fallback ?? [:], isLive: false)
    }

    private static func fetch(base: String) async throws -> [String: Double] {
        let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=\(base)")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(FrankfurterResponse.self, from: data)
        // Frankfurter returns base-per-foreign inverted: rates[CAD]=1.37 means 1 USD = 1.37 CAD,
        // so 1 CAD = 1/1.37 USD.
        return resp.rates.compactMapValues { $0 > 0 ? 1.0 / $0 : nil }
    }
}
