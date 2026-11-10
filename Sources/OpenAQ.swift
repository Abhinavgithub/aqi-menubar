import Foundation

// MARK: - Response models (OpenAQ v3, https://docs.openaq.org)

struct OAQDatetime: Decodable { let utc: String; let local: String? }
struct OAQParameter: Decodable { let id: Int; let name: String; let units: String }
struct OAQSensor: Decodable { let id: Int; let name: String?; let parameter: OAQParameter }
struct OAQCoordinates: Decodable { let latitude: Double?; let longitude: Double? }
struct OAQLocation: Decodable {
    let id: Int
    let name: String?
    let locality: String?
    let isMobile: Bool?
    let sensors: [OAQSensor]
    let coordinates: OAQCoordinates?
    let distance: Double?
    let datetimeLast: OAQDatetime?
}
struct OAQLatest: Decodable {
    let datetime: OAQDatetime
    let value: Double?
    let sensorsId: Int
    let locationsId: Int
}
struct OAQPeriod: Decodable { let datetimeFrom: OAQDatetime?; let datetimeTo: OAQDatetime? }
struct OAQHour: Decodable { let value: Double?; let parameter: OAQParameter; let period: OAQPeriod? }
struct OAQList<T: Decodable>: Decodable { let results: [T] }

enum OpenAQError: LocalizedError {
    case unauthorized
    case rateLimited
    case noStation
    case stale
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "OpenAQ key not accepted"
        case .rateLimited: return "OpenAQ rate limit reached"
        case .noStation: return "no PM station within 25 km"
        case .stale: return "nearby stations haven't reported in the last 3 hours"
        case .http(let code): return "OpenAQ returned HTTP \(code)"
        }
    }
}

// MARK: - Pure helpers (covered by --self-test)

/// A station sensor that can supply one pollutant.
struct StationChoice: Codable, Equatable {
    let locationId: Int
    let sensorId: Int
    let name: String
    let distanceKm: Double
}

/// Cached search result, so the locations endpoint is only hit when needed.
struct StationPlan: Codable {
    let latitude: Double
    let longitude: Double
    let searchedAt: Date
    let pm25: [StationChoice]
    let pm10: [StationChoice]

    /// Search again after moving more than 2 km, or every 12 hours.
    func isOutdated(latitude lat: Double, longitude lon: Double, now: Date) -> Bool {
        Geo.distanceKm(latitude, longitude, lat, lon) > 2 || now.timeIntervalSince(searchedAt) > 12 * 3600
    }
}

struct StationReading {
    let choice: StationChoice
    let value: Double
    let time: Date
}

enum Geo {
    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0, rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * rad) * cos(lat2 * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}

enum OpenAQLogic {
    static let maxReadingAge: TimeInterval = 3 * 3600
    static let parameterNames: [Pollutant: String] = [.pm25: "pm25", .pm10: "pm10"]

    static func isMicrogramsPerCubicMetre(_ units: String) -> Bool {
        let u = units.lowercased().replacingOccurrences(of: " ", with: "")
        return ["µg/m³", "μg/m³", "ug/m3", "µg/m3", "μg/m3", "ug/m³"].contains(u)
    }

    /// Plausible concentration: finite, not negative (OpenAQ uses -999 for missing), not absurd.
    static func isValid(_ v: Double?) -> Bool {
        guard let v, v.isFinite else { return false }
        return v >= 0 && v <= 2000
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// Fixed (non-mobile) locations with a µg/m³ sensor for the pollutant that reported
    /// within the last 3 hours, nearest first.
    static func candidates(_ pollutant: Pollutant, in locations: [OAQLocation],
                           latitude: Double, longitude: Double, now: Date) -> [StationChoice] {
        let wanted = parameterNames[pollutant]!
        var out: [StationChoice] = []
        for loc in locations where loc.isMobile != true {
            guard let last = loc.datetimeLast.flatMap({ parseDate($0.utc) }),
                  now.timeIntervalSince(last) <= maxReadingAge else { continue }
            guard let sensor = loc.sensors.first(where: {
                $0.parameter.name.lowercased() == wanted && isMicrogramsPerCubicMetre($0.parameter.units)
            }) else { continue }
            let km: Double
            if let la = loc.coordinates?.latitude, let lo = loc.coordinates?.longitude {
                km = Geo.distanceKm(latitude, longitude, la, lo)
            } else if let d = loc.distance {
                km = d / 1000
            } else { continue }
            guard km <= 25.5 else { continue }
            let name = [loc.name, loc.locality].compactMap { $0 }.first ?? "Station \(loc.id)"
            out.append(StationChoice(locationId: loc.id, sensorId: sensor.id, name: name, distanceKm: km))
        }
        return out.sorted { $0.distanceKm < $1.distanceKm }
    }

    /// The latest valid, recent reading for a choice, or nil.
    static func reading(for choice: StationChoice, in latest: [OAQLatest], now: Date) -> StationReading? {
        guard let l = latest.first(where: { $0.sensorsId == choice.sensorId }),
              isValid(l.value), let t = parseDate(l.datetime.utc),
              now.timeIntervalSince(t) <= maxReadingAge else { return nil }
        return StationReading(choice: choice, value: l.value!, time: t)
    }

    /// Hourly slots (period end times, UTC hours) ending at `endSlot`, oldest first.
    static func slots(endingAt endSlot: Date, count: Int) -> [Date] {
        (0..<count).reversed().map { endSlot.addingTimeInterval(-Double($0) * 3600) }
    }

    static func floorToHour(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    /// Map hourly results onto slots by period end; invalid or missing hours are nil.
    static func series(_ hours: [OAQHour], slots: [Date]) -> [Double?] {
        var byHour: [Int: Double] = [:]
        for h in hours where isValid(h.value) && isMicrogramsPerCubicMetre(h.parameter.units) {
            guard let to = h.period?.datetimeTo.flatMap({ parseDate($0.utc) }) else { continue }
            byHour[Int((to.timeIntervalSince1970 / 3600).rounded())] = h.value!
        }
        return slots.map { byHour[Int(($0.timeIntervalSince1970 / 3600).rounded())] }
    }
}

// MARK: - Client

struct StationData {
    let pm25: StationReading?
    let pm10: StationReading?
    let slots: [Date]          // 24 hourly slots, oldest first
    let pm25Series: [Double?]
    let pm10Series: [Double?]
}

enum OpenAQClient {
    static let base = "https://api.openaq.org/v3"

    static func get<T: Decodable>(_ path: String, _ query: [URLQueryItem], key: String) async throws -> T {
        var c = URLComponents(string: base + path)!
        c.queryItems = query.isEmpty ? nil : query
        var r = URLRequest(url: c.url!, timeoutInterval: 20)
        r.setValue(key, forHTTPHeaderField: "X-API-Key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return try JSONDecoder().decode(T.self, from: data)
        case 401, 403: throw OpenAQError.unauthorized
        case 429: throw OpenAQError.rateLimited
        default: throw OpenAQError.http(code)
        }
    }

    static func search(latitude: Double, longitude: Double, key: String, now: Date) async throws -> StationPlan {
        let list: OAQList<OAQLocation> = try await get("/locations", [
            .init(name: "coordinates", value: String(format: "%.3f,%.3f", latitude, longitude)),
            .init(name: "radius", value: "25000"),
            .init(name: "limit", value: "100"),
        ], key: key)
        let plan = StationPlan(
            latitude: latitude, longitude: longitude, searchedAt: now,
            pm25: Array(OpenAQLogic.candidates(.pm25, in: list.results, latitude: latitude, longitude: longitude, now: now).prefix(4)),
            pm10: Array(OpenAQLogic.candidates(.pm10, in: list.results, latitude: latitude, longitude: longitude, now: now).prefix(4)))
        AppFiles.writeJSON(plan, to: AppFiles.stationPlanURL)
        return plan
    }

    /// Nearest station reading per pollutant (PM2.5 and PM10 may come from different stations).
    static func readings(_ plan: StationPlan, key: String, now: Date) async throws -> (StationReading?, StationReading?) {
        var latestByLocation: [Int: [OAQLatest]] = [:]
        func pick(_ choices: [StationChoice]) async throws -> StationReading? {
            for choice in choices {
                if latestByLocation[choice.locationId] == nil {
                    let l: OAQList<OAQLatest> = try await get("/locations/\(choice.locationId)/latest", [], key: key)
                    latestByLocation[choice.locationId] = l.results
                }
                if let r = OpenAQLogic.reading(for: choice, in: latestByLocation[choice.locationId]!, now: now) {
                    return r
                }
            }
            return nil
        }
        return (try await pick(plan.pm25), try await pick(plan.pm10))
    }

    static func hours(sensorId: Int, slots: [Date], key: String) async throws -> [OAQHour] {
        let f = ISO8601DateFormatter()
        let list: OAQList<OAQHour> = try await get("/sensors/\(sensorId)/hours", [
            .init(name: "datetime_from", value: f.string(from: slots.first!.addingTimeInterval(-3600))),
            .init(name: "datetime_to", value: f.string(from: slots.last!.addingTimeInterval(60))),
            .init(name: "limit", value: "100"),
        ], key: key)
        return list.results
    }

    static func stationData(latitude: Double, longitude: Double, key: String, now: Date = Date()) async throws -> StationData {
        var plan = AppFiles.readJSON(StationPlan.self, from: AppFiles.stationPlanURL)
        var searched = false
        if plan == nil || plan!.isOutdated(latitude: latitude, longitude: longitude, now: now) {
            plan = try await search(latitude: latitude, longitude: longitude, key: key, now: now)
            searched = true
        }
        var (pm25, pm10) = try await readings(plan!, key: key, now: now)
        if pm25 == nil && pm10 == nil && !searched {
            // Cached stations went stale: search once more.
            plan = try await search(latitude: latitude, longitude: longitude, key: key, now: now)
            (pm25, pm10) = try await readings(plan!, key: key, now: now)
        }
        guard pm25 != nil || pm10 != nil else {
            throw (plan!.pm25.isEmpty && plan!.pm10.isEmpty) ? OpenAQError.noStation : OpenAQError.stale
        }
        let slots = OpenAQLogic.slots(endingAt: OpenAQLogic.floorToHour(now), count: 24)
        var h25: [OAQHour] = [], h10: [OAQHour] = []
        if let pm25 { h25 = try await hours(sensorId: pm25.choice.sensorId, slots: slots, key: key) }
        if let pm10 { h10 = try await hours(sensorId: pm10.choice.sensorId, slots: slots, key: key) }
        return StationData(pm25: pm25, pm10: pm10, slots: slots,
                           pm25Series: OpenAQLogic.series(h25, slots: slots),
                           pm10Series: OpenAQLogic.series(h10, slots: slots))
    }
}
