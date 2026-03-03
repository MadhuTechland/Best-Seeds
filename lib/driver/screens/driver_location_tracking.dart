import 'package:bestseeds/driver/services/background_location_service.dart';

/// Legacy facade - delegates to BackgroundLocationService.
/// Kept for backward compatibility with existing call sites.
class DriverLocationService {
  static Future<void> start(String token) async {
    // Token is already stored in SharedPreferences by DriverStorageService
    // at login time (key: 'driver_token'). The background isolate reads it
    // directly from SharedPreferences, so we don't need to pass it here.
    print('DriverLocationService.start() -> delegating to BackgroundLocationService');
    await BackgroundLocationService.start();
  }

  static Future<void> stop() async {
    print('DriverLocationService.stop() -> delegating to BackgroundLocationService');
    await BackgroundLocationService.stop();
  }
}
