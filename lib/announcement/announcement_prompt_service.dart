import 'package:bestseeds/announcement/announcement_controller.dart';
import 'package:bestseeds/announcement/announcement_dialog.dart';
import 'package:bestseeds/announcement/announcement_model.dart';
import 'package:bestseeds/announcement/announcement_session.dart';
import 'package:bestseeds/routes/api_clients.dart';
import 'package:bestseeds/routes/app_constants.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Decides when a new announcement pops up as a dialog.
///
/// The server is the source of truth: GET /{role}/announcements/popup returns
/// the newest announcement this user has never been shown, or null. The same
/// call marks every other never-shown announcement as "offered" — so only the
/// newest ever interrupts, and the rest simply wait, still unread, in
/// Profile > Announcements.
///
/// Triggered from every app state so an announcement is never missed:
///  1. Real-time — foreground FCM `announcement` → [onAnnouncementPush].
///  2. Resume — background → foreground.
///  3. Start / just-logged-in — the home screens call [check] once mounted.
class AnnouncementPromptService {
  AnnouncementPromptService._();
  static final AnnouncementPromptService instance =
      AnnouncementPromptService._();

  bool _isShowing = false;

  final ApiClient _api = ApiClient();

  /// Real-time path: an announcement push arrived while the app is open.
  Future<void> onAnnouncementPush(Map<String, dynamic> data) async {
    if (data['type']?.toString() != 'announcement') return;
    await check();
  }

  /// Start / resume path. Safe to call often — no-ops when logged out, when
  /// nothing is pending, or when a dialog is already up.
  Future<void> check() async {
    if (_isShowing) return;

    final role = AnnouncementSession.current();
    if (role == null) return;

    try {
      final response = await _api.request(
        url: '${AppConstants.baseUrl}${role.apiPrefix}/announcements/popup',
        body: {},
        method: 'GET',
        token: role.token,
      );

      if (response['status'] != true) return;

      // Keep the Profile badge in step even when nothing pops up — the popup
      // call is the most frequent signal we get about the unread count.
      _syncBadge(response['unread_count']);

      final payload = response['announcement'];
      if (payload == null) return;

      await _present(AnnouncementModel.fromJson(
        Map<String, dynamic>.from(payload),
      ));
    } catch (e) {
      debugPrint('Announcement popup check failed: $e');
      // Network hiccup — try again on the next resume/start.
    }
  }

  Future<void> _present(AnnouncementModel announcement) async {
    if (_isShowing) return;

    final context = Get.context ?? Get.overlayContext;
    // Navigator not mounted yet (e.g. still on splash) — leave it so a later
    // resume/landing trigger shows it from a stable screen.
    if (context == null) return;

    _isShowing = true;
    try {
      // The close (X) is the only way out — no barrier dismiss, so the user
      // has actually seen it before it drops into the list.
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AnnouncementDialog(announcement: announcement),
      );

      await _markRead(announcement.id);
    } finally {
      _isShowing = false;
    }
  }

  Future<void> _markRead(int id) async {
    if (Get.isRegistered<AnnouncementController>()) {
      await Get.find<AnnouncementController>().markAsRead(id);
      return;
    }

    // List screen was never opened this session — mark it on the server
    // directly so the dialog doesn't count as unread.
    final role = AnnouncementSession.current();
    if (role == null) return;

    try {
      await _api.request(
        url: '${AppConstants.baseUrl}${role.apiPrefix}/announcements/$id/read',
        body: {},
        token: role.token,
      );
    } catch (e) {
      debugPrint('Announcement mark-read failed: $e');
    }
  }

  void _syncBadge(dynamic unreadCount) {
    if (unreadCount == null) return;
    if (!Get.isRegistered<AnnouncementController>()) return;

    final count = int.tryParse('$unreadCount');
    if (count != null) {
      Get.find<AnnouncementController>().unreadCount.value = count;
    }
  }
}
