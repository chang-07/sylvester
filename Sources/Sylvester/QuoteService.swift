import Foundation

struct Quote {
    var price: Double
    var prevClose: Double

    var dayChangePct: Double? {
        prevClose > 0 ? (price / prevClose - 1) * 100 : nil
    }
}

// Day-change quotes from Yahoo's chart endpoint (no key; universal tickers like
// XEQT.TO are already Yahoo-shaped). Missing/unresolvable symbols just drop out.
enum QuoteService {
    private struct ChartResponse: Codable {
        struct Chart: Codable {
            struct Result: Codable {
                struct Meta: Codable {
                    var regularMarketPrice: Double?
                    var chartPreviousClose: Double?
                    var previousClose: Double?
                }
                var meta: Meta?
            }
            var result: [Result]?
        }
        var chart: Chart?
    }

    static func fetch(_ symbols: [String]) async -> [String: Quote] {
        await withTaskGroup(of: (String, Quote?).self) { group in
            for symbol in symbols {
                group.addTask { (symbol, try? await fetchOne(symbol)) }
            }
            var quotes: [String: Quote] = [:]
            for await (symbol, quote) in group {
                if let quote { quotes[symbol] = quote }
            }
            return quotes
        }
    }

    private static func fetchOne(_ symbol: String) async throws -> Quote? {
        let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(escaped)?range=1d&interval=1d") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let meta = try JSONDecoder().decode(ChartResponse.self, from: data).chart?.result?.first?.meta
        guard let price = meta?.regularMarketPrice,
              let prev = meta?.previousClose ?? meta?.chartPreviousClose, prev > 0
        else { return nil }
        return Quote(price: price, prevClose: prev)
    }
}
