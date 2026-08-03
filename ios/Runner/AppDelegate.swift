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

  // Timer that downgrades a native GPS wakeup back to SLC-only after the
  // brief background window iOS grants us. Prevents the native side from
  // holding a full GPS stream open indefinitely if Flutter never boots.
  private var nativeTrackingStopTimer: Timer?

  private let baseUrl  = "https://aqua.bestseed.in/api/driver/location/update"
  private let tokenKey = "flutter.driver_token"           // SharedPreferences prefix
  private let runKey   = "flutter.bg_location_service_running"

  // MARK: - App lifecycle

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()
    // Key comes from ios/Flutter/Secrets.xcconfig (gitignored) via the
    // GoogleMapsApiKey entry in Info.plist, so it never appears in source.
    // The "$(" check catches an unsubstituted placeholder — i.e. the xcconfig
    // is missing — so it fails loudly in the log instead of silently.
    if let mapsKey = Bundle.main.object(forInfoDictionaryKey: "GoogleMapsApiKey") as? String,
       !mapsKey.isEmpty,
       !mapsKey.hasPrefix("$(") {
      GMSServices.provideAPIKey(mapsKey)
    } else {
      NSLog("⚠️ [KEYS] GoogleMapsApiKey missing — copy ios/Flutter/Secrets.example.xcconfig to Secrets.xcconfig. Maps will be blank.")
    }
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

      // Device-info channel — same name as the Android side so the Dart layer
      // uses a single channel cross-platform. Mirrors the iOS-relevant subset
      // of the Android checks (Always/Precise/BackgroundRefresh/LowPowerMode)
      // plus openLocationSettings so we can deep-link the driver to the app's
      // Settings screen when a required toggle is off.
      //
      // WHY on iOS specifically: iOS doesn't have Doze — CLLocationManager
      // with `location` background mode + Always permission keeps ticking on
      // a locked phone. What DOES silently kill background tracking is the
      // user granting "When in Use" (not "Always"), disabling Precise
      // Location, or the periodic reminder ("continue background access?")
      // being answered with "Only while using". These checks let the driver
      // app catch that and prompt the driver to restore the setting.
      let deviceInfoChannel = FlutterMethodChannel(
        name: "bestseeds/device_info",
        binaryMessenger: controller.binaryMessenger
      )
      deviceInfoChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "isAlwaysAuthorized":
          let status: CLAuthorizationStatus
          if #available(iOS 14.0, *) {
            status = CLLocationManager().authorizationStatus
          } else {
            status = CLLocationManager.authorizationStatus()
          }
          result(status == .authorizedAlways)

        case "isPreciseLocation":
          if #available(iOS 14.0, *) {
            result(CLLocationManager().accuracyAuthorization == .fullAccuracy)
          } else {
            // Pre-iOS 14 always had full accuracy.
            result(true)
          }

        case "isBackgroundRefreshAvailable":
          // .available = user has Background App Refresh ON for the app.
          // .denied / .restricted = OFF. In practice location tracking still
          // works while foregrounded and via SLC (which is BAR-exempt for
          // location-authorized apps), but foreground-fetch tasks and some
          // relaunch scenarios are affected — worth surfacing.
          result(UIApplication.shared.backgroundRefreshStatus == .available)

        case "isLowPowerModeEnabled":
          result(ProcessInfo.processInfo.isLowPowerModeEnabled)

        case "openLocationSettings":
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            result(true)
          } else {
            result(false)
          }

        // Android-only methods — return safe defaults so a cross-platform
        // Dart call site doesn't have to branch on Platform.isAndroid for
        // every invocation. These are wake-lock / OEM-autostart checks that
        // have no iOS equivalent.
        case "acquireWakeLock", "releaseWakeLock":
          result(true)
        case "isWakeLockHeld":
          result(false)
        case "isAggressiveOem", "isIgnoringBatteryOptimizations":
          result(true)
        case "requestIgnoreBatteryOptimizations", "openOemAutoStartSettings":
          result(true)

        default:
          result(FlutterMethodNotImplemented)
        }
      }

      // Live Activity channel — drives the lock-screen / Dynamic Island tile.
      // Flutter calls start at journey start, update on every successful
      // location send, and end at journey completion / logout / 401.
      let liveActivityChannel = FlutterMethodChannel(
        name: "com.bestseed/live_activity",
        binaryMessenger: controller.binaryMessenger
      )
      liveActivityChannel.setMethodCallHandler { call, result in
        if call.method == "end" {
          BestseedLiveActivityManager.shared.end()
          result(nil)
          return
        }
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "bad_args", message: "expected map", details: nil))
          return
        }
        switch call.method {
        case "start":
          BestseedLiveActivityManager.shared.start(
            journeyId: args["journeyId"] as? String ?? "",
            driverName: args["driverName"] as? String ?? "",
            locationName: args["locationName"] as? String ?? "Tracking active",
            latitude: args["latitude"] as? Double ?? 0,
            longitude: args["longitude"] as? Double ?? 0,
            lastSentAtEpoch: args["lastSentAtEpoch"] as? Double ?? Date().timeIntervalSince1970,
            nextStop: args["nextStop"] as? String,
            pickupName: args["pickupName"] as? String,
            dropName: args["dropName"] as? String,
            progress: args["progress"] as? Double ?? 0,
            etaText: args["etaText"] as? String,
            stops: args["stops"] as? [[String: Any]]
          )
          result(nil)
        case "update":
          BestseedLiveActivityManager.shared.update(
            locationName: args["locationName"] as? String ?? "Tracking active",
            latitude: args["latitude"] as? Double ?? 0,
            longitude: args["longitude"] as? Double ?? 0,
            lastSentAtEpoch: args["lastSentAtEpoch"] as? Double ?? Date().timeIntervalSince1970,
            nextStop: args["nextStop"] as? String,
            pickupName: args["pickupName"] as? String,
            dropName: args["dropName"] as? String,
            progress: args["progress"] as? Double ?? 0,
            etaText: args["etaText"] as? String,
            stops: args["stops"] as? [[String: Any]]
          )
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    // If iOS relaunched us because of a location event (app was terminated
    // mid-journey), restart native tracking just long enough to post one
    // position; Flutter's `IosLocationService.start()` will re-arm the
    // foreground stream + SLC once the engine boots and verifies the
    // journey is still active.
    //
    // Do NOT arm SLC on plain cold launches (no `.location` key in
    // launchOptions). SLC is persistent — once armed, iOS counts the app
    // as a background-location consumer until stopMonitoringSLC is called
    // explicitly. The Flutter side is the single source of truth for
    // "start tracking"; native side only reacts to genuine wakeups.
    let launchedByLocation = launchOptions?[.location] != nil
    let trackingActive     = UserDefaults.standard.bool(forKey: runKey)

    if launchedByLocation && trackingActive {
      startNativeTracking()   // brief GPS window — auto-stops if Flutter doesn't claim it
    }

    return result
  }

  // MARK: - Watchdog control

  private func startWatchdog() {
    setupManager()
    nativeLocationManager?.startMonitoringSignificantLocationChanges()
  }

  private func stopWatchdog() {
    nativeTrackingStopTimer?.invalidate()
    nativeTrackingStopTimer = nil
    nativeLocationManager?.stopMonitoringSignificantLocationChanges()
    nativeLocationManager?.stopUpdatingLocation()
  }

  // Full accuracy stream — used when iOS wakes us from terminated state.
  // iOS gives ~30 s of background runtime for an SLC wakeup. We use it to
  // post one or two positions, then drop back to SLC-only so we are not
  // holding a GPS stream open without an active Flutter engine to validate
  // that the journey is still live.
  private func startNativeTracking() {
    setupManager()
    nativeLocationManager?.desiredAccuracy = kCLLocationAccuracyBest
    nativeLocationManager?.distanceFilter  = 10
    nativeLocationManager?.startUpdatingLocation()
    nativeLocationManager?.startMonitoringSignificantLocationChanges()

    nativeTrackingStopTimer?.invalidate()
    nativeTrackingStopTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
      guard let self = self else { return }
      // If the journey is still active per the run flag, Flutter
      // (IosLocationService.start) will have its own foreground stream
      // running by now. Either way, the native side should stop the
      // power-hungry continuous stream — SLC stays armed only while the
      // journey is active so iOS can wake us again if the process dies.
      self.nativeLocationManager?.stopUpdatingLocation()
      if !UserDefaults.standard.bool(forKey: self.runKey) {
        self.stopWatchdog()
      }
    }
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

    // Keep the lock-screen tile fresh even when Flutter is dead — this is
    // the swipe-kill recovery path. The activity stays alive for up to ~8 h
    // after being started, so as long as journeys end before that the user
    // sees a live tile across the entire delivery. We don't know the
    // current journey's pickup/drop/progress at the native level — pass
    // nil so the Live Activity falls back to its simpler layout for these
    // intermediate updates. Flutter overwrites with full data on next boot.
    BestseedLiveActivityManager.shared.update(
      locationName: "Live vehicle location",
      latitude: loc.coordinate.latitude,
      longitude: loc.coordinate.longitude,
      lastSentAtEpoch: Date().timeIntervalSince1970,
      nextStop: nil,
      pickupName: nil,
      dropName: nil,
      progress: 0,
      etaText: nil,
      stops: nil
    )
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
