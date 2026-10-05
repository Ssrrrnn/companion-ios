import SwiftUI
import CoreLocation

struct PhoneLocation: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let sampled_at: String
    static func sample(_ location: CLLocation, now: Date = .now) -> PhoneLocation? {
        guard CLLocationCoordinate2DIsValid(location.coordinate), location.horizontalAccuracy >= 0,
              location.horizontalAccuracy.isFinite, abs(now.timeIntervalSince(location.timestamp)) <= 120 else { return nil }
        return PhoneLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy, sampled_at: ISO8601DateFormatter().string(from: location.timestamp))
    }
}

@MainActor
final class LocationContext: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var enabled = UserDefaults.standard.bool(forKey: "phone_location_read_v1") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "phone_location_read_v1")
            if !enabled { value = nil; finish(nil); manager.stopUpdatingLocation() }
            else if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        }
    }
    @Published private(set) var authorized = false
    @Published private(set) var value: PhoneLocation?
    @Published private(set) var error: String?
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<PhoneLocation?, Never>?
    private var timeout: Task<Void, Never>?
    override init() {
        super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorized = manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    }
    func request() async -> PhoneLocation? {
        guard enabled, authorized, UIApplication.shared.applicationState == .active, continuation == nil else { return nil }
        if let value, let sampled = ISO8601DateFormatter().date(from: value.sampled_at), Date.now.timeIntervalSince(sampled) < 60 { return value }
        return await withCheckedContinuation { pending in
            continuation = pending
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                self?.error = "暂未取得新的定位。"; self?.finish(nil)
            }
            manager.requestLocation()
        }
    }
    private func finish(_ location: PhoneLocation?) {
        timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil; pending?.resume(returning: location)
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorized = manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
        if !authorized { value = nil; finish(nil) }
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted { error = "定位未授权，可以在系统设置中修改。" }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard enabled, authorized, let location = locations.last.flatMap({ PhoneLocation.sample($0) }) else { finish(nil); return }
        value = location; error = nil; finish(location)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        self.error = "暂未取得新的定位。"; finish(nil)
    }
    func background() { manager.stopUpdatingLocation(); finish(nil) }
}
