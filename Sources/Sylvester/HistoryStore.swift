import Foundation

struct HistoryPoint: Codable, Identifiable {
    var t: TimeInterval
    var v: Double
    var c: String   // currency the value was computed in

    var id: TimeInterval { t }
    var date: Date { Date(timeIntervalSince1970: t) }
}

// Net worth over time only exists if we record it: one point per successful refresh,
// persisted next to the config.
enum HistoryStore {
    static let path = SylvesterConfig.dir.appendingPathComponent("history.json")
    // Backstop only. Age-based thinning holds the steady state near ~3k points plus
    // ~365/year, so this shouldn't ever actually bite.
    private static let maxPoints = 20_000

    private static let day: TimeInterval = 86_400

    static func load() -> [HistoryPoint] {
        guard let data = try? Data(contentsOf: path),
              let points = try? JSONDecoder().decode([HistoryPoint].self, from: data)
        else { return [] }
        return points
    }

    static func append(value: Double, currency: String, to points: inout [HistoryPoint]) {
        let now = Date().timeIntervalSince1970
        // Rate-limit to one point per minute unless the value actually moved —
        // replacing the last point here would let a fast poll loop slide a single
        // point forward forever and history would never accumulate.
        if let last = points.last, now - last.t < 60, abs(last.v - value) < 0.005, last.c == currency {
            return
        }
        points.append(HistoryPoint(t: now, v: value, c: currency))
        points = thinned(points, now: now)
        if points.count > maxPoints {
            points.removeFirst(points.count - maxPoints)
        }
        save(points)
    }

    // Thin by age rather than dropping the oldest points. A flat cap silently starts
    // eating the long-term record after ~7 months at a 15-minute cadence — exactly the
    // history a net-worth chart exists to show. Recent detail is what's worth keeping at
    // full resolution; a year back, one point a day says everything.
    //
    //   < 7 days    full resolution (every refresh)
    //   7–90 days   one point per hour
    //   > 90 days   one point per day
    //
    // Buckets are keyed per currency so switching baseCurrency can't thin away the
    // series the chart is currently filtered to.
    static func thinned(_ points: [HistoryPoint], now: TimeInterval) -> [HistoryPoint] {
        var keptKeys = Set<String>()
        var result: [HistoryPoint] = []
        result.reserveCapacity(points.count)
        // Walk newest-first, keeping the first point seen in each bucket, so a bucket is
        // represented by its closing value rather than its opening one.
        for point in points.reversed() {
            let age = now - point.t
            let bucket: TimeInterval
            switch age {
            case ..<(7 * day): bucket = 0        // keep everything
            case ..<(90 * day): bucket = 3_600   // hourly
            default: bucket = day                // daily
            }
            if bucket == 0 {
                result.append(point)
                continue
            }
            let key = "\(point.c)|\(Int(point.t / bucket))"
            if keptKeys.insert(key).inserted {
                result.append(point)
            }
        }
        return result.reversed()
    }

    private static func save(_ points: [HistoryPoint]) {
        try? FileManager.default.createDirectory(at: SylvesterConfig.dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(points) {
            try? data.write(to: path, options: .atomic)
        }
    }
}

// Tracks when each activity id was first seen, so the feed can flag fresh arrivals.
// First-ever load is baselined (firstSeen=0) so existing history doesn't all read as new.
struct SeenActivities: Codable {
    var firstSeen: [String: TimeInterval] = [:]
    var baselined = false
}

enum SeenActivitiesStore {
    static let path = SylvesterConfig.dir.appendingPathComponent("seen_activities.json")

    static func load() -> SeenActivities {
        guard let data = try? Data(contentsOf: path),
              let seen = try? JSONDecoder().decode(SeenActivities.self, from: data)
        else { return SeenActivities() }
        return seen
    }

    static func save(_ seen: SeenActivities) {
        try? FileManager.default.createDirectory(at: SylvesterConfig.dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(seen) {
            try? data.write(to: path, options: .atomic)
        }
    }
}
