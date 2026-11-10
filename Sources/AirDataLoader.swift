import Foundation

/// Where the numbers came from.
enum DataSource {
    /// OpenAQ ground station(s). PM2.5 and PM10 may come from different stations.
    case station(pm25: StationReading?, pm10: StationReading?)
    /// Open-Meteo model estimate, with the reason a station wasn't used.
    case model(reason: String)
}

struct LoadOutcome {
    let snapshot: AQISnapshot
    let keyRejected: Bool
}

/// Picks the data source (OpenAQ station if possible, otherwise Open-Meteo) and builds a snapshot.
enum AirDataLoader {
    static func load(latitude: Double, longitude: Double, placeName: String, now: Date = Date()) async throws -> LoadOutcome {
        var reason = "no OpenAQ key"
        var keyRejected = false
        if let key = KeyStore.load() {
            do {
                let st = try await OpenAQClient.stationData(latitude: latitude, longitude: longitude, key: key, now: now)
                if let snap = snapshot(from: st, placeName: placeName, now: now) {
                    return LoadOutcome(snapshot: snap, keyRejected: false)
                }
                reason = OpenAQError.stale.localizedDescription
            } catch let e as OpenAQError {
                if case .unauthorized = e { keyRejected = true }
                reason = e.localizedDescription
            } catch {
                reason = "OpenAQ unavailable (\(error.localizedDescription))"
            }
            AppLog.write("OpenAQ not used: \(reason)")
        }

        let r = try await AirQualityService.fetch(latitude: latitude, longitude: longitude)
        guard let summary = IndianAQI.summarize(hours: r.hours, currentTime: r.current.time,
                                                currentPM25: r.current.pm25, currentPM10: r.current.pm10) else {
            throw AirQualityError.http(200, "no PM2.5 or PM10 values for this location")
        }
        let snap = AQISnapshot(placeName: placeName, aqi: summary.headline.aqi, category: summary.headline.category,
                               dominant: summary.headline.dominant,
                               currentPM25: r.current.pm25, currentPM10: r.current.pm10,
                               avgPM25: summary.avgPM25, avgPM10: summary.avgPM10,
                               averageAQI: summary.averageAQI?.aqi, trend: summary.trend,
                               dataTime: r.current.time, utcOffsetSeconds: r.utcOffsetSeconds,
                               source: .model(reason: reason), updated: now)
        return LoadOutcome(snapshot: snap, keyRejected: keyRejected)
    }

    /// Station readings -> snapshot, reusing the CPCB maths (live values, 24h averages, 12h strip).
    static func snapshot(from st: StationData, placeName: String, now: Date) -> AQISnapshot? {
        let tz = TimeZone.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.timeZone = tz
        let hours = st.slots.indices.map {
            HourReading(time: f.string(from: st.slots[$0]), pm25: st.pm25Series[$0], pm10: st.pm10Series[$0])
        }
        guard let last = hours.last,
              let summary = IndianAQI.summarize(hours: hours, currentTime: last.time,
                                                currentPM25: st.pm25?.value, currentPM10: st.pm10?.value)
        else { return nil }
        let readingTime = [st.pm25?.time, st.pm10?.time].compactMap { $0 }.max() ?? now
        return AQISnapshot(placeName: placeName, aqi: summary.headline.aqi, category: summary.headline.category,
                           dominant: summary.headline.dominant,
                           currentPM25: st.pm25?.value, currentPM10: st.pm10?.value,
                           avgPM25: summary.avgPM25, avgPM10: summary.avgPM10,
                           averageAQI: summary.averageAQI?.aqi, trend: summary.trend,
                           dataTime: f.string(from: readingTime), utcOffsetSeconds: tz.secondsFromGMT(for: now),
                           source: .station(pm25: st.pm25, pm10: st.pm10), updated: now)
    }

    /// Plain-text report for `--print-once` (never includes the key).
    static func report(_ o: LoadOutcome, latitude: Double, longitude: Double) -> String {
        let s = o.snapshot
        let t = DateFormatter()
        t.dateStyle = .short; t.timeStyle = .short
        func v(_ x: Double?) -> String { x.map { String(format: "%.1f µg/m³", $0) } ?? "n/a" }
        var lines = ["Location: \(s.placeName) (\(String(format: "%.3f, %.3f", latitude, longitude)))"]
        switch s.source {
        case let .station(pm25, pm10):
            lines.append("Source: OpenAQ ground station")
            for (label, r) in [("PM2.5", pm25), ("PM10", pm10)] {
                if let r {
                    lines.append("  \(label): \(v(r.value)) at \(t.string(from: r.time)) from \"\(r.choice.name)\" (\(String(format: "%.1f", r.choice.distanceKm)) km, sensor \(r.choice.sensorId))")
                } else {
                    lines.append("  \(label): no recent station reading")
                }
            }
        case let .model(reason):
            lines.append("Source: Open-Meteo model estimate (\(reason))")
            lines.append("  PM2.5: \(v(s.currentPM25)), PM10: \(v(s.currentPM10)), for \(s.dataTime)")
        }
        if o.keyRejected { lines.append("OpenAQ key: NOT accepted (401/403)") }
        lines.append("AQI: \(s.aqi) \(s.category.name) (dominant \(s.dominant.rawValue))")
        lines.append("24h averages: PM2.5 \(v(s.avgPM25)), PM10 \(v(s.avgPM10)), AQI \(s.averageAQI.map(String.init) ?? "n/a")")
        lines.append("Last 12 h: " + s.trend.map { "\($0.time.suffix(5))=\($0.aqi.map(String.init) ?? "-")" }.joined(separator: " "))
        return lines.joined(separator: "\n")
    }

    /// `AQIBar --print-once [lat,lon]`: one load using the given or last-known coordinate.
    static func printOnce(arguments: [String]) -> Int32 {
        var lat: Double?, lon: Double?, place = "last known location"
        if let i = arguments.firstIndex(of: "--print-once"), i + 1 < arguments.count {
            let parts = arguments[i + 1].split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 { lat = parts[0]; lon = parts[1]; place = "given coordinate" }
        }
        if lat == nil, let last = AppFiles.readJSON(LastLocation.self, from: AppFiles.lastLocationURL) {
            lat = last.latitude; lon = last.longitude; place = last.placeName ?? place
        }
        guard let lat, let lon else {
            print("No coordinate: launch the app once, or pass --print-once LAT,LON")
            return 2
        }
        let done = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do {
                let o = try await load(latitude: lat, longitude: lon, placeName: place)
                print(report(o, latitude: lat, longitude: lon))
            } catch {
                print("Load failed: \(error.localizedDescription)")
                code = 1
            }
            done.signal()
        }
        done.wait()
        return code
    }
}
