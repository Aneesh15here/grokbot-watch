import GrokBotCore
import SwiftUI
import WidgetKit

struct ActivityEntry: TimelineEntry, Sendable {
    var date: Date
    var snapshot: ActivitySnapshot
}

struct ActivityProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActivityEntry {
        ActivityEntry(date: Date(), snapshot: .placeholderSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (ActivityEntry) -> Void) {
        completion(ActivityEntry(date: Date(), snapshot: current()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ActivityEntry>) -> Void) {
        let entry = ActivityEntry(date: Date(), snapshot: current())
        let refresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func current() -> ActivitySnapshot {
        guard let url = SharedLocations.activityURL(
            useAppGroup: AppGroupAccess.isEnabled(),
            appGroupID: AppGroupAccess.groupID()
        ) else {
            return .placeholderSnapshot
        }
        return ActivityFile.read(from: url) ?? .placeholderSnapshot
    }
}

struct BotActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GrokBotAPI.widgetKind, provider: ActivityProvider()) { entry in
            BotActivityView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Grok Bot")
        .description("Shows whether your last active bot is working.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner
        ])
    }
}

struct BotActivityView: View {
    @Environment(\.widgetFamily) private var family
    var snapshot: ActivitySnapshot

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            Text(snapshot.inlineText)
        case .accessoryCorner:
            Text(snapshot.shortStatus)
                .widgetLabel { Text(snapshot.botName) }
        default:
            Text(snapshot.inlineText)
        }
    }

    private var circular: some View {
        VStack(spacing: 0) {
            Image(systemName: snapshot.placeholder ? "applewatch" : snapshot.phase.symbolName)
                .font(.headline)
            Text(snapshot.shortStatus)
                .font(.system(size: 10, weight: .semibold))
        }
        .accessibilityLabel(snapshot.inlineText)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.botName)
                .font(.headline)
                .lineLimit(1)
            Text(snapshot.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(snapshot.inlineText)
    }
}

@main
struct GrokBotWidgets: WidgetBundle {
    var body: some Widget {
        BotActivityWidget()
    }
}
