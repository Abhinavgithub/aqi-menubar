import CoreLocation
import Foundation

struct Located {
    let coordinate: CLLocationCoordinate2D
    let placeName: String?
}

enum LocationError: Error {
    case notDetermined      // the user has not answered the permission prompt
    case denied
    case restricted
    case failed(String)
}

/// Wraps CLLocationManager: asks for when-in-use permission, gets one fix at
/// kilometre accuracy and reverse geocodes it to a short place name.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var authWaiters: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    private var locationWaiters: [CheckedContinuation<CLLocation, Error>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func locate() async throws -> Located {
        var status = manager.authorizationStatus
        if status == .notDetermined {
            status = await withCheckedContinuation { c in
                authWaiters.append(c)
                manager.requestWhenInUseAuthorization()
                // Don't wait forever if the prompt is ignored.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 90_000_000_000)
                    self?.resumeAuthWaiters(self?.manager.authorizationStatus ?? .notDetermined)
                }
            }
        }
        switch status {
        case .notDetermined: throw LocationError.notDetermined
        case .denied: throw LocationError.denied
        case .restricted: throw LocationError.restricted
        default: break
        }

        let location: CLLocation = try await withCheckedThrowingContinuation { c in
            locationWaiters.append(c)
            if locationWaiters.count == 1 { manager.requestLocation() }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                self?.resumeLocationWaiters(.failure(LocationError.failed("Timed out waiting for a location fix.")))
            }
        }
        return Located(coordinate: location.coordinate, placeName: await placeName(for: location))
    }

    private func placeName(for location: CLLocation) async -> String? {
        guard let p = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
        var parts: [String] = []
        if let sub = p.subLocality, !sub.isEmpty { parts.append(sub) }
        if let city = p.locality, !city.isEmpty, !parts.contains(city) { parts.append(city) }
        if parts.isEmpty, let area = p.administrativeArea ?? p.name { parts.append(area) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func resumeAuthWaiters(_ status: CLAuthorizationStatus) {
        let waiters = authWaiters
        authWaiters.removeAll()
        waiters.forEach { $0.resume(returning: status) }
    }

    private func resumeLocationWaiters(_ result: Result<CLLocation, Error>) {
        let waiters = locationWaiters
        locationWaiters.removeAll()
        waiters.forEach { $0.resume(with: result) }
    }

    // MARK: CLLocationManagerDelegate (called on the main thread, where the manager was created)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        Task { @MainActor in self.resumeAuthWaiters(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.resumeLocationWaiters(.success(last)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor in
            self.resumeLocationWaiters(.failure(denied ? LocationError.denied : LocationError.failed(message)))
        }
    }
}
