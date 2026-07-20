import Foundation
import ActivityKit

/// Live Activity attributes shared between the Runner app (which starts /
/// updates / ends the activity) and the Widget Extension (which renders the
/// lock-screen + Dynamic Island UI).
///
/// IMPORTANT: this file must be added to BOTH targets in Xcode — Runner and
/// BestseedTrackingWidgetExtension. The type identity must match exactly, so
/// both targets compile against the same struct.
///
/// `attributes` are immutable for the lifetime of the activity (journey id,
/// driver name). `ContentState` is what changes — updated by the Runner app
/// on every successful location send.
/// One intermediate drop along the journey. Rendered as a dot on the
/// route bar; colour depends on `status` (0 = upcoming, 1 = current,
/// 2 = delivered). `progress` is the dot's horizontal position on the
/// bar (0.0 — 1.0).
@available(iOS 16.1, *)
public struct BestseedRouteStop: Codable, Hashable {
    public var name: String
    public var progress: Double
    public var status: Int

    public init(name: String, progress: Double, status: Int) {
        self.name = name
        self.progress = max(0, min(1, progress))
        self.status = status
    }
}

@available(iOS 16.1, *)
public struct BestseedTrackingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// User-facing location string ("Madhapur, Hyderabad").
        public var locationName: String
        /// Driver's last known coordinates.
        public var latitude: Double
        public var longitude: Double
        /// Epoch seconds of the most recent successful backend send.
        /// Used to render "GPS just now" / "GPS 5m ago" client-side.
        public var lastSentAt: Date
        /// Optional next-stop label (e.g. "Drop 2 of 5 — Komaragiri").
        public var nextStop: String?

        // ── Route metadata (renders the Maps-style progress bar) ────────
        /// Pickup point name shown on the left side of the route bar.
        /// `nil` until the driver app supplies an active booking.
        public var pickupName: String?
        /// Drop point name shown on the right side of the route bar.
        public var dropName: String?
        /// 0.0 — 1.0. Fraction of total journey distance covered. The
        /// driver app recomputes this from current/pickup/drop coordinates
        /// before each Live Activity update.
        public var progress: Double
        /// Pre-formatted ETA / distance-remaining text rendered next to the
        /// progress bar. Examples: "12 min", "5.2 km", "Arriving".
        public var etaText: String?
        /// Intermediate drops on the route. Rendered as small dots on the
        /// route bar at their `progress` positions, coloured by status.
        /// Empty when the journey has no intermediate stops (single-drop
        /// delivery), in which case the bar just shows pickup → drop.
        public var stops: [BestseedRouteStop]

        public init(
            locationName: String,
            latitude: Double,
            longitude: Double,
            lastSentAt: Date,
            nextStop: String? = nil,
            pickupName: String? = nil,
            dropName: String? = nil,
            progress: Double = 0,
            etaText: String? = nil,
            stops: [BestseedRouteStop] = []
        ) {
            self.locationName = locationName
            self.latitude = latitude
            self.longitude = longitude
            self.lastSentAt = lastSentAt
            self.nextStop = nextStop
            self.pickupName = pickupName
            self.dropName = dropName
            self.progress = max(0, min(1, progress))
            self.etaText = etaText
            self.stops = stops
        }
    }

    /// Static attributes set once at start() and never changed.
    public var journeyId: String
    public var driverName: String

    public init(journeyId: String, driverName: String) {
        self.journeyId = journeyId
        self.driverName = driverName
    }
}
