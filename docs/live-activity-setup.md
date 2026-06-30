# Live Activity — what's wired & what's left

The Widget Extension target is already added to the Xcode project (named
`BestseedTrackingWidgetExtension`). The boilerplate Xcode generated has
been overwritten with the real Live Activity code. A few small Xcode
configuration steps still need to happen by hand.

## File layout (everything is in the repo)

| Path | Target(s) | Purpose |
|---|---|---|
| `ios/Shared/BestseedTrackingAttributes.swift` | Runner **+** Widget | Shared `ActivityAttributes` type |
| `ios/Runner/BestseedLiveActivityManager.swift` | Runner | start / update / end wrapper |
| `ios/Runner/AppDelegate.swift` (edited) | Runner | `com.bestseed/live_activity` MethodChannel |
| `ios/Runner/Info.plist` (edited) | Runner | `NSSupportsLiveActivities = YES` |
| `ios/BestseedTrackingWidgetExtension/BestseedTrackingWidgetExtensionBundle.swift` | Widget | Bundle — registers only the Live Activity |
| `ios/BestseedTrackingWidgetExtension/BestseedTrackingWidgetExtensionLiveActivity.swift` | Widget | Lock-screen + Dynamic Island SwiftUI |
| `ios/BestseedTrackingWidgetExtension/BestseedTrackingWidgetExtension.swift` | Widget | (Empty stub — Xcode-referenced, no widget exported) |
| `ios/BestseedTrackingWidgetExtension/BestseedTrackingWidgetExtensionControl.swift` | Widget | (Empty stub — iOS 18+ ControlWidget removed) |
| `ios/BestseedTrackingWidgetExtension/Info.plist` | Widget | Extension manifest |
| `lib/driver/services/live_activity_service.dart` | Flutter | MethodChannel wrapper |
| `lib/driver/services/ios_location_service.dart` (edited) | Flutter | start / update / end call sites |

## Steps still required in Xcode UI

### 1. Add the shared attributes file to **both** targets

The file `ios/Shared/BestseedTrackingAttributes.swift` must be compiled
into both the Runner app and the Widget Extension so they share the same
Swift type identity.

1. In Xcode, drag the file from Finder into the project navigator (e.g.
   under a new "Shared" group at the project root).
2. In the "Add files" dialog:
   - **Copy items if needed:** ❌ unchecked (file is already at the right path)
   - **Add to targets:** ✅ Runner ✅ BestseedTrackingWidgetExtension

### 2. Add the Live Activity manager to the Runner target

Drag `ios/Runner/BestseedLiveActivityManager.swift` into Xcode under the
Runner group. **Add to targets:** ✅ Runner only.

### 3. Set the widget's deployment target to iOS 16.1

When Xcode created the Widget Extension target, it set `IPHONEOS_DEPLOYMENT_TARGET`
to the latest SDK (currently shown as `26.5` in the pbxproj). Fix this:

1. Select the project → `BestseedTrackingWidgetExtension` target → **General**.
2. **Minimum Deployments → iOS:** set to `16.1`.

Without this, the widget will only install on the very latest iOS, which
will break most drivers' phones. The main Runner target stays at iOS 15.0;
only the widget needs 16.1+.

### 4. Code signing

The widget target needs the same Team / signing as Runner.
1. Select the `BestseedTrackingWidgetExtension` target → **Signing & Capabilities**.
2. Set **Team** to the same team used by Runner.
3. **Automatically manage signing** ✅.

### 5. Build & verify

1. Build on a real iOS device on iOS 16.1+. Live Activities don't render
   in the iOS Simulator before iOS 16.2, and Dynamic Island only shows on
   iPhone 14 Pro / 15+ models — older devices still get the lock-screen tile.
2. Settings → Bestseed → Live Activities → **On** (per-app toggle).
3. Start a journey. You should see:
   - The persistent notification (existing behaviour).
   - A new **lock-screen tile** with the truck icon + "GPS just now".
   - On iPhone 14 Pro / 15+: a **Dynamic Island** pill at the top.
4. As the driver moves, the tile location + GPS-age text update on every
   successful send.

## Troubleshooting

- **"Cannot find type 'BestseedTrackingAttributes' in scope"** in the widget
  target → the shared file wasn't added to the widget target (Step 1).
- **Build error mentioning `ControlWidget`** → the Control widget file isn't
  empty; re-pull `BestseedTrackingWidgetExtensionControl.swift` from the repo.
- **Tile doesn't appear** → check `Settings → <App> → Live Activities` is
  on. Also confirm `NSSupportsLiveActivities` is `true` in
  `ios/Runner/Info.plist` (already added).
- **Builds for simulator but fails on device** → almost always a signing
  issue on the widget target (Step 4).
- **Tile shows but never updates** → confirm `LiveActivityService.update`
  is being called from `IosLocationService._onPosition`. Look for the
  "📍 [iOS-LOC] ✅ SENT" log; the update call sits right after that in
  [ios_location_service.dart](../lib/driver/services/ios_location_service.dart).

## Behaviour after build

- Tile starts when journey begins (driver hits Start Journey).
- Tile updates on every successful location send while the app is running
  (foreground or background).
- After **swipe-kill**, the tile keeps showing the last-known location for
  up to ~8 hours, OR until an SLC wakeup posts a new location through
  AppDelegate's native `didUpdateLocations` (which also pushes a tile update).
- Tile ends immediately when the journey completes / driver logs out / 401.
