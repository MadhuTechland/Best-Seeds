# On-demand location refresh — FCM contract

## Goal

When a vendor (or customer) opens the tracking screen, the server pings the
driver app via FCM to capture a single fresh GPS fix. The driver app posts
that fix to the existing `POST /driver/location/update` endpoint and the
vendor screen sees a position that is no older than the round-trip time
(typically 2–8 s).

## Driver-app side

Already wired. Both foreground and background FCM handlers in
[`lib/services/notification_service.dart`](../lib/services/notification_service.dart)
react to `data.type == "request_location"` by calling
[`captureAndPostOnDemandLocation()`](../lib/driver/services/on_demand_location.dart),
which:

1. Reads the driver token from SharedPreferences.
2. Requires the journey to be active (`bg_location_service_running == true`).
3. Calls `Geolocator.getCurrentPosition(timeLimit: 10s)` with a `getLastKnownPosition()` fallback.
4. POSTs the position to `/driver/location/update` with an extra `source: "on_demand"` field so the backend can distinguish on-demand pushes from the regular stream if useful.

## FCM message shape

Send a **data-only** message (no notification block). Notification blocks
trigger banner UI; we want this to be silent.

```json
{
  "message": {
    "token": "<DRIVER_FCM_TOKEN>",
    "data": {
      "type": "request_location",
      "booking_id": "<optional, for analytics>"
    },
    "android": {
      "priority": "high",
      "ttl": "30s"
    },
    "apns": {
      "headers": {
        "apns-priority": "5",
        "apns-push-type": "background"
      },
      "payload": {
        "aps": {
          "content-available": 1
        }
      }
    }
  }
}
```

Critical fields:

| Field | Why |
|---|---|
| `android.priority: "high"` | Required to wake the app from Doze. Default `normal` is delayed. |
| `android.ttl: "30s"` | If the device is offline / Doze-deep, drop the request rather than delivering a stale one minutes later. |
| `apns.headers.apns-push-type: "background"` | Tells iOS this is a silent push, not a user-visible notification. |
| `apns.headers.apns-priority: "5"` | Apple requires priority 5 for `content-available: 1`; priority 10 will be rejected. |
| `aps.content-available: 1` | The flag that wakes the iOS background handler. |
| **No** `notification` block | If present, iOS will show a banner instead of waking the handler. |

## iOS reliability caveats — read before promising vendors a 5-second refresh

Apple **throttles** silent pushes per app:
- Typically only a few `content-available: 1` pushes per hour are delivered to a backgrounded app.
- A **swipe-killed** app on iOS will not be woken reliably by silent push.
  iOS treats swipe-kill as "user wants this off." This is the same Apple
  policy that limits Live Activities, not a code bug.
- iOS Low Power Mode disables silent push delivery almost entirely.
- The driver MUST have the app running (foreground or background, not swipe-killed)
  for on-demand to work reliably.

Android is more permissive: a high-priority data message wakes the app even
under Doze, with the exceptions of:
- Xiaomi / Realme / Vivo OEMs that aggressively block background work
  unless the user has granted "auto-start" and "no-restrictions" permission
  in the OEM settings.
- Force-stopped apps (user opened App Info → Force Stop). Same as iOS
  swipe-kill — no recovery via push.

## Recommended backend flow

```
Vendor opens tracking screen
  ↓
GET /vendor/bookings/{id}/tracking
  ↓
Server checks "last driver update age":
  - If < 30 s          → return existing data immediately
  - If 30 s – 5 min    → return existing data, queue an FCM push (fire-and-forget),
                         tell client to refetch in 5 s
  - If > 5 min         → return existing data with `stale: true`, send FCM push,
                         tell client to refetch in 8 s (longer because GPS cold-start)
```

This caps push volume per driver: at most one push per 5 s per booking,
regardless of how many vendors are watching.

## Optional: server endpoint to register on-demand windows

If multiple vendors view the same booking, dedupe by booking ID and only send
one push per N seconds even if 10 vendors are watching. Hold the FCM call
behind a short Redis lock:

```
KEY: ondemand_lock:{booking_id}
TTL: 5s
SET NX  → if you got the lock, send the FCM; otherwise skip
```

## Testing

To smoke-test the driver-side handler without a backend, send a manual FCM
from the Firebase console:
1. **Notifications → New campaign → Firebase Notification messages**
2. Toggle to **"Send test message"**, paste the driver's FCM token.
3. In **Additional options → Custom data**, add: key `type`, value `request_location`.
4. Send. Watch the driver-app logcat for the `📍 [ON-DEMAND]` log lines.

For production sends, use the FCM HTTP v1 API as in the JSON example above.
The Firebase admin SDKs (Node, Python, Java, Go) all handle the v1 protocol
natively — you just pass the same body in the SDK's typed message builder.
