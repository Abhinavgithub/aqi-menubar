import Foundation

/// The parts of the Open-Meteo Air Quality response AQI Bar uses.
struct AirQualityResponse: Decodable {
    struct Current: Decodable {
        let time: String
        let pm25: Double?
        let pm10: Double?
        enum CodingKeys: String, CodingKey { case time, pm25 = "pm2_5", pm10 }
    }
    struct Hourly: Decodable {
        let time: [String]
        let pm25: [Double?]
        let pm10: [Double?]
        enum CodingKeys: String, CodingKey { case time, pm25 = "pm2_5", pm10 }
    }
    let utcOffsetSeconds: Int
    let current: Current
    let hourly: Hourly
    enum CodingKeys: String, CodingKey { case utcOffsetSeconds = "utc_offset_seconds", current, hourly }

    var hours: [HourReading] {
        hourly.time.indices.map { i in
            HourReading(time: hourly.time[i],
                        pm25: i < hourly.pm25.count ? hourly.pm25[i] : nil,
                        pm10: i < hourly.pm10.count ? hourly.pm10[i] : nil)
        }
    }
}

enum AirQualityError: LocalizedError {
    case http(Int, String?)
    var errorDescription: String? {
        switch self {
        case let .http(code, reason): return "Air quality service returned HTTP \(code)" + (reason.map { ": \($0)" } ?? ".")
        }
    }
}

enum AirQualityService {
    static func fetch(latitude: Double, longitude: Double) async throws -> AirQualityResponse {
        var c = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", latitude)),
            .init(name: "longitude", value: String(format: "%.4f", longitude)),
            .init(name: "current", value: "pm2_5,pm10"),
            .init(name: "hourly", value: "pm2_5,pm10"),
            .init(name: "past_hours", value: "36"),
            .init(name: "forecast_hours", value: "1"),
            .init(name: "timezone", value: "auto"),
        ]
        var request = URLRequest(url: c.url!, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
            throw AirQualityError.http(http.statusCode, reason)
        }
        return try JSONDecoder().decode(AirQualityResponse.self, from: data)
    }
}
