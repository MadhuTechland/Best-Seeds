import 'package:bestseeds/driver/repository/driver_auth_repository.dart';
import 'package:bestseeds/driver/services/background_location_service.dart';
import 'package:bestseeds/driver/services/driver_storage_service.dart';
import 'package:bestseeds/employee/repository/auth_repository.dart';
import 'package:bestseeds/employee/services/storage_service.dart';
import 'package:bestseeds/routes/app_constants.dart';
import 'package:bestseeds/routes/app_routes.dart';
import 'package:bestseeds/services/notification_service.dart';
import 'package:bestseeds/services/version_check_service.dart';
import 'package:bestseeds/widgets/login_location_screen.dart';
import 'package:bestseeds/widgets/update_gate.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.skipUpdateGate = false});

  /// Set when re-entering splash after the driver tapped "Later" on the
  /// force-update screen.
  ///
  /// Only the update gate is skipped — everything after it still runs, because
  /// that is where the session is validated, the FCM token is registered and
  /// (critically for a driver mid-journey) background location tracking is
  /// restarted via [BackgroundLocationService.restartIfNeeded].
  final bool skipUpdateGate;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    // ── Force-update gate (Play In-App Updates + Firebase Remote Config) ──
    // Runs FIRST — before any auth/token navigation. On update available
    // we replace the whole stack with DriverForceUpdateScreen, mirroring
    // the pattern used by the user app. Doing it here (rather than via a
    // MaterialApp.builder wrapper) avoids the dialog-vs-Navigator race
    // where splash's own Get.offAllNamed would pop the dialog.
    //
    // Skipped when we got here from "Later": re-running the check would cost
    // up to ~14 s (Play 6 s + Remote Config 6 s + the delay below) staring at
    // a frozen screen, and could bounce the driver straight back to the gate
    // if the journey fingerprint no longer matched. Everything AFTER the gate
    // still runs — that is where the session is validated, the FCM token is
    // registered and background tracking is restarted.
    if (!widget.skipUpdateGate) {
      try {
        final v = await DriverVersionCheck.checkForceUpdate();
        if (v.decision == DriverForceUpdateDecision.showBlockScreen) {
          if (!mounted) return;
          Get.offAll(() => DriverForceUpdateScreen(
                useInAppUpdate: v.useInAppUpdate,
                storeUrlAndroid: v.storeUrlAndroid,
                storeUrlIos: v.storeUrlIos,
                allowLater: v.inJourney,
                journeyFingerprint: v.journeyFingerprint,
                // "Later" re-enters splash with the gate disabled.
                //
                // It used to restart splash plainly, which replayed the whole
                // gate before the driver saw anything: Play In-App Update (6 s
                // timeout) + Remote Config fetch (6 s timeout, and
                // minimumFetchInterval is zero so it always hits the network) +
                // the 2 s branding delay. Mid-journey on a weak signal that is
                // many seconds of an apparently frozen screen — and if the
                // journey fingerprint no longer matched on the way back, the
                // gate simply reappeared. Both read as "Later does nothing".
                //
                // Skipping the gate (rather than jumping straight to
                // driverHome) keeps the rest of splash: token validation, FCM
                // registration, the hasLocation check, and above all
                // BackgroundLocationService.restartIfNeeded — without which a
                // driver who taps Later mid-journey would lose GPS tracking for
                // the remainder of the trip.
                onLater: () async {
                  Get.offAll(() => const SplashScreen(skipUpdateGate: true));
                },
              ));
          return;
        }
      } catch (e) {
        debugPrint('Splash: DriverVersionCheck failed (non-fatal): $e');
      }
    }

    // Cosmetic branding pause — cold start only. Coming back from "Later" the
    // driver has already been staring at the gate, so don't add two more
    // seconds before they get into the app.
    if (!widget.skipUpdateGate) {
      await Future.delayed(const Duration(seconds: 2));
    }

    final employeeStorage = StorageService();
    final driverStorage = DriverStorageService();

    // ── Legacy backend version-check gate ──
    // Kept as a secondary check for the old `/api/app-version-check`
    // endpoint (independent of Play In-App Updates). Fires only when a
    // session exists so it doesn't add latency to first-time users.
    final hasEmployeeSession = await employeeStorage.getUser() != null;
    final hasDriverSession = await driverStorage.getDriver() != null;
    if (hasDriverSession) {
      final r = await VersionCheckService.runOnStartup(app: 'driver');
      if (r == VersionCheckResult.forceUpdate) return;
    } else if (hasEmployeeSession) {
      final r = await VersionCheckService.runOnStartup(app: 'vendor');
      if (r == VersionCheckResult.forceUpdate) return;
    }

    // Check if employee is logged in
    final employee = await employeeStorage.getUser();
    if (employee != null) {
      // Validate token — catches stale tokens restored from Android backup after reinstall
      try {
        final validate = await http.get(
          Uri.parse(AppConstants.baseUrl + AppConstants.employeeProfileApi),
          headers: {
            'Authorization': 'Bearer ${employee.token}',
            'Accept': 'application/json'
          },
        ).timeout(const Duration(seconds: 5));
        if (validate.statusCode == 401) {
          await employeeStorage.logout();
          Get.offAllNamed(AppRoutes.login);
          return;
        }
      } catch (_) {
        // Network error / timeout — proceed with cached data (user may be offline)
      }

      print('Splash: Employee found - ${employee.name}');
      // Register FCM token on auto-login
      NotificationService().registerEmployeeToken();

      // Check if employee has location saved
      if (!employeeStorage.hasLocation()) {
        print(
            'Splash: Employee has no location, navigating to location screen');
        Get.offAll(() => LoginLocationScreen(
              userType: 'employee',
              onLocationSelected: (location) async {
                // Save location to local storage
                await employeeStorage.saveLocation(
                  latitude: location.latitude,
                  longitude: location.longitude,
                  address: location.address,
                );
                print('Splash: Employee location saved locally');

                // Save location to backend
                try {
                  final repo = AuthRepository();
                  await repo.updateCurrentLocation(
                    token: employee.token,
                    latitude: location.latitude,
                    longitude: location.longitude,
                    address: location.address,
                  );
                  print('Splash: Employee location saved to backend');
                } catch (e) {
                  print(
                      'Splash: Failed to save employee location to backend: $e');
                }

                // Navigate to home
                Get.offAllNamed(AppRoutes.employeeHome);
              },
            ));
        return;
      }

      Get.offAllNamed(AppRoutes.employeeHome);
      // Handle pending notification if app was opened from terminated state
      Future.delayed(const Duration(milliseconds: 500), () {
        NotificationService.handlePendingNotification();
      });
      return;
    }

    // Check if driver is logged in
    final driver = await driverStorage.getDriver();
    if (driver != null) {
      // Validate token — catches stale tokens restored from Android backup after reinstall.
      // Retry once on 401 with a short delay to survive network handoffs
      // (mobile↔WiFi, captive-portal middleboxes) — mirrors the retry in
      // api_clients.dart. Only logout if two consecutive 401s in a row.
      try {
        Future<http.Response> validate() => http.get(
              Uri.parse(AppConstants.baseUrl + AppConstants.driverProfileApi),
              headers: {
                'Authorization': 'Bearer ${driver.token}',
                'Accept': 'application/json'
              },
            ).timeout(const Duration(seconds: 5));

        var resp = await validate();
        if (resp.statusCode == 401) {
          await Future.delayed(const Duration(milliseconds: 1500));
          try {
            resp = await validate();
          } catch (_) {
            // Network still unstable — keep session, proceed with cached data.
            print('Splash: retry-validate network error, keeping session');
            resp = http.Response('', 200); // synthetic pass-through
          }
        }
        if (resp.statusCode == 401) {
          await driverStorage.logout();
          Get.offAllNamed(AppRoutes.login);
          return;
        }
      } catch (_) {
        // Network error / timeout — proceed with cached data (user may be offline)
      }

      print('Splash: Driver found - ${driver.name}');
      // Register FCM token on auto-login
      NotificationService().registerDriverToken();

      // Check if driver has location saved
      if (!driverStorage.hasLocation()) {
        // Make sure no stale background tracking service interferes with the
        // login location picker after logout/re-login.
        await BackgroundLocationService.stop();

        print('Splash: Driver has no location, navigating to location screen');
        Get.offAll(() => LoginLocationScreen(
              userType: 'driver',
              onLocationSelected: (location) async {
                // Save location to local storage
                await driverStorage.saveLocation(
                  latitude: location.latitude,
                  longitude: location.longitude,
                  address: location.address,
                );
                print('Splash: Driver location saved locally');

                // Save location to backend
                try {
                  final repo = DriverAuthRepository();
                  await repo.updateCurrentLocation(
                    token: driver.token,
                    latitude: location.latitude,
                    longitude: location.longitude,
                    address: location.address,
                  );
                  print('Splash: Driver location saved to backend');
                } catch (e) {
                  print(
                      'Splash: Failed to save driver location to backend: $e');
                }

                // Navigate to home
                Get.offAllNamed(AppRoutes.driverHome);
              },
            ));
        return;
      }

      // Restart background location service if it was killed during active journey
      await BackgroundLocationService.restartIfNeeded();
      Get.offAllNamed(AppRoutes.driverHome);
      return;
    }

    // No user logged in, go to driver login (default)
    print('Splash: No user found, going to login');
    Get.offAllNamed(AppRoutes.login);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF0077C8),
              Color(0xFF3FA9F5),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/images/logo.jpeg',
              width: width * 0.4,
              errorBuilder: (context, error, stackTrace) {
                return Icon(
                  Icons.local_shipping,
                  size: width * 0.3,
                  color: Colors.white,
                );
              },
            ),
            SizedBox(height: width * 0.06),
            Text(
              'Bestseed',
              style: TextStyle(
                color: Colors.white,
                fontSize: width * 0.08,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: width * 0.04),
            const CircularProgressIndicator(
              color: Colors.white,
              strokeWidth: 2,
            ),
          ],
        ),
      ),
    );
  }
}
