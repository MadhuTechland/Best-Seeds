import Flutter
import UIKit
import GoogleMaps
import Firebase
import FirebaseMessaging
import UserNotifications
import CoreLocation

@main
@objc class AppDelegate: FlutterAppDelegate, CLLocationManagerDelegate {

  // Native location manager — handles the terminated-app case.
  // When the Flutter engine is dead (user swiped the app away), iOS can still
  // relaunch the process for significant-location-change events. This manager
  // posts coordinates directly to the backend via URLSession so tracking
  // continues without Flutter being fully initialised.
  private var nativeLocationManager: CLLocationManager?

  private let baseUrl  = "https://aqua.bestseed.in/api/driver/location/update"
  private let tokenKey = "flutter.driver_token"           // SharedPreferences prefix
  private let runKey   = "flutter.bg_location_service_running"

  // MARK: - App lifecycle

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()
    GMSServices.provideAPIKey("AIzaSyA111b89Exrm83RRWF-2hP1EPeUxvos87I")
    UNUserNotificationCenter.current().delegate = self
    application.registerForRemoteNotifications()
    GeneratedPluginRegistrant.register(with: self)

    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // Set up MethodChannel (FlutterViewController is ready after super).
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "com.bestseed/location_watchdog",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "startWatchdog": self?.startWatchdog(); result(nil)
        case "stopWatchdog":  self?.stopWatchdog();  result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
    }

    // If iOS relaunched us because of a location event (app was terminated),
    // restart native tracking immediately so we keep sending positions.
    let launchedByLocation = launchOptions?[.location] != nil
    let trackingActive     = UserDefaults.standard.bool(forKey: runKey)

    if launchedByLocation && trackingActive {
      startNativeTracking()   // full GPS stream for the brief wakeup window
    } else if trackingActive {
      startWatchdog()         // significant changes only — low battery cost
    }

    return result
  }

  // MARK: - Watchdog control

  private func startWatchdog() {
    setupManager()
    nativeLocationManager?.startMonitoringSignificantLocationChanges()
  }

  private func stopWatchdog() {
    nativeLocationManager?.stopMonitoringSignificantLocationChanges()
    nativeLocationManager?.stopUpdatingLocation()
  }

  // Full accuracy stream — used when iOS wakes us from terminated state
  private func startNativeTracking() {
    setupManager()
    nativeLocationManager?.desiredAccuracy = kCLLocationAccuracyBest
    nativeLocationManager?.distanceFilter  = 10
    nativeLocationManager?.startUpdatingLocation()
    nativeLocationManager?.startMonitoringSignificantLocationChanges()
  }

  private func setupManager() {
    guard nativeLocationManager == nil else { return }
    let mgr = CLLocationManager()
    mgr.delegate = self
    mgr.allowsBackgroundLocationUpdates   = true
    mgr.pausesLocationUpdatesAutomatically = false
    nativeLocationManager = mgr
  }

  // MARK: - CLLocationManagerDelegate

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let loc = locations.last,
          loc.horizontalAccuracy >= 0,
          loc.horizontalAccuracy < 100 else { return }

    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: runKey),
          let token = defaults.string(forKey: tokenKey),
          !token.isEmpty else {
      stopWatchdog()
      return
    }

    postLocation(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, token: token)
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    print("NativeLocationManager error: \(error.localizedDescription)")
  }

  // MARK: - Backend POST

  private func postLocation(lat: Double, lng: Double, token: String) {
    guard let url = URL(string: baseUrl) else { return }

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 12
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let body: [String: Any] = [
      "lat": lat, "lng": lng,
      "location_name": "Live vehicle location",
      "accuracy": 50.0
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
      guard let self = self else { return }
      if let http = response as? HTTPURLResponse {
        if http.statusCode == 401 {
          UserDefaults.standard.set(false, forKey: self.runKey)
          self.stopWatchdog()
          return
        }
        if (200..<300).contains(http.statusCode),
           let data = data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = json["status"] as? Bool, !status {
          UserDefaults.standard.set(false, forKey: self.runKey)
          self.stopWatchdog()
        }
      }
    }.resume()
  }

  // MARK: - APNs

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Messaging.messaging().apnsToken = deviceToken
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }
}
