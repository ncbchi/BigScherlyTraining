import SwiftUI

// MARK: - Dashboard (first screen after the welcome board)
// Surfaces the most-used info at a glance — today's workout, today's macros,
// unread badges — mirroring what Trainerize/TrueCoach lead with.
struct DashboardView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Eyebrow(text: "Today")
                Text("Your Day").font(BrandFont.display(48)).foregroundColor(.white)

                // Next workout
                if let w = store.upcomingWorkouts.first {
                    Button { store.select(.workouts) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("NEXT WORKOUT").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                                Spacer()
                                Text("\(w.dayOfWeek), \(w.dateLabel)").font(BrandFont.body(12, .semibold)).foregroundColor(Brand.mute)
                            }
                            Text(w.title).font(BrandFont.display(28)).foregroundColor(.white)
                            Text(w.exerciseSummary).font(BrandFont.body(13)).foregroundColor(Brand.mute).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                    }
                }

                // Today's macros mini
                if let m = store.todayMacros {
                    Button { store.select(.macros) } label: {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("TODAY'S MACROS").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                                Spacer()
                                Text(m.isTrainingDay ? "TRAINING DAY" : "REST DAY")
                                    .font(BrandFont.body(11, .bold)).foregroundColor(Brand.black)
                                    .padding(.horizontal, 8).padding(.vertical, 3).background(Brand.volt)
                            }
                            HStack(spacing: 20) {
                                macroMini("\(m.calorieGoal)", "kcal")
                                macroMini("\(m.proteinGoal)g", "protein")
                                macroMini("\(m.carbGoal)g", "carbs")
                                macroMini("\(m.fatGoal)g", "fat")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                    }
                }

                // Quick actions row
                HStack(spacing: 12) {
                    quickAction(.checkins, "Check-In")
                    quickAction(.photos, "Add Photo")
                    quickAction(.share, "Share Win")
                }

                // Unread chat / announcements
                if store.unreadMessages > 0 || !store.liveAnnouncements.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("NEW FOR YOU").font(BrandFont.body(11, .bold)).tracking(1.5).foregroundColor(Brand.volt)
                        if store.unreadMessages > 0 {
                            notifRow("bubble.left.and.bubble.right.fill", "\(store.unreadMessages) new message\(store.unreadMessages>1 ? "s" : "") from coach", .chat)
                        }
                        if let a = store.liveAnnouncements.first {
                            notifRow("megaphone.fill", a.title, .announcements)
                        }
                    }
                    .card()
                }
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    func macroMini(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(BrandFont.display(24)).foregroundColor(.white)
            Text(l.uppercased()).font(BrandFont.body(9, .semibold)).tracking(1).foregroundColor(Brand.mute)
        }
    }
    func quickAction(_ tab: AppTab, _ label: String) -> some View {
        Button { store.select(tab) } label: {
            VStack(spacing: 10) {
                Image(systemName: tab.icon).font(.system(size: 22)).foregroundColor(Brand.volt)
                Text(label.uppercased()).font(BrandFont.body(11, .bold)).tracking(0.5).foregroundColor(.white)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 22).card(padding: 0)
        }
    }
    func notifRow(_ icon: String, _ text: String, _ tab: AppTab) -> some View {
        Button { store.select(tab) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundColor(Brand.volt).frame(width: 22)
                Text(text).font(BrandFont.body(14, .medium)).foregroundColor(.white).multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(Brand.mute).font(.system(size: 12))
            }
        }
    }
}
