import Foundation
import ActivityKit

/// Wraps ActivityKit so the rest of the app (and Flutter via MethodChannel)
/// never has to deal with availability checks or Activity<…> generics.
///
/// All methods are no-ops on iOS < 16.1 — older devices fall back to the
/// existing notification path and won't show a Live Activity.
@objc final class BestseedLiveActivityManager: NSObject {

    @objc static let shared = BestseedLiveActivityManager()
    private override init() {}

    // Tracks the currently-running activity so update / end can address it
    // without re-discovering it from Activity.activities each time.
    private var currentActivityId: String?

    // MARK: - Public API

    /// Convert the dictionary form of stops (sent across the Flutter
    /// MethodChannel as `[[String: Any]]`) into the typed Swift struct used
    /// by the widget. Invalid entries are silently dropped.
    @available(iOS 16.1, *)
    private func parseStops(_ raw: [[String: Any]]?) -> [BestseedRouteStop] {
        guard let raw else { return [] }
        return raw.compactMap { dict in
            guard
                let name = dict["name"] as? String,
                let progress = dict["progress"] as? Double
            else { return nil }
            let status = (dict["status"] as? Int) ?? 0
            return BestseedRouteStop(name: name, progress: progress, status: status)
        }
    }

    /// Start a Live Activity for an active delivery journey.
    /// Idempotent — if one is already running, this just updates it.
    @objc func start(
        journeyId: String,
        driverName: String,
        locationName: String,
        latitude: Double,
        longitude: Double,
        lastSentAtEpoch: Double,
        nextStop: String?,
        pickupName: String?,
        dropName: String?,
        progress: Double,
        etaText: String?,
        stops: [[String: Any]]?
    ) {
        guard #available(iOS 16.1, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("LiveActivity: user has disabled Live Activities — skipping")
            return
        }

        let parsedStops = parseStops(stops)

        // If there's already an activity for this journey, update it instead
        // of starting a duplicate. Restarting tracking after a token refresh
        // or a brief background-foreground bounce hits this path.
        if currentActivityId != nil {
            update(
                locationName: locationName,
                latitude: latitude,
                longitude: longitude,
                lastSentAtEpoch: lastSentAtEpoch,
                nextStop: nextStop,
                pickupName: pickupName,
                dropName: dropName,
                progress: progress,
                etaText: etaText,
                stops: stops
            )
            return
        }

        let attributes = BestseedTrackingAttributes(
            journeyId: journeyId,
            driverName: driverName
        )
        let state = BestseedTrackingAttributes.ContentState(
            locationName: locationName,
            latitude: latitude,
            longitude: longitude,
            lastSentAt: Date(timeIntervalSince1970: lastSentAtEpoch),
            nextStop: nextStop,
            pickupName: pickupName,
            dropName: dropName,
            progress: progress,
            etaText: etaText,
            stops: parsedStops
        )

        do {
            let activity: Activity<BestseedTrackingAttributes>
            if #available(iOS 16.2, *) {
                activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
            } else {
                activity = try Activity.request(
                    attributes: attributes,
                    contentState: state,
                    pushType: nil
                )
            }
            currentActivityId = activity.id
            NSLog("LiveActivity: started id=\(activity.id) for journey=\(journeyId)")
        } catch {
            NSLog("LiveActivity: failed to start — \(error.localizedDescription)")
        }
    }

    /// Update the running activity's ContentState. Safe to call from any
    /// thread (ActivityKit dispatches internally).
    @objc func update(
        locationName: String,
        latitude: Double,
        longitude: Double,
        lastSentAtEpoch: Double,
        nextStop: String?,
        pickupName: String?,
        dropName: String?,
        progress: Double,
        etaText: String?,
        stops: [[String: Any]]?
    ) {
        guard #available(iOS 16.1, *) else { return }
        guard let id = currentActivityId,
              let activity = Activity<BestseedTrackingAttributes>.activities
                .first(where: { $0.id == id }) else {
            return
        }

        let parsedStops = parseStops(stops)
        let newState = BestseedTrackingAttributes.ContentState(
            locationName: locationName,
            latitude: latitude,
            longitude: longitude,
            lastSentAt: Date(timeIntervalSince1970: lastSentAtEpoch),
            nextStop: nextStop,
            pickupName: pickupName,
            dropName: dropName,
            progress: progress,
            etaText: etaText,
            stops: parsedStops
        )

        Task {
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: newState, staleDate: nil))
            } else {
                await activity.update(using: newState)
            }
        }
    }

    /// End the running activity. The lock-screen tile fades out within a few
    /// seconds. We use `.immediate` so the tile disappears at journey end
    /// (delivered / cancelled) — not after the default 4-hour timeout.
    @objc func end() {
        guard #available(iOS 16.1, *) else { return }
        guard let id = currentActivityId else { return }

        Task {
            for activity in Activity<BestseedTrackingAttributes>.activities where activity.id == id {
                if #available(iOS 16.2, *) {
                    await activity.end(nil, dismissalPolicy: .immediate)
                } else {
                    await activity.end(dismissalPolicy: .immediate)
                }
            }
        }
        currentActivityId = nil
        NSLog("LiveActivity: ended")
    }
}
