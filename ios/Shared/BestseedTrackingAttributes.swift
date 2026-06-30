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
/// `attributes` are immutable for the lifetime of the activity (driver name,
/// order id). `ContentState` is what changes — updated by the Runner app on
/// every successful location send.
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

        public init(
            locationName: String,
            latitude: Double,
            longitude: Double,
            lastSentAt: Date,
            nextStop: String? = nil
        ) {
            self.locationName = locationName
            self.latitude = latitude
            self.longitude = longitude
            self.lastSentAt = lastSentAt
            self.nextStop = nextStop
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
