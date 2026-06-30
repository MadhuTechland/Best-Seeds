import ActivityKit
import WidgetKit
import SwiftUI

/// Live Activity for an active delivery journey.
///
/// Shown:
///   • Lock screen — always-visible tile while the journey is active.
///   • Dynamic Island — compact pill, expanded view when tapped/long-pressed,
///     minimal indicator when several activities are stacked.
///
/// The Runner app starts / updates / ends the activity via ActivityKit
/// (see BestseedLiveActivityManager). This file only describes the UI.
@available(iOS 16.1, *)
struct BestseedTrackingWidgetExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BestseedTrackingAttributes.self) { context in
            // MARK: Lock-screen / Banner view
            LockScreenView(context: context)
                .padding(16)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(Color(.label))
        } dynamicIsland: { context in
            // MARK: Dynamic Island
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "truck.box.fill")
                        .foregroundColor(.blue)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(gpsAge(from: context.state.lastSentAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("Delivering")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.locationName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let stop = context.state.nextStop, !stop.isEmpty {
                            Text(stop)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "truck.box.fill")
                    .foregroundColor(.blue)
            } compactTrailing: {
                Text(gpsAge(from: context.state.lastSentAt))
                    .font(.caption2)
            } minimal: {
                Image(systemName: "truck.box.fill")
                    .foregroundColor(.blue)
            }
            .widgetURL(URL(string: "bestseed://tracking"))
            .keylineTint(.blue)
        }
    }
}

// MARK: - Lock-screen layout

@available(iOS 16.1, *)
private struct LockScreenView: View {
    let context: ActivityViewContext<BestseedTrackingAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "truck.box.fill")
                .font(.title)
                .foregroundColor(.blue)
                .frame(width: 44, height: 44)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Bestseed — Delivering")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                Text(context.state.locationName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let stop = context.state.nextStop, !stop.isEmpty {
                    Text(stop)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(gpsAge(from: context.state.lastSentAt))
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)
                Circle()
                    .fill(isFresh(context.state.lastSentAt) ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
            }
        }
    }
}

// MARK: - Shared helpers

@available(iOS 16.1, *)
private func gpsAge(from date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 90 { return "just now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    return "\(hours)h ago"
}

@available(iOS 16.1, *)
private func isFresh(_ date: Date) -> Bool {
    Date().timeIntervalSince(date) < 120
}
