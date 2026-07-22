import ActivityKit
import WidgetKit
import SwiftUI

/// Live Activity for an active delivery journey.
///
/// Renders three surfaces:
///   • Lock screen — a Maps-style route card with pickup → drop progress bar.
///   • Dynamic Island expanded — compact version of the same route view.
///   • Dynamic Island compact / minimal — just a truck icon + GPS-age pill.
///
/// State is driven entirely by the Runner app via
/// `BestseedLiveActivityManager` — this file is pure view code.
@available(iOS 16.1, *)
struct BestseedTrackingWidgetExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BestseedTrackingAttributes.self) { context in
            // MARK: Lock-screen / Banner
            LockScreenView(context: context)
                .padding(14)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(Color(.label))
        } dynamicIsland: { context in
            // MARK: Dynamic Island
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "truck.box.fill")
                        .foregroundColor(.blue)
                        .font(.title3)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if let eta = context.state.etaText {
                            Text(eta)
                        } else {
                            // Auto-ticking relative age — iOS redraws this on
                            // its own schedule even when Flutter is dead, so
                            // "just now" naturally becomes "5 min ago", "1 h
                            // ago", etc. without any app-side push.
                            Text(context.state.lastSentAt, style: .relative)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .fixedSize()
                }
                DynamicIslandExpandedRegion(.center) {
                    // Short status only — the destination name already
                    // appears once at the bottom inside the route bar.
                    Text("Delivering")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        RouteBar(context: context, compact: true)
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill")
                                .font(.caption2)
                                .foregroundColor(.blue)
                            Text(context.state.locationName)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(context.state.lastSentAt, style: .relative)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize()
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "truck.box.fill")
                    .foregroundColor(.blue)
            } compactTrailing: {
                Group {
                    if let eta = context.state.etaText {
                        Text(eta)
                    } else {
                        // Auto-ticking — iOS updates the compact pill on its
                        // own schedule without needing Flutter to be alive.
                        Text(context.state.lastSentAt, style: .relative)
                    }
                }
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
        VStack(alignment: .leading, spacing: 12) {
            // Header row: app icon + status text + ETA badge
            HStack(spacing: 10) {
                Image(systemName: "truck.box.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 32, height: 32)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Bestseed — Delivering")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                    Text(headerText(context.state))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let eta = context.state.etaText {
                    Text(eta)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .clipShape(Capsule())
                }
            }

            // Route bar
            RouteBar(context: context, compact: false)

            // Footer: current location + GPS freshness dot
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.caption2)
                    .foregroundColor(.blue)
                Text(context.state.locationName)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Circle()
                    .fill(isFresh(context.state.lastSentAt) ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                // Auto-ticking — iOS itself redraws this every ~15s while the
                // widget is on the lock screen, so the age keeps advancing
                // "just now" → "1 min ago" → "5 min ago" without needing the
                // Runner app to be alive to push updates.
                Text(context.state.lastSentAt, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Route bar (Maps-style progress)

@available(iOS 16.1, *)
private struct RouteBar: View {
    let context: ActivityViewContext<BestseedTrackingAttributes>
    /// When `true` use a tighter layout for the Dynamic Island expanded region.
    let compact: Bool

    var body: some View {
        let pickup = context.state.pickupName ?? "Start"
        let drop = context.state.dropName ?? "Destination"
        let progress = context.state.progress
        let trackHeight: CGFloat = compact ? 4 : 6
        let truckSize: CGFloat = compact ? 16 : 20

        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            GeometryReader { geo in
                let inset = trackHeight + 4
                let usableWidth = max(0, geo.size.width - inset * 2)
                ZStack(alignment: .leading) {
                    // Endpoints
                    HStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: trackHeight + 2, height: trackHeight + 2)
                        Spacer()
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: trackHeight + 6))
                            .foregroundColor(.red)
                    }
                    // Track background
                    Capsule()
                        .fill(Color.gray.opacity(0.25))
                        .frame(height: trackHeight)
                        .padding(.horizontal, inset)
                    // Progress fill
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.85), Color.blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: usableWidth * progress, height: trackHeight)
                        .padding(.leading, inset)
                    // Intermediate stop dots. Skipped on the compact (Dynamic
                    // Island expanded) layout when there are more than ~4 to
                    // avoid crowding; the lock-screen view always renders them.
                    ForEach(Array(context.state.stops.enumerated()), id: \.offset) { _, stop in
                        StopDot(stop: stop, currentProgress: progress, compact: compact)
                            .offset(
                                x: inset + usableWidth * stop.progress -
                                    (compact ? 4 : 5)
                            )
                    }
                    // Truck on the path — drawn LAST so it always sits on top
                    // of the stop dots when it passes through them.
                    Image(systemName: "truck.box.fill")
                        .font(.system(size: truckSize))
                        .foregroundColor(.blue)
                        .background(
                            Circle()
                                .fill(Color(.systemBackground))
                                .frame(width: truckSize + 6, height: truckSize + 6)
                        )
                        .offset(x: max(0, inset + usableWidth * progress - truckSize / 2))
                }
            }
            .frame(height: max(trackHeight + 2, truckSize) + 2)

            // Pickup / drop labels under the bar. On the lock screen we have
            // room to show the full address; on the Dynamic Island we use
            // the short form (first comma-segment) so a long address like
            // "Naguluppala Padu, Prakasam, Andhra Pradesh, 523262, India"
            // shows as "Naguluppala Padu" — readable without truncation.
            HStack {
                Text(compact ? shortName(pickup) : pickup)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(compact ? shortName(drop) : drop)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

// MARK: - Short-name helper

/// Extract the first comma-separated segment of a place name so long
/// addresses render compactly inside the Dynamic Island. Falls back to
/// the original string when there are no commas.
@available(iOS 16.1, *)
private func shortName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    if let comma = trimmed.firstIndex(of: ",") {
        return String(trimmed[..<comma]).trimmingCharacters(in: .whitespaces)
    }
    return trimmed
}

// MARK: - Stop dot

@available(iOS 16.1, *)
private struct StopDot: View {
    let stop: BestseedRouteStop
    let currentProgress: Double
    let compact: Bool

    var body: some View {
        let size: CGFloat = compact ? 8 : 10
        let (fill, ring): (Color, Color) = {
            switch stop.status {
            case 2:
                // Delivered
                return (Color.green, Color.green.opacity(0.35))
            case 1:
                // Current target (next drop)
                return (Color.blue, Color.blue.opacity(0.4))
            default:
                // Upcoming — fade with whether the truck has visually passed it
                let passed = currentProgress >= stop.progress
                return passed
                    ? (Color.blue.opacity(0.75), Color.blue.opacity(0.25))
                    : (Color(.systemBackground), Color.gray.opacity(0.6))
            }
        }()
        ZStack {
            Circle()
                .fill(ring)
                .frame(width: size + 4, height: size + 4)
            Circle()
                .fill(fill)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Header text helper

@available(iOS 16.1, *)
private func headerText(_ state: BestseedTrackingAttributes.ContentState) -> String {
    if let next = state.nextStop, !next.isEmpty {
        return next
    }
    if let drop = state.dropName, !drop.isEmpty {
        return "Heading to \(drop)"
    }
    return "Live tracking"
}

// MARK: - Shared helpers

/// True if the last GPS fix is recent enough for the freshness dot to stay
/// green. This is evaluated at body-build time; SwiftUI re-runs it whenever
/// the widget is redrawn by an `activity.update()`. The auto-ticking
/// `Text(_:style: .relative)` fields nearby refresh independently on iOS's
/// own schedule, so the dot may lag by one update cycle vs the age text —
/// acceptable trade-off for keeping the view code trivial.
@available(iOS 16.1, *)
private func isFresh(_ date: Date) -> Bool {
    Date().timeIntervalSince(date) < 120
}
