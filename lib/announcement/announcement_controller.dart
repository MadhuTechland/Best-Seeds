import 'package:bestseeds/announcement/announcement_model.dart';
import 'package:bestseeds/announcement/announcement_session.dart';
import 'package:bestseeds/routes/api_clients.dart';
import 'package:bestseeds/routes/app_constants.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// Holds the announcement list shown under Profile > Announcements and the
/// unread count that drives the badge on that menu row.
///
/// One controller serves both the driver and the vendor side — the role is
/// resolved per call from whichever session is active.
class AnnouncementController extends GetxController {
  /// The one shared instance. Both profile badges and the list screen reach the
  /// controller through here — a plain Get.put in each would replace the
  /// registered instance and reset the unread count.
  static AnnouncementController get to =>
      Get.isRegistered<AnnouncementController>()
          ? Get.find<AnnouncementController>()
          : Get.put(AnnouncementController(), permanent: true);

  final announcements = <AnnouncementModel>[].obs;
  final unreadCount = 0.obs;
  final isLoading = false.obs;

  final ApiClient _api = ApiClient();

  /// Role the current list belongs to. This controller is permanent and the
  /// same binary serves drivers and vendors, so a logout→login as the other
  /// side must not leave the previous session's announcements on screen.
  AnnouncementRole? _loadedRole;

  @override
  void onInit() {
    super.onInit();
    fetchAnnouncements();
  }

  Future<void> fetchAnnouncements() async {
    final role = AnnouncementSession.current();
    if (role == null) {
      _clear();
      return;
    }

    if (_loadedRole != null && _loadedRole != role) {
      _clear();
    }

    try {
      isLoading.value = true;

      final response = await _api.request(
        url: '${AppConstants.baseUrl}${role.apiPrefix}/announcements',
        body: {},
        method: 'GET',
        token: role.token,
      );

      _loadedRole = role;

      if (response['status'] == true) {
        announcements.assignAll(
          (response['announcements'] as List? ?? [])
              .map((e) => AnnouncementModel.fromJson(
                    Map<String, dynamic>.from(e),
                  ))
              .toList(),
        );
        unreadCount.value = response['unread_count'] ?? 0;
      }
    } catch (e) {
      debugPrint('Error fetching announcements: $e');
    } finally {
      isLoading.value = false;
    }
  }

  void _clear() {
    announcements.clear();
    unreadCount.value = 0;
    _loadedRole = null;
  }

  /// Marks one announcement read and keeps the local list/badge in sync so the
  /// UI updates without another round trip.
  Future<void> markAsRead(int id) async {
    final role = AnnouncementSession.current();
    if (role == null) return;

    final index = announcements.indexWhere((a) => a.id == id);
    if (index != -1 && announcements[index].isRead) return;

    if (index != -1) {
      announcements[index] = announcements[index].copyWith(isRead: true);
      if (unreadCount.value > 0) unreadCount.value--;
    }

    try {
      final response = await _api.request(
        url: '${AppConstants.baseUrl}${role.apiPrefix}/announcements/$id/read',
        body: {},
        token: role.token,
      );

      if (response['unread_count'] != null) {
        unreadCount.value = response['unread_count'];
      }
    } catch (e) {
      debugPrint('Error marking announcement as read: $e');
    }
  }
}
