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
    static let path = SnapBarConfig.dir.appendingPathComponent("history.json")
    private static let maxPoints = 20_000

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
        if points.count > maxPoints {
            points.removeFirst(points.count - maxPoints)
        }
        save(points)
    }

    private static func save(_ points: [HistoryPoint]) {
        try? FileManager.default.createDirectory(at: SnapBarConfig.dir, withIntermediateDirectories: true)
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
    static let path = SnapBarConfig.dir.appendingPathComponent("seen_activities.json")

    static func load() -> SeenActivities {
        guard let data = try? Data(contentsOf: path),
              let seen = try? JSONDecoder().decode(SeenActivities.self, from: data)
        else { return SeenActivities() }
        return seen
    }

    static func save(_ seen: SeenActivities) {
        try? FileManager.default.createDirectory(at: SnapBarConfig.dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(seen) {
            try? data.write(to: path, options: .atomic)
        }
    }
}
