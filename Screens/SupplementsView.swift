import SwiftUI

// MARK: - Supplements
// Client view of the trainer-prescribed supplement protocol.
struct SupplementsView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("bst_supp_disclaimer_ack") private var disclaimerAck = false

    private var stacks: [SupplementStack] { store.supplementStacks }
    private var grouped: [(stack: SupplementStack?, items: [Supplement])] {
        let active = store.supplements.filter { $0.isActive }
        var out: [(SupplementStack?, [Supplement])] = []
        for st in stacks {
            let items = active.filter { $0.stackId == st.id }
            if !items.isEmpty { out.append((st, items)) }
        }
        let loose = active.filter { s in s.stackId == nil || !stacks.contains { $0.id == s.stackId } }
        if !loose.isEmpty { out.append((nil, loose)) }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DSScreenHeader(eyebrow: "Protocol", title: "Supplements",
                               subtitle: "Your stack, prescribed by your coach. Confirm each dose so your coach can track it.")
                    .padding(.bottom, 4)

                if !store.supplements.filter({ $0.isActive }).isEmpty {
                    adherenceCard
                }

                ForEach(Array(grouped.enumerated()), id: \.offset) { _, group in
                    stackCard(group.stack, group.items)
                }

                if store.supplements.filter({ $0.isActive }).isEmpty {
                    EmptyState(icon: "pills.fill",
                               title: "No supplements yet",
                               message: "Your coach hasn't prescribed any supplements yet. They'll appear here.")
                }

                Text("Supplements are prescribed by your coach for general wellness and are not medical advice. Consult your physician before starting any supplement.")
                    .font(BrandFont.body(11)).foregroundColor(Brand.mute)
                    .padding(.top, 8)
            }
            .padding(.top, 52).padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Brand.bg.ignoresSafeArea())
        .dsTopFade()
        .overlay { if !disclaimerAck { disclaimerGate } }
        .onAppear { SupplementEngine.shared.requestPermissionIfNeeded() }
    }

    // MARK: Adherence
    private var adherenceCard: some View {
        let a = SupplementEngine.shared.adherence(logs: store.supplementLogs)
        let active = store.supplements.filter { $0.isActive }
        let takenToday = active.filter { todayStatus($0) == .taken }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DSStatTile(value: "\(takenToday)/\(active.count)", label: "TAKEN TODAY")
                DSStatTile(value: "\(a.streakDays)", label: "DAY STREAK")
                DSStatTile(value: a.percentLabel, label: "30-DAY", color: Brand.text)
            }
            DSProgressBar(fraction: active.isEmpty ? 0 : Double(takenToday) / Double(active.count))
            if takenToday == active.count && !active.isEmpty {
                Label("All done for today — nice work.", systemImage: "checkmark.circle.fill")
                    .font(BrandFont.body(12, .semibold)).foregroundColor(Brand.voltText)
            }
        }
    }
    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundColor(Brand.voltText).font(.system(size: 16))
            Text(value).font(BrandFont.display(30)).foregroundColor(Brand.text)
            Text(label).font(BrandFont.body(11)).foregroundColor(Brand.mute)
        }.frame(maxWidth: .infinity)
    }

    // MARK: Stack card
    private func stackCard(_ stack: SupplementStack?, _ items: [Supplement]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(stack?.name ?? "Individual")
                    .font(BrandFont.body(13, .bold)).foregroundColor(Brand.voltText)
                    .textCase(.uppercase)
                Spacer()
                if items.count > 1, allPending(items) {
                    Button { for s in items { store.confirmSupplement(s) } } label: {
                        Text("Take all").font(BrandFont.body(12, .bold))
                            .foregroundColor(Brand.onVolt)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Brand.volt).clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            ForEach(items) { s in
                supplementRow(s)
                if s.id != items.last?.id { Divider().overlay(Brand.line).padding(.leading, 16) }
            }
        }
        .background(Brand.black).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }
    private func allPending(_ items: [Supplement]) -> Bool {
        items.allSatisfy { todayStatus($0) != .taken }
    }

    // MARK: Supplement row
    private func supplementRow(_ s: Supplement) -> some View {
        let status = todayStatus(s)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(s.name).font(BrandFont.body(16, .bold)).foregroundColor(Brand.text)
                        if s.isPrescription {
                            Text("Rx").font(BrandFont.body(9, .bold)).foregroundColor(Brand.card)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Brand.mute).clipShape(Capsule())
                        }
                    }
                    Text(s.dose.display).font(BrandFont.body(14, .semibold)).foregroundColor(Brand.voltText)
                    Text(s.timing.summary).font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    if let inst = s.instructions {
                        Text(inst).font(BrandFont.body(11)).foregroundColor(Brand.mute).italic()
                    }
                }
                Spacer()
                takeButton(s, status: status)
            }
            if s.lowStock { refillRow(s) }
        }
        .padding(16)
    }

    @ViewBuilder
    private func takeButton(_ s: Supplement, status: DoseStatus) -> some View {
        switch status {
        case .taken:
            Label("Taken", systemImage: "checkmark.circle.fill")
                .font(BrandFont.body(13, .bold)).foregroundColor(Brand.voltText)
                .labelStyle(.titleAndIcon)
        default:
            Button { store.confirmSupplement(s) } label: {
                Text("Mark taken").font(BrandFont.body(13, .bold)).foregroundColor(Brand.onVolt)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Brand.volt).clipShape(Capsule())
            }
        }
    }

    private func refillRow(_ s: Supplement) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
            Text("Low — \(s.quantityOnHand ?? 0) doses left").font(BrandFont.body(11, .semibold))
            Spacer()
            if let urlStr = s.reorderURL, let url = URL(string: urlStr) {
                Link(destination: url) {
                    Text("Reorder").font(BrandFont.body(11, .bold)).foregroundColor(Brand.onVolt)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Brand.volt).clipShape(Capsule())
                }
            }
        }
        .foregroundColor(Color(hex: 0xFFB84D))
        .padding(10)
        .background(Color(hex: 0xFFB84D).opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Today's status for a supplement
    private func todayStatus(_ s: Supplement) -> DoseStatus {
        let cal = Calendar.current
        if store.supplementLogs.contains(where: {
            $0.supplementId == s.id && $0.status == .taken && cal.isDateInToday($0.takenAt ?? .distantPast)
        }) { return .taken }
        return .pending
    }

    // MARK: One-time disclaimer gate
    private var disclaimerGate: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "cross.case.fill").font(.system(size: 40)).foregroundColor(Brand.voltText)
                Text("Before you start").font(BrandFont.display(30)).foregroundColor(Brand.text)
                Text("The supplements here are prescribed by your coach for general training and wellness support. This is not medical advice. Consult your physician before starting any supplement, especially if you take medication or have a health condition.")
                    .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                    .multilineTextAlignment(.center)
                Button { disclaimerAck = true } label: {
                    Text("I understand").font(BrandFont.body(15, .bold)).foregroundColor(Brand.onVolt)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(Brand.volt).clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(28)
        }
    }
}

// MARK: - Pre-workout confirm-on-open prompt
// Shown when the user opens Workouts and has "before workout" supplements not yet taken.
// Redesign: compact left-aligned header (no tall hero), full-width progress, tappable rows
// as the primary content, a pinned action button, and a graceful all-set state so the sheet
// can never render as an empty 0/0 shell.
struct PreWorkoutSupplementPrompt: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let supplements: [Supplement]

    @State private var appear = false

    private var takenCount: Int { supplements.filter(isTaken).count }
    private var allTaken: Bool { !supplements.isEmpty && supplements.allSatisfy(isTaken) }
    private var progress: CGFloat {
        supplements.isEmpty ? 0 : CGFloat(takenCount) / CGFloat(supplements.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Brand.line).frame(width: 40, height: 5)
                .padding(.top, 10).padding(.bottom, 18)

            if supplements.isEmpty {
                allSetState
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Brand.bg.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appear = true }
        }
    }

    // MARK: Populated state
    private var content: some View {
        VStack(spacing: 0) {
            // Compact header — icon + title on the left instead of a 150pt hero.
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(Brand.volt).frame(width: 46, height: 46)
                    Image(systemName: "pills.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(Brand.onVolt)
                }
                .scaleEffect(appear ? 1 : 0.6)
                .animation(.spring(response: 0.45, dampingFraction: 0.55), value: appear)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Fuel up first")
                        .font(BrandFont.display(26)).foregroundColor(Brand.text)
                    Text("Your coach set these for before you train.")
                        .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)

            // Full-width progress.
            VStack(spacing: 7) {
                HStack {
                    Text("TAKEN").font(BrandFont.body(11, .semibold)).tracking(1).foregroundColor(Brand.mute)
                    Spacer()
                    Text("\(takenCount) of \(supplements.count)")
                        .font(BrandFont.body(12, .semibold)).foregroundColor(Brand.voltText)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Brand.black).frame(height: 6)
                        Capsule().fill(Brand.volt)
                            .frame(width: max(0, geo.size.width * progress), height: 6)
                            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: takenCount)
                    }
                }
                .frame(height: 6)
            }
            .padding(.horizontal, 20).padding(.top, 18)

            // Rows — the primary content, staggered in on appear.
            ScrollView {
                VStack(spacing: 9) {
                    ForEach(Array(supplements.enumerated()), id: \.element.id) { idx, s in
                        supplementRow(s)
                            .opacity(appear ? 1 : 0)
                            .offset(y: appear ? 0 : 14)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8)
                                .delay(0.05 * Double(idx)), value: appear)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
            }

            // Pinned actions fill the bottom instead of a floating text link.
            VStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                        if allTaken {
                            dismiss()
                        } else {
                            for s in supplements where !isTaken(s) { store.confirmSupplement(s) }
                        }
                    }
                } label: {
                    Text(allTaken ? "Let's train" : "Mark all as taken")
                        .font(BrandFont.body(16, .bold)).foregroundColor(Brand.onVolt)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(Brand.volt).clipShape(RoundedRectangle(cornerRadius: 14))
                }
                if !allTaken {
                    Button { dismiss() } label: {
                        Text("Skip for now")
                            .font(BrandFont.body(13, .semibold)).foregroundColor(Brand.mute)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
        }
    }

    // MARK: All-set / empty state (defensive — no more 0/0 shell)
    private var allSetState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 24)
            ZStack {
                Circle().fill(Brand.volt).frame(width: 76, height: 76)
                Image(systemName: "checkmark")
                    .font(.system(size: 34, weight: .bold)).foregroundColor(Brand.onVolt)
            }
            .scaleEffect(appear ? 1 : 0.6)
            .animation(.spring(response: 0.5, dampingFraction: 0.55), value: appear)
            Text("You're all set").font(BrandFont.display(28)).foregroundColor(Brand.text)
            Text("No pre-workout supplements today. Go get after it.")
                .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer(minLength: 24)
            Button { dismiss() } label: {
                Text("Let's train")
                    .font(BrandFont.body(16, .bold)).foregroundColor(Brand.onVolt)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Brand.volt).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    // MARK: Row
    @ViewBuilder
    private func supplementRow(_ s: Supplement) -> some View {
        let taken = isTaken(s)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10)
                .fill(taken ? Brand.volt.opacity(0.12) : Brand.line.opacity(0.4))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "pills.fill")
                        .font(.system(size: 18))
                        .foregroundColor(taken ? Brand.voltText : Brand.mute)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(BrandFont.body(15, .semibold)).foregroundColor(Brand.text)
                Text(s.dose.display + (s.instructions.map { " · \($0)" } ?? ""))
                    .font(BrandFont.body(12)).foregroundColor(Brand.voltText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            if taken {
                Circle().fill(Brand.volt).frame(width: 30, height: 30)
                    .overlay(Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold)).foregroundColor(Brand.onVolt))
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                        store.confirmSupplement(s)
                    }
                } label: {
                    Text("Took it").font(BrandFont.body(12, .bold)).foregroundColor(Brand.onVolt)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Brand.volt).clipShape(Capsule())
                }
            }
        }
        .padding(14)
        .background(Brand.black)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(taken ? Brand.voltLine.opacity(0.4) : Brand.line, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !taken else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                store.confirmSupplement(s)
            }
        }
    }

    private func isTaken(_ s: Supplement) -> Bool {
        let cal = Calendar.current
        return store.supplementLogs.contains {
            $0.supplementId == s.id && $0.status == .taken && cal.isDateInToday($0.takenAt ?? .distantPast)
        }
    }
}
