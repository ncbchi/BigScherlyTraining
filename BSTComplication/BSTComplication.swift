import WidgetKit
import SwiftUI

// Complication for the watch face. Priority per the product decision:
// 1) streak / training status, 2) next workout, 3) unread messages.
// Reads the last snapshot the phone sent (cached in UserDefaults by WatchState),
// so the face has data even between updates.

struct BSTComplicationEntry: TimelineEntry {
    let date: Date
    let streakWeeks: Int
    let status: String
    let nextWorkout: String
    let unread: Int
}

struct BSTComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> BSTComplicationEntry {
        BSTComplicationEntry(date: Date(), streakWeeks: 4, status: "On track",
                             nextWorkout: "Leg Day", unread: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (BSTComplicationEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BSTComplicationEntry>) -> Void) {
        // Refresh hourly; WatchState also nudges a reload when new data arrives.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [currentEntry()], policy: .after(next)))
    }

    private func currentEntry() -> BSTComplicationEntry {
        let shared = UserDefaults(suiteName: "group.bigscherlytraining.app") ?? .standard
        let ctx = shared.dictionary(forKey: "bst.watch.lastContext")
            ?? UserDefaults.standard.dictionary(forKey: "bst.watch.lastContext") ?? [:]
        return BSTComplicationEntry(
            date: Date(),
            streakWeeks: ctx["streakWeeks"] as? Int ?? 0,
            status: ctx["trainingStatus"] as? String ?? "—",
            nextWorkout: ctx["nextWorkoutTitle"] as? String ?? "—",
            unread: ctx["unreadMessages"] as? Int ?? 0)
    }
}

struct BSTComplicationView: View {
    @Environment(\.widgetFamily) var family
    let entry: BSTComplicationEntry
    private let volt = Color(red: 0xE8/255, green: 0xFB/255, blue: 0x52/255)

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "flame.fill").foregroundColor(volt).font(.system(size: 13))
                    Text("\(entry.streakWeeks)w").font(.system(size: 13, weight: .bold))
                }
            }
        case .accessoryInline:
            Label("\(entry.streakWeeks)w · \(entry.status)", systemImage: "flame.fill")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill").foregroundColor(volt)
                    Text(entry.streakWeeks > 0 ? "\(entry.streakWeeks)-week streak" : "Get started")
                        .font(.system(size: 13, weight: .bold))
                }
                Text(entry.nextWorkout).font(.system(size: 12)).lineLimit(1)
                if entry.unread > 0 {
                    Text("\(entry.unread) new message\(entry.unread == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundColor(volt)
                } else {
                    Text(entry.status).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        default:
            Text("\(entry.streakWeeks)w")
        }
    }
}

struct BSTComplication: Widget {
    let kind = "BSTComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BSTComplicationProvider()) { entry in
            BSTComplicationView(entry: entry)
        }
        .configurationDisplayName("Big Scherly")
        .description("Your streak, next workout, and coach messages.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

// Called from WatchState when fresh data arrives, to nudge the face.
enum ComplicationRefresher {
    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
