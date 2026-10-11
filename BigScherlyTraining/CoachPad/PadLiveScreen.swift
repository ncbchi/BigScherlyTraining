import SwiftUI

// MARK: - Coach HQ on iPad: Live · the screen (Oct 10, 2026)
//
// Top bar: every client you follow, as the phone's pinned set bar (tap to switch; orange when one
// needs you). One: their card on the left (status bar, four windows, set card, exercises), your
// column on the right (Next set, Notes for next time, Watch for). Side by side: two clients, a
// column each (semi-private). Mockups: iPad canvas row 3.1.6. Synchronized folder: no target step.

struct PadLiveView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var link = PadLiveLink.shared
    @ObservedObject private var data = PadData.shared
    @AppStorage("bst_pad_live_metrics") private var metricsRaw = "speed,heart,tempo,notes"
    @AppStorage("bst_pad_live_side") private var sideRaw = "speed,heart"
    @AppStorage("bst_pad_live_mode") private var modeRaw = "one"

    private var sideBySide: Bool { modeRaw == "side" && link.following.count >= 2 }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Brand.line).frame(height: 1)
            content
        }
        .background(Brand.bg.ignoresSafeArea())
        .overlay { PadToastHost() }
        .onAppear { link.start() }
    }

    @ViewBuilder private var content: some View {
        let f: [PadLivePhone] = link.following
        if f.isEmpty {
            waiting
        } else if sideBySide {
            side(f)
        } else if let p = link.current {
            one(p)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { link.close() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundColor(Brand.text)
                    .frame(width: 44, height: 44).background(Circle().fill(Brand.text.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Live")
            HStack(spacing: 7) {
                Circle().fill(Brand.danger).frame(width: 8, height: 8)
                    .background(Circle().fill(Brand.danger.opacity(0.2)).frame(width: 16, height: 16))
                Text("LIVE").font(BrandFont.body(13, .heavy)).tracking(1.6).foregroundColor(Brand.text)
                if link.demoRunning {
                    Text("DEMO").font(BrandFont.body(9, .heavy)).tracking(1).foregroundColor(Color(hex: 0xF2A03D))
                        .padding(.horizontal, 6).frame(height: 18).overlay(Capsule().stroke(Color(hex: 0xF2A03D), lineWidth: 1))
                }
            }
            if link.following.count >= 2 {
                HStack(spacing: 3) {
                    modeButton("One", "one")
                    modeButton("Side by side", "side")
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 12).fill(Brand.text.opacity(0.06)))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(link.following) { p in pinned(p) }
                }
                .padding(.vertical, 12).padding(.horizontal, 2)
            }
            if !link.nearby.isEmpty {
                Menu {
                    ForEach(link.nearby) { p in Button("Follow \(p.name)") { link.follow(p.id) } }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        Text("\(link.nearby.count) nearby").font(BrandFont.body(13, .heavy))
                        Text("· Follow").font(BrandFont.body(13, .semibold)).foregroundColor(Brand.mute)
                    }
                    .foregroundColor(Brand.text)
                    .padding(.horizontal, 14).frame(height: 44)
                    .overlay(Capsule().stroke(Brand.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                }
            }
        }
        .padding(.horizontal, 18).frame(height: 84)
    }

    private func modeButton(_ t: String, _ raw: String) -> some View {
        let on: Bool = (raw == "side") == sideBySide
        return Button { withAnimation(.easeOut(duration: 0.2)) { modeRaw = raw } } label: {
            Text(t).font(BrandFont.body(12, .heavy))
                .foregroundColor(on ? Brand.onVolt : Brand.text)
                .padding(.horizontal, 12).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(on ? Brand.volt : Color.clear))
        }
        .buttonStyle(.plain)
    }

    /// A followed client, as their phone's pinned set bar. Tap to switch to them.
    private func pinned(_ p: PadLivePhone) -> some View {
        let on: Bool = link.current?.id == p.id
        let needs: String? = needsYou(p)
        let stroke: Color = needs != nil ? Color(hex: 0xF2A03D) : (on ? Brand.voltLine : Brand.line)
        let label: String = p.name.firstName.uppercased() + (needs.map { " · " + $0 } ?? "")
        return Button { link.selected = p.id } label: {
            Group {
                if p.allowed, let ctx = PadLiveCtx.make(p) {
                    PadLiveSetCard(ctx: ctx, compact: true) { _ in }
                        .allowsHitTesting(false)
                } else {
                    HStack(spacing: 10) {
                        PadAvatar(name: p.name, size: 30)
                        Text(p.link != .connected ? "Reconnecting…" : (p.allowed ? "Connected" : "Waiting for Allow"))
                            .font(BrandFont.body(13, .heavy)).foregroundColor(Brand.mute)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 44)
                }
            }
            .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 8)
            .frame(width: 300)
            .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(stroke, lineWidth: on || needs != nil ? 1.5 : 1))
            .overlay(alignment: .topLeading) {
                Text(label).font(BrandFont.body(9, .heavy)).tracking(1.2)
                    .foregroundColor(needs != nil ? Color(hex: 0xF2A03D) : (on ? Brand.voltText : Brand.mute))
                    .padding(.horizontal, 6).background(Brand.bg)
                    .offset(x: 12, y: -7)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { link.unfollow(p.id) } label: { Label("Stop following", systemImage: "xmark.circle") }
        }
    }

    /// Orange in the top bar: a set waiting to be logged, or "Start set" sitting there 20 s after rest.
    private func needsYou(_ p: PadLivePhone) -> String? {
        guard let c = p.state?.card else { return nil }
        if c.logNeeded { return "LOG SET" }
        if c.stage == .ready, let since = p.readySince, Date().timeIntervalSince(since) > 20 { return "REST'S UP" }
        return nil
    }

    // MARK: One client

    @ViewBuilder private func one(_ p: PadLivePhone) -> some View {
        if !p.allowed {
            TimelineView(.periodic(from: .now, by: 2)) { _ in asking(p) }
        } else if let ctx = PadLiveCtx.make(p) {
            GeometryReader { g in
                let wide: Bool = g.size.width >= 1000
                let rightW: CGFloat = 440
                let leftW: CGFloat = wide ? g.size.width - rightW - 16 - 40 : g.size.width - 40
                // The windows share what's left once the title, set card and exercises are placed.
                let fixed: CGFloat = 394          // title 40 + set card 124 + exercises 112 + gaps and padding
                let windows: CGFloat = max(400, g.size.height - fixed)
                let topH: CGFloat = (windows * 0.58).rounded()
                ScrollView {
                    if wide {
                        HStack(alignment: .top, spacing: 16) {
                            left(ctx, topH: topH, botH: windows - topH).frame(width: leftW)
                            right(ctx).frame(width: rightW).id(p.id)
                        }
                        .padding(20)
                    } else {
                        VStack(spacing: 16) {
                            left(ctx, topH: topH, botH: windows - topH)
                            right(ctx).id(p.id)
                        }
                        .padding(20)
                    }
                }
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Connected. Waiting for the first update from \(p.name.firstName)'s phone…").font(BrandFont.body(15)).foregroundColor(Brand.mute)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func left(_ ctx: PadLiveCtx, topH: CGFloat, botH: CGFloat) -> some View {
        let metrics: [PadLiveMetric] = PadLiveMetric.list(metricsRaw, count: 4)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ctx.workout?.title ?? "Workout").font(BrandFont.display(32)).foregroundColor(Brand.text).lineLimit(1)
                Text("\(ctx.phone.name) · what \(ctx.firstName) sees, with your layer on it").font(BrandFont.body(12)).foregroundColor(Brand.mute).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 40)
            if ctx.phone.ended || ctx.card.stage == .done { doneBanner(ctx) }
            VStack(spacing: 0) {
                PadLiveStatusBar(ctx: ctx)
                Rectangle().fill(Brand.line).frame(height: 1)
                HStack(spacing: 0) {
                    window(ctx, metrics, 0)
                    Rectangle().fill(Brand.line).frame(width: 1)
                    window(ctx, metrics, 1)
                }
                .frame(height: topH)
                Rectangle().fill(Brand.line).frame(height: 1)
                HStack(spacing: 0) {
                    window(ctx, metrics, 2)
                    Rectangle().fill(Brand.line).frame(width: 1)
                    window(ctx, metrics, 3)
                }
                .frame(height: botH)
            }
            .padLiveCard()
            PadLiveSetCard(ctx: ctx) { cmd in link.command(cmd, to: ctx.phone.id) }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .padLiveCard()
            PadLiveExerciseStrip(ctx: ctx)
            if ctx.phone.link != .connected {
                Label("Link dropped — reconnecting when they're back in range.", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(BrandFont.body(13, .semibold)).foregroundColor(Color(hex: 0xF2A03D))
            }
        }
    }

    private func window(_ ctx: PadLiveCtx, _ metrics: [PadLiveMetric], _ i: Int) -> some View {
        let others: Set<PadLiveMetric> = Set(metrics.enumerated().filter { $0.offset != i }.map { $0.element })
        let options: [PadLiveMetric] = PadLiveMetric.allCases.filter { !others.contains($0) }
        return PadLiveWindow(ctx: ctx, metric: metrics[i], options: options) { m in
            var all = metrics
            if let j = all.firstIndex(of: m), j != i { all.swapAt(i, j) } else { all[i] = m }
            metricsRaw = all.map { $0.rawValue }.joined(separator: ",")
        }
    }

    private func right(_ ctx: PadLiveCtx) -> some View {
        VStack(spacing: 12) {
            PadLiveNextSetCard(ctx: ctx)
            PadLiveNotesCard(ctx: ctx)
            PadLiveWatchFor(ctx: ctx)
        }
    }

    private func doneBanner(_ ctx: PadLiveCtx) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "flag.checkered").font(.system(size: 18, weight: .bold)).foregroundColor(Brand.onVolt)
                .frame(width: 40, height: 40).background(Circle().fill(Brand.volt))
            VStack(alignment: .leading, spacing: 2) {
                Text(ctx.phone.ended ? "Session closed on \(ctx.firstName)'s phone" : "Every set's logged")
                    .font(BrandFont.body(15, .heavy)).foregroundColor(Brand.text)
                Text(ctx.phone.notes.isEmpty ? "Anything for next time? Leave it in Notes for next time."
                     : "\(ctx.phone.notes.count) note\(ctx.phone.notes.count == 1 ? "" : "s") waiting for \(ctx.firstName)'s next workout.")
                    .font(BrandFont.body(12)).foregroundColor(Brand.mute)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .padLiveCard(16, highlight: Brand.voltLine)
    }

    // MARK: Side by side

    private func side(_ f: [PadLivePhone]) -> some View {
        let cur: PadLivePhone = link.current ?? f[0]
        let other: PadLivePhone = f.first { $0.id != cur.id } ?? f[1]
        let pair: [PadLivePhone] = [cur, other]
        let metrics: [PadLiveMetric] = PadLiveMetric.list(sideRaw, count: 2)
        return ScrollView {
            HStack(alignment: .top, spacing: 20) {
                ForEach(Array(pair.enumerated()), id: \.element.id) { i, p in
                    column(p, metric: metrics[min(i, metrics.count - 1)], slot: i)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder private func column(_ p: PadLivePhone, metric: PadLiveMetric, slot: Int) -> some View {
        if p.allowed, let ctx = PadLiveCtx.make(p) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(ctx.firstName).font(BrandFont.display(28)).foregroundColor(Brand.text)
                    Text("\(ctx.workout?.title ?? "") · \(ctx.card.setsDone)/\(ctx.card.setsTotal) sets").font(BrandFont.body(12)).foregroundColor(Brand.mute)
                    Spacer(minLength: 0)
                }
                VStack(spacing: 0) {
                    PadLiveStatusBar(ctx: ctx)
                    Rectangle().fill(Brand.line).frame(height: 1)
                    PadLiveWindow(ctx: ctx, metric: metric, options: PadLiveMetric.allCases) { m in
                        var all: [PadLiveMetric] = PadLiveMetric.list(sideRaw, count: 2)
                        all[min(slot, all.count - 1)] = m
                        sideRaw = all.map { $0.rawValue }.joined(separator: ",")
                    }
                    .frame(height: 290)
                }
                .padLiveCard()
                PadLiveSetCard(ctx: ctx) { cmd in link.command(cmd, to: ctx.phone.id) }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .padLiveCard()
                PadLiveExerciseStrip(ctx: ctx, only: true)
                PadLiveNextSetCard(ctx: ctx, compact: true).id("next-\(p.id)")
                PadLiveNotesCard(ctx: ctx, compact: true).id("notes-\(p.id)")
            }
            .frame(maxWidth: .infinity)
        } else {
            asking(p).frame(maxWidth: .infinity, minHeight: 400)
        }
    }

    // MARK: Before anything streams

    private var waiting: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Follow a session").font(BrandFont.display(40)).foregroundColor(Brand.text)
                Text("Your client opens today's workout on their phone. It shows up here — tap Follow, they tap Allow, and their own workout card streams to this screen with your layer on it. Bluetooth, phone to iPad: no Wi-Fi needed.")
                    .font(BrandFont.body(15)).foregroundColor(Brand.mute).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if link.radioOK { ProgressView().controlSize(.small) } else { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Color(hex: 0xF2A03D)) }
                    Text(link.radio).font(BrandFont.body(14, .semibold)).foregroundColor(link.radioOK ? Brand.mute : Color(hex: 0xF2A03D))
                }
                if link.nearby.isEmpty {
                    Text("No phones nearby yet. Check the client's workout is open and their phone's Bluetooth is on.")
                        .font(BrandFont.body(14)).foregroundColor(Brand.mute)
                    Button { PadLiveDemo.shared.start() } label: {
                        Label("See it with demo data", systemImage: "play.rectangle")
                            .font(BrandFont.body(15, .heavy)).foregroundColor(Brand.onVolt)
                            .padding(.horizontal, 18).frame(height: 46)
                            .background(Capsule().fill(Brand.volt))
                    }
                    .buttonStyle(.plain)
                    Text("Two made-up clients mid-session. The set card and Next set work; nothing is saved or sent.")
                        .font(BrandFont.body(13)).foregroundColor(Brand.mute)
                } else {
                    VStack(spacing: 10) {
                        ForEach(link.nearby) { p in
                            HStack(spacing: 12) {
                                PadAvatar(name: p.name, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(BrandFont.body(16, .heavy)).foregroundColor(Brand.text)
                                    Text(p.hello?.workoutId == nil ? "No workout open" : "Workout open").font(BrandFont.body(13)).foregroundColor(Brand.mute)
                                }
                                Spacer(minLength: 0)
                                PadLivePill(text: "Follow", filled: true) { link.follow(p.id) }
                            }
                            .padding(12)
                            .padLiveCard(16)
                        }
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    private func asking(_ p: PadLivePhone) -> some View {
        let first: String = p.name.firstName
        let justAsked: Bool = p.requestedAt.map { Date().timeIntervalSince($0) < 8 } ?? false
        let line: String
        if p.link != .connected { line = "Reconnecting to \(first)'s phone…" }
        else if p.asking { line = "Waiting for \(first) to tap Allow on their phone." }
        else if justAsked { line = "Asking \(first)'s phone…" }
        else { line = "\(first) didn't allow it this time." }
        return VStack(spacing: 16) {
            PadAvatar(name: p.name, size: 64)
            Text(line).font(BrandFont.body(18, .heavy)).foregroundColor(Brand.text).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if p.link == .connected && !p.asking && !justAsked {
                    PadLivePill(text: "Ask again", filled: true) { link.askAgain(p.id) }
                }
                PadLivePill(text: "Stop following") { link.unfollow(p.id) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
