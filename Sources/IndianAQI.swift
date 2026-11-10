import Foundation

/// The two pollutants AQI Bar measures.
enum Pollutant: String {
    case pm25 = "PM2.5"
    case pm10 = "PM10"
}

/// CPCB National AQI categories.
enum AQICategory: Int, CaseIterable {
    case good, satisfactory, moderate, poor, veryPoor, severe

    init(aqi: Int) {
        switch aqi {
        case ..<51: self = .good
        case 51...100: self = .satisfactory
        case 101...200: self = .moderate
        case 201...300: self = .poor
        case 301...400: self = .veryPoor
        default: self = .severe
        }
    }

    var name: String {
        switch self {
        case .good: return "Good"
        case .satisfactory: return "Satisfactory"
        case .moderate: return "Moderate"
        case .poor: return "Poor"
        case .veryPoor: return "Very Poor"
        case .severe: return "Severe"
        }
    }

    /// sRGB components, 0...1.
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .good: return (0.00, 0.60, 0.20)          // dark green
        case .satisfactory: return (0.55, 0.80, 0.30)  // light green
        case .moderate: return (1.00, 0.84, 0.00)      // yellow
        case .poor: return (1.00, 0.55, 0.00)          // orange
        case .veryPoor: return (0.90, 0.10, 0.10)      // red
        case .severe: return (0.50, 0.00, 0.10)        // maroon
        }
    }
}

/// One hourly reading from the API. Values can be missing.
struct HourReading {
    let time: String      // local ISO time, "yyyy-MM-ddTHH:mm"
    let pm25: Double?
    let pm10: Double?
}

struct AQIResult {
    let aqi: Int
    let category: AQICategory
    let dominant: Pollutant
}

struct TrendPoint {
    let time: String
    let aqi: Int?         // that hour's live AQI; nil when the hour has no PM data
    let pm25: Double?
    let pm10: Double?
}

struct AQISummary {
    /// Live AQI from the current PM2.5 and PM10 concentrations.
    let headline: AQIResult
    let avgPM25: Double?
    let avgPM10: Double?
    /// CPCB-style AQI from 24h averages (nil if fewer than 16 valid hours).
    let averageAQI: AQIResult?
    let trend: [TrendPoint]
}

/// Pure functions for the Indian CPCB National Air Quality Index.
enum IndianAQI {
    struct Breakpoint {
        let cLo: Double, cHi: Double, iLo: Double, iHi: Double
    }

    /// CPCB breakpoints (µg/m³, 24h average). Bands are written as CPCB publishes them
    /// (e.g. 31-60 -> 51-100); a value that falls in the gap between bands (e.g. 30.4)
    /// is interpolated between the neighbouring band edges, so the result is continuous.
    static let pm25Bands: [Breakpoint] = [
        .init(cLo: 0, cHi: 30, iLo: 0, iHi: 50),
        .init(cLo: 31, cHi: 60, iLo: 51, iHi: 100),
        .init(cLo: 61, cHi: 90, iLo: 101, iHi: 200),
        .init(cLo: 91, cHi: 120, iLo: 201, iHi: 300),
        .init(cLo: 121, cHi: 250, iLo: 301, iHi: 400),
        .init(cLo: 251, cHi: 380, iLo: 401, iHi: 500),
    ]

    static let pm10Bands: [Breakpoint] = [
        .init(cLo: 0, cHi: 50, iLo: 0, iHi: 50),
        .init(cLo: 51, cHi: 100, iLo: 51, iHi: 100),
        .init(cLo: 101, cHi: 250, iLo: 101, iHi: 200),
        .init(cLo: 251, cHi: 350, iLo: 201, iHi: 300),
        .init(cLo: 351, cHi: 430, iLo: 301, iHi: 400),
        .init(cLo: 431, cHi: 510, iLo: 401, iHi: 500),
    ]

    static func subIndex(_ c: Double, bands: [Breakpoint]) -> Double {
        guard c.isFinite, c > 0 else { return 0 }
        for (k, b) in bands.enumerated() where c <= b.cHi {
            if k > 0, c < b.cLo {
                let p = bands[k - 1]
                return p.iHi + (c - p.cHi) * (b.iLo - p.iHi) / (b.cLo - p.cHi)
            }
            return b.iLo + (c - b.cLo) * (b.iHi - b.iLo) / (b.cHi - b.cLo)
        }
        return 500
    }

    static func pm25SubIndex(_ c: Double) -> Double { subIndex(c, bands: pm25Bands) }
    static func pm10SubIndex(_ c: Double) -> Double { subIndex(c, bands: pm10Bands) }

    /// AQI is the larger sub-index, rounded. Needs at least one pollutant.
    static func aqi(pm25: Double?, pm10: Double?) -> AQIResult? {
        let s25 = pm25.map(pm25SubIndex)
        let s10 = pm10.map(pm10SubIndex)
        let dominant: Pollutant
        let value: Double
        switch (s25, s10) {
        case let (a?, b?): (dominant, value) = a >= b ? (.pm25, a) : (.pm10, b)
        case let (a?, nil): (dominant, value) = (.pm25, a)
        case let (nil, b?): (dominant, value) = (.pm10, b)
        case (nil, nil): return nil
        }
        let n = min(500, Int(value.rounded()))
        return AQIResult(aqi: n, category: AQICategory(aqi: n), dominant: dominant)
    }

    /// Mean of the non-null values in the `window` hours ending at `end` (inclusive).
    static func trailingAverage(_ values: [Double?], endingAt end: Int,
                                window: Int = 24, minValid: Int = 16) -> Double? {
        guard end >= 0, end < values.count else { return nil }
        let start = max(0, end - window + 1)
        let valid = values[start...end].compactMap { $0 }
        guard valid.count >= minValid else { return nil }
        return valid.reduce(0, +) / Double(valid.count)
    }

    /// Headline: live AQI from the current concentrations (falling back to the current
    /// hour's hourly values). Also the 24h-average AQI, and a 12-hour trend where each
    /// point is that hour's own live AQI.
    static func summarize(hours: [HourReading], currentTime: String,
                          currentPM25: Double?, currentPM10: Double?) -> AQISummary? {
        guard !hours.isEmpty else { return nil }
        // Current hour = last hourly slot not later than the "current" timestamp.
        // ISO strings in the same format compare correctly as text.
        let end = hours.lastIndex(where: { $0.time <= currentTime }) ?? (hours.count - 1)
        let pm25 = hours.map(\.pm25)
        let pm10 = hours.map(\.pm10)

        let avg25 = trailingAverage(pm25, endingAt: end)
        let avg10 = trailingAverage(pm10, endingAt: end)
        guard let headline = aqi(pm25: currentPM25 ?? hours[end].pm25,
                                 pm10: currentPM10 ?? hours[end].pm10) else { return nil }
        let averageAQI = (avg25 == nil && avg10 == nil) ? nil : aqi(pm25: avg25, pm10: avg10)

        var trend: [TrendPoint] = []
        for i in max(0, end - 11)...end {
            let a = aqi(pm25: hours[i].pm25, pm10: hours[i].pm10)
            trend.append(TrendPoint(time: hours[i].time, aqi: a?.aqi, pm25: hours[i].pm25, pm10: hours[i].pm10))
        }
        return AQISummary(headline: headline, avgPM25: avg25, avgPM10: avg10,
                          averageAQI: averageAQI, trend: trend)
    }
}

/// Command-line check: run the app binary with `--self-test`.
enum SelfTest {
    static func pm25SubIndexRounded(_ c: Double) -> Double { IndianAQI.pm25SubIndex(c).rounded() }

    static func run() -> Int32 {
        var failures = 0
        func check(_ label: String, _ got: Int, _ want: Int) {
            let ok = got == want
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(label) -> \(got) (expected \(want))")
        }
        for (c, want) in [(0.0, 0), (30, 50), (31, 51), (60, 100), (90, 200), (120, 300), (250, 400), (380, 500), (600, 500)] {
            check("PM2.5 \(c)", Int(IndianAQI.pm25SubIndex(c).rounded()), want)
        }
        for (c, want) in [(0.0, 0), (50, 50), (100, 100), (250, 200), (350, 300), (430, 400), (510, 500), (900, 500)] {
            check("PM10 \(c)", Int(IndianAQI.pm10SubIndex(c).rounded()), want)
        }
        let r = IndianAQI.aqi(pm25: 95, pm10: 120)!
        check("AQI(pm25 95, pm10 120) dominant PM2.5", r.dominant == .pm25 ? r.aqi : -1, 215)
        check("category of 215 is Poor", r.category == .poor ? 1 : 0, 1)
        // PM tile colours use each pollutant's own sub-index band.
        check("PM2.5 118 alone is Poor", AQICategory(aqi: Int(pm25SubIndexRounded(118))) == .poor ? 1 : 0, 1)
        check("PM10 168 alone is Moderate", AQICategory(aqi: Int(IndianAQI.pm10SubIndex(168).rounded())) == .moderate ? 1 : 0, 1)
        let bands: [AQICategory] = [.good, .satisfactory, .moderate, .poor, .veryPoor, .severe]
        func band(_ v: Double) -> Int { AQICategory(aqi: Int(v.rounded())).rawValue }
        for (c, want) in [(30.0, 0), (31, 1), (60, 1), (61, 2), (90, 2), (91, 3), (120, 3), (121, 4), (250, 4), (251, 5)] {
            check("PM2.5 \(c) band \(bands[want].name)", band(IndianAQI.pm25SubIndex(c)), want)
        }
        for (c, want) in [(50.0, 0), (51, 1), (100, 1), (101, 2), (250, 2), (251, 3), (350, 3), (351, 4), (430, 4), (431, 5)] {
            check("PM10 \(c) band \(bands[want].name)", band(IndianAQI.pm10SubIndex(c)), want)
        }
        check("PM10 98 alone is Satisfactory", AQICategory(aqi: Int(IndianAQI.pm10SubIndex(98).rounded())) == .satisfactory ? 1 : 0, 1)

        // 36 hours of constant data: 24h average equals the constant.
        let flat = (0..<37).map { HourReading(time: String(format: "T%03d", $0), pm25: 60, pm10: 100) }
        if let s = IndianAQI.summarize(hours: flat, currentTime: "T036", currentPM25: 120, currentPM10: 50) {
            check("live headline uses current values (PM2.5 120)", s.headline.aqi, 300)
            check("24h-average AQI (avg 60/100)", s.averageAQI?.aqi ?? -1, 100)
            check("trend point = that hour's live AQI", s.trend.last?.aqi ?? -1, 100)
            check("trend has 12 points", s.trend.count, 12)
        } else { check("summary produced", 0, 1) }
        let sparse = (0..<37).map { HourReading(time: String(format: "T%03d", $0), pm25: $0 % 2 == 0 ? 60 : nil, pm10: nil) }
        if let s = IndianAQI.summarize(hours: sparse, currentTime: "T036", currentPM25: 30, currentPM10: nil) {
            check("live headline with sparse history", s.headline.aqi, 50)
            check("no 24h-average AQI when < 16 valid hours", s.averageAQI == nil ? 1 : 0, 1)
        } else { check("sparse summary produced", 0, 1) }

        failures += OpenAQSelfTest.run(check)

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) FAILED.")
        return failures == 0 ? 0 : 1
    }
}
