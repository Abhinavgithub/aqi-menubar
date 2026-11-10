import AppKit
import CoreLocation
import Foundation
import Network

struct AQISnapshot {
    let placeName: String
    let aqi: Int
    let category: AQICategory
    let dominant: Pollutant
    let currentPM25: Double?
    let currentPM10: Double?
    let avgPM25: Double?
    let avgPM10: Double?
    let averageAQI: Int?      // CPCB 24h-average AQI, shown as secondary info
    let trend: [TrendPoint]
    let dataTime: String     // the API's "current" time, local to the location
    let utcOffsetSeconds: Int // the location's offset, for turning hourly times into dates
    let source: DataSource
    let updated: Date        // when this Mac fetched it
}

enum AQIState {
    case loading
    case needsLocationPermission(String)
    case error(String)
    /// `refreshError` is set when the latest refresh failed and this is the last good data.
    case loaded(AQISnapshot, refreshError: String?)
}

@MainActor
final class AQIStore: ObservableObject {
    @Published private(set) var state: AQIState = .loading
    @Published private(set) var isRefreshing = false
    @Published private(set) var keyStatus: KeyStatus = KeyStore.load() == nil ? .missing : .saved

    enum KeyStatus { case missing, saved, working, rejected }

    func saveKey(_ key: String) {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try KeyStore.save(key)
            keyStatus = .saved
            AppLog.write("OpenAQ key saved")
        } catch {
            AppLog.write("could not save OpenAQ key: \(error.localizedDescription)")
        }
        Task { await refresh() }
    }

    func removeKey() {
        KeyStore.remove()
        keyStatus = .missing
        AppLog.write("OpenAQ key removed")
        Task { await refresh() }
    }

    private let location = LocationProvider()
    private var nextRefresh: Task<Void, Never>?
    private var failureCount = 0
    private let monitor = NWPathMonitor()
    private var networkWasDown = false
    static let refreshInterval: TimeInterval = 15 * 60

    init() {
        // Refresh after waking from sleep (give Wi-Fi a moment to reconnect).
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.refresh()
            }
        }
        // Refresh when the network comes back.
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if up && self.networkWasDown {
                    AppLog.write("network is back, refreshing")
                    await self.refresh()
                }
                self.networkWasDown = !up
            }
        }
        monitor.start(queue: DispatchQueue(label: "aqibar.network"))
        Task { await refresh() }
    }

    var menuTitle: String {
        if case let .loaded(s, _) = state { return "AQI \(s.aqi)" }
        return "AQI --"
    }

    /// One-shot timer: 15 minutes after a success; after a failure 1, 2, 4, 8 then 15 minutes.
    private func scheduleNext(success: Bool) {
        failureCount = success ? 0 : failureCount + 1
        let delay = success ? Self.refreshInterval : min(Self.refreshInterval, 60 * pow(2, Double(failureCount - 1)))
        nextRefresh?.cancel()
        nextRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if case .loaded = state {} else { state = .loading }

        do {
            let (lat, lon, place) = try await currentCoordinate()
            let outcome = try await AirDataLoader.load(latitude: lat, longitude: lon, placeName: place)
            if outcome.keyRejected { keyStatus = .rejected }
            else if case .station = outcome.snapshot.source { keyStatus = .working }
            state = .loaded(outcome.snapshot, refreshError: nil)
            AppLog.write(outcome.snapshot)
            scheduleNext(success: true)
        } catch let e as LocationError {
            let message: String
            switch e {
            case .notDetermined: message = "AQI Bar needs your location. Click Allow on the location prompt, then Refresh."
            case .denied: message = "Location access is off for AQI Bar. Turn it on in System Settings > Privacy & Security > Location Services."
            case .restricted: message = "Location access is restricted on this Mac."
            case .failed(let m): message = "Couldn't find your location: \(m)"
            }
            fail(message, short: "Couldn't find your location", permission: e.isPermission)
        } catch {
            if Self.isOffline(error) {
                fail("You're offline. AQI Bar will retry automatically.", short: "Offline", permission: false)
            } else {
                fail(error.localizedDescription, short: "Couldn't refresh (\(error.localizedDescription))", permission: false)
            }
        }
    }

    /// The Mac's coordinate; if a fix fails (not a permission problem), the last known one.
    private func currentCoordinate() async throws -> (Double, Double, String) {
        do {
            let here = try await location.locate()
            let place = here.placeName ?? String(format: "%.2f, %.2f", here.coordinate.latitude, here.coordinate.longitude)
            AppFiles.writeJSON(LastLocation(latitude: here.coordinate.latitude, longitude: here.coordinate.longitude,
                                            placeName: here.placeName), to: AppFiles.lastLocationURL)
            return (here.coordinate.latitude, here.coordinate.longitude, place)
        } catch LocationError.failed(let m) {
            guard let last = AppFiles.readJSON(LastLocation.self, from: AppFiles.lastLocationURL) else {
                throw LocationError.failed(m)
            }
            AppLog.write("location fix failed (\(m)), using last known location")
            return (last.latitude, last.longitude, last.placeName ?? "Last known location")
        }
    }

    static func isOffline(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff].contains(u.code)
    }

    private func fail(_ message: String, short: String, permission: Bool) {
        AppLog.write("refresh failed: \(message)")
        if case let .loaded(s, _) = state {
            state = .loaded(s, refreshError: short)   // keep the last good data
        } else {
            state = permission ? .needsLocationPermission(message) : .error(message)
        }
        scheduleNext(success: false)
    }
}

extension LocationError {
    var isPermission: Bool {
        switch self {
        case .notDetermined, .denied, .restricted: return true
        case .failed: return false
        }
    }
}

/// Appends one line per refresh to ~/Library/Logs/AQIBar.log.
enum AppLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AQIBar.log")

    static func write(_ s: AQISnapshot) {
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "n/a" }
        let source: String
        switch s.source {
        case let .station(a, b):
            source = "openaq" + [a, b].compactMap { $0 }.map { " \"\($0.choice.name)\"(\(String(format: "%.1f", $0.choice.distanceKm))km)" }.joined()
        case let .model(reason): source = "open-meteo(\(reason))"
        }
        write("source=\(source) place=\"\(s.placeName)\" aqi=\(s.aqi) category=\(s.category.name) dominant=\(s.dominant.rawValue)"
              + " pm25=\(f(s.currentPM25)) pm10=\(f(s.currentPM10)) avg24h_pm25=\(f(s.avgPM25)) avg24h_pm10=\(f(s.avgPM10))"
              + " avg24h_aqi=\(s.averageAQI.map(String.init) ?? "n/a") data_time=\(s.dataTime)"
              + " trend=[" + s.trend.map { "\($0.time.suffix(5))=\($0.aqi.map(String.init) ?? "-")" }.joined(separator: " ") + "]")
    }

    static func write(_ line: String) {
        let text = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
