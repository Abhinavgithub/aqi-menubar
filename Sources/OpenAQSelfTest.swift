import Foundation

/// OpenAQ parsing, station selection and fallback checks, using small samples shaped
/// like the real v3 responses. Returns the number of failures it found on its own
/// (checks reported through `check` are counted by the caller).
enum OpenAQSelfTest {
    static let now = OpenAQLogic.parseDate("2026-11-10T17:20:00Z")!

    static let locationsJSON = """
    {"meta":{"name":"openaq-api","website":"/","page":1,"limit":100,"found":4},"results":[
     {"id":10,"name":"Far Station","locality":null,"timezone":"UTC","isMobile":false,"isMonitor":true,
      "sensors":[{"id":101,"name":"pm25 µg/m³","parameter":{"id":2,"name":"pm25","units":"µg/m³","displayName":"PM2.5"}},
                 {"id":102,"name":"pm10 µg/m³","parameter":{"id":1,"name":"pm10","units":"µg/m³","displayName":"PM10"}}],
      "coordinates":{"latitude":10.10,"longitude":20.10},"bounds":[20.1,10.1,20.1,10.1],"distance":14800.0,
      "datetimeFirst":{"utc":"2019-01-01T00:00:00Z","local":"2019-01-01T05:30:00Z"},
      "datetimeLast":{"utc":"2026-11-10T17:00:00Z","local":"2026-11-10T17:00:00Z"}},
     {"id":20,"name":"Near Station","locality":"Sample City","timezone":"UTC","isMobile":false,"isMonitor":true,
      "sensors":[{"id":201,"name":"pm25 µg/m³","parameter":{"id":2,"name":"pm25","units":"µg/m³","displayName":"PM2.5"}},
                 {"id":203,"name":"no2 ppb","parameter":{"id":7,"name":"no2","units":"ppb","displayName":"NO₂"}}],
      "coordinates":{"latitude":10.0135,"longitude":20.00},"bounds":[20.0,10.0135,20.0,10.0135],"distance":1500.0,
      "datetimeFirst":null,"datetimeLast":{"utc":"2026-11-10T16:00:00Z","local":"2026-11-10T16:00:00Z"}},
     {"id":30,"name":"Stale Station","locality":null,"timezone":"UTC","isMobile":false,"isMonitor":true,
      "sensors":[{"id":301,"name":"pm10 µg/m³","parameter":{"id":1,"name":"pm10","units":"µg/m³","displayName":"PM10"}}],
      "coordinates":{"latitude":10.00,"longitude":20.00},"bounds":[],"distance":100.0,
      "datetimeFirst":null,"datetimeLast":{"utc":"2026-11-09T02:00:00Z","local":"2026-11-09T07:30:00Z"}},
     {"id":40,"name":"Bus Sensor","locality":null,"timezone":"UTC","isMobile":true,"isMonitor":false,
      "sensors":[{"id":401,"name":"pm25","parameter":{"id":2,"name":"pm25","units":"µg/m³","displayName":"PM2.5"}}],
      "coordinates":{"latitude":10.00,"longitude":20.00},"bounds":[],"distance":50.0,
      "datetimeFirst":null,"datetimeLast":{"utc":"2026-11-10T17:10:00Z","local":"2026-11-10T22:40:00Z"}}
    ]}
    """

    static let latestNearJSON = """
    {"meta":{"name":"openaq-api","website":"/","page":1,"limit":100,"found":2},"results":[
     {"datetime":{"utc":"2026-11-10T16:00:00Z","local":"2026-11-10T16:00:00Z"},"value":-999.0,
      "coordinates":{"latitude":10.0135,"longitude":20.00},"sensorsId":201,"locationsId":20},
     {"datetime":{"utc":"2026-11-10T16:00:00Z","local":"2026-11-10T16:00:00Z"},"value":31.0,
      "coordinates":{"latitude":10.0135,"longitude":20.00},"sensorsId":203,"locationsId":20}]}
    """

    static let latestFarJSON = """
    {"meta":{"name":"openaq-api","website":"/","page":1,"limit":100,"found":2},"results":[
     {"datetime":{"utc":"2026-11-10T17:00:00Z","local":"2026-11-10T17:00:00Z"},"value":94.1,
      "coordinates":{"latitude":10.10,"longitude":20.10},"sensorsId":101,"locationsId":10},
     {"datetime":{"utc":"2026-11-10T17:00:00Z","local":"2026-11-10T17:00:00Z"},"value":180.0,
      "coordinates":{"latitude":10.10,"longitude":20.10},"sensorsId":102,"locationsId":10}]}
    """

    static let hoursJSON = """
    {"meta":{"name":"openaq-api","website":"/","page":1,"limit":100,"found":3},"results":[
     {"value":90.0,"flagInfo":{"hasFlags":false},"parameter":{"id":2,"name":"pm25","units":"µg/m³","displayName":null},
      "period":{"label":"1hour","interval":"01:00:00","datetimeFrom":{"utc":"2026-11-10T15:00:00Z","local":"2026-11-10T20:30:00Z"},
      "datetimeTo":{"utc":"2026-11-10T16:00:00Z","local":"2026-11-10T16:00:00Z"}},"coordinates":null,"summary":null,"coverage":null},
     {"value":null,"flagInfo":{"hasFlags":false},"parameter":{"id":2,"name":"pm25","units":"µg/m³","displayName":null},
      "period":{"label":"1hour","interval":"01:00:00","datetimeFrom":{"utc":"2026-11-10T14:00:00Z","local":"2026-11-10T19:30:00Z"},
      "datetimeTo":{"utc":"2026-11-10T15:00:00Z","local":"2026-11-10T20:30:00Z"}},"coordinates":null,"summary":null,"coverage":null},
     {"value":5000.0,"flagInfo":{"hasFlags":true},"parameter":{"id":2,"name":"pm25","units":"µg/m³","displayName":null},
      "period":{"label":"1hour","interval":"01:00:00","datetimeFrom":{"utc":"2026-11-10T16:00:00Z","local":"2026-11-10T16:00:00Z"},
      "datetimeTo":{"utc":"2026-11-10T17:00:00Z","local":"2026-11-10T17:00:00Z"}},"coordinates":null,"summary":null,"coverage":null}
    ]}
    """

    static func decode<T: Decodable>(_ json: String, as: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static func run(_ check: (String, Int, Int) -> Void) -> Int {
        let extra = 0
        guard let locs = decode(locationsJSON, as: OAQList<OAQLocation>.self),
              let latestNear = decode(latestNearJSON, as: OAQList<OAQLatest>.self),
              let latestFar = decode(latestFarJSON, as: OAQList<OAQLatest>.self),
              let hours = decode(hoursJSON, as: OAQList<OAQHour>.self) else {
            print("FAIL  OpenAQ sample JSON did not decode")
            return 1
        }
        check("OpenAQ: decoded 4 locations", locs.results.count, 4)
        let lat = 10.00, lon = 20.00
        let c25 = OpenAQLogic.candidates(.pm25, in: locs.results, latitude: lat, longitude: lon, now: now)
        let c10 = OpenAQLogic.candidates(.pm10, in: locs.results, latitude: lat, longitude: lon, now: now)
        check("OpenAQ: PM2.5 candidates skip mobile, nearest first", c25.map(\.locationId) == [20, 10] ? 1 : 0, 1)
        check("OpenAQ: PM10 candidates skip stale station", c10.map(\.locationId) == [10] ? 1 : 0, 1)
        check("OpenAQ: distance from coordinates (1.5 km, x10)", Int(((c25.first?.distanceKm ?? 0) * 10).rounded()), 15)

        // Nearest PM2.5 reports -999: it must be rejected and the next station used.
        check("OpenAQ: sentinel -999 rejected", OpenAQLogic.reading(for: c25[0], in: latestNear.results, now: now) == nil ? 1 : 0, 1)
        let r25 = OpenAQLogic.reading(for: c25[1], in: latestFar.results, now: now)
        check("OpenAQ: falls through to next station's PM2.5 (94)", Int(r25?.value ?? -1), 94)
        let old = now.addingTimeInterval(4 * 3600)
        check("OpenAQ: reading older than 3h rejected", OpenAQLogic.reading(for: c25[1], in: latestFar.results, now: old) == nil ? 1 : 0, 1)
        check("OpenAQ: units µg/m³ accepted, ppb rejected",
              OpenAQLogic.isMicrogramsPerCubicMetre("µg/m³") && !OpenAQLogic.isMicrogramsPerCubicMetre("ppb") ? 1 : 0, 1)

        // Hourly series: null and absurd (5000) values become gaps.
        let slots = OpenAQLogic.slots(endingAt: OpenAQLogic.floorToHour(now), count: 3)
        let series = OpenAQLogic.series(hours.results, slots: slots)
        check("OpenAQ: hourly series [nil, 90, nil]",
              series.count == 3 && series[0] == nil && series[1] == 90 && series[2] == nil ? 1 : 0, 1)

        // Station data -> snapshot uses the live station values.
        let full = OpenAQLogic.slots(endingAt: OpenAQLogic.floorToHour(now), count: 24)
        let st = StationData(pm25: r25, pm10: nil, slots: full,
                             pm25Series: full.map { _ in 94.1 }, pm10Series: full.map { _ in nil })
        let snap = AirDataLoader.snapshot(from: st, placeName: "Test", now: now)
        check("OpenAQ: station snapshot AQI from PM2.5 94.1", snap?.aqi ?? -1, 212)
        if case .station = snap?.source { check("OpenAQ: snapshot source is station", 1, 1) }
        else { check("OpenAQ: snapshot source is station", 0, 1) }

        // Cached plan: re-search only after moving > 2 km or after 12 h.
        let plan = StationPlan(latitude: lat, longitude: lon, searchedAt: now, pm25: c25, pm10: c10)
        check("OpenAQ: plan kept after moving 1 km", plan.isOutdated(latitude: lat + 0.009, longitude: lon, now: now) ? 0 : 1, 1)
        check("OpenAQ: plan outdated after moving 3 km", plan.isOutdated(latitude: lat + 0.027, longitude: lon, now: now) ? 1 : 0, 1)
        check("OpenAQ: plan outdated after 13 h", plan.isOutdated(latitude: lat, longitude: lon, now: now.addingTimeInterval(13 * 3600)) ? 1 : 0, 1)

        // Fallback reasons.
        check("Fallback: 401 means key not accepted", OpenAQError.unauthorized.localizedDescription == "OpenAQ key not accepted" ? 1 : 0, 1)

        return extra
    }
}
