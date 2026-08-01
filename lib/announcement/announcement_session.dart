import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/employee/services/storage_service.dart';

/// Which side of the app is logged in right now.
///
/// This build serves two audiences from one binary — the driver screens and the
/// employee/vendor screens — and the announcement endpoints differ per audience
/// (`/api/driver/...` vs `/api/vendor/...`). Everything announcement-related
/// resolves its prefix and token through here so neither side hardcodes the
/// other's route.
enum AnnouncementRole { driver, vendor }

extension AnnouncementRolePath on AnnouncementRole {
  String get apiPrefix => this == AnnouncementRole.driver ? 'driver' : 'vendor';

  String? get token => this == AnnouncementRole.driver
      ? DriverStorageService().getToken()
      : StorageService().getToken();
}

class AnnouncementSession {
  /// The audience to fetch announcements for, or null when nobody is logged in.
  ///
  /// The driver token is checked first: a driver session is the more specific
  /// one, and the employee storage uses the generic `token` key.
  static AnnouncementRole? current() {
    if (DriverStorageService().getToken() != null) {
      return AnnouncementRole.driver;
    }
    if (StorageService().getToken() != null) {
      return AnnouncementRole.vendor;
    }
    return null;
  }
}
