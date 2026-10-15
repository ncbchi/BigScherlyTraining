import SwiftUI
import Combine

// MARK: - Coach HQ on iPad: Library ▸ Exercises (3.1.8, Oct 10, 2026)
//
// Every exercise: yours, the standard ones, and names clients only typed into workouts. Filter by
// tapping a muscle on the body map, by movement pattern or kit, by who's using it. Each row shows the
// last 30 days' use and how many clients have it. The exercise page: your video, cues and what to
// watch for, the ladder (easier → harder) and swaps, who's doing it (estimated max and a 12-week
// trend per client), where it's used, and its history. Edit, make a standard one yours, or add a
// typed name to the library (the server's exercise-library endpoints, as Coach HQ uses them).
// Synchronized folder: no target step needed.

struct PadLibraryExercises: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @Environment(\.padLibrary) private var actions

    private var filtered: [LibExercise] {
        let q = lib.exQuery.trimmingCharacters(in: .whitespaces)
        return lib.exercises.filter { x in
            switch lib.source {
            case "mine": if !x.isMine { return false }
            case "standard": if x.source != "standard" { return false }
            case "typed": if !x.isTyped { return false }
            default: break
            }
            if !lib.muscles.isEmpty && !lib.muscles.contains(x.muscleGroup) && lib.muscles.isDisjoint(with: x.secondaryList) { return false }
            if let p = lib.pattern, x.pattern != p { return false }
            if let e = lib.equipment, x.equipment != e { return false }
            if lib.inUseOnly && x.used30 == 0 && x.clients.isEmpty { return false }
            if lib.noCuesOnly && (x.hasCues || x.isTyped) { return false }
            if let t = lib.tag, !x.tags.contains(t) { return false }
            if !q.isEmpty && !PadLibraryKit.matches([x.name, x.muscleGroup, x.equipment, x.pattern, x.tags.joined(separator: " ")].joined(separator: " "), q) { return false }
            return true
        }
        .sorted { $0.used30 != $1.used30 ? $0.used30 > $1.used30 : $0.name < $1.name }
    }

    private var selected: LibExercise? {
        if let k = lib.exerciseKey, let x = lib.exercise(k) { return x }
        return filtered.first
    }

    private var patterns: [String] { counted(lib.exercises.map { $0.pattern }) }
    private var kit: [String] { Array(counted(lib.exercises.map { $0.equipment }).prefix(6)) }
    private func counted(_ xs: [String]) -> [String] {
        var d: [String: Int] = [:]
        for x in xs where !x.isEmpty { d[x, default: 0] += 1 }
        return d.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { $0.key }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                filters
                Rectangle().fill(Pad.line).frame(height: 1)
                HStack {
                    PadLab("\(filtered.count.plural("exercise")) · most used first", size: 12)
                    Spacer()
                    if hasFilters {
                        Button("Clear filters") { clear() }.font(PadFont.cond(12)).foregroundColor(Pad.voltText).buttonStyle(.plain)
                    }
                    PadLab("30 days · who", color: Pad.faint, size: 12)
                }
                .padding(.horizontal, 14).frame(height: 32)
                Rectangle().fill(Pad.line).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !lib.loaded {
                            ForEach(0..<6, id: \.self) { _ in PadSkeleton(height: 50).padding(12) }
                        } else if filtered.isEmpty {
                            PadEmptyLine(text: lib.exercises.isEmpty ? "Couldn't load the exercises. Pull down to try again." : "Nothing matches those filters.").padding(14)
                        } else {
                            ForEach(filtered) { x in row(x) }
                        }
                    }
                }
            }
            .frame(width: 530)
            Rectangle().fill(Pad.line).frame(width: 1)
            Group {
                if let x = selected { PadLibraryExercisePage(x: x).id(x.key) } else {
                    PadLibraryPick(icon: "dumbbell", title: "Pick an exercise", text: "Its cues, ladder and swaps, and who's doing it.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var hasFilters: Bool {
        !lib.muscles.isEmpty || lib.pattern != nil || lib.equipment != nil || lib.inUseOnly || lib.noCuesOnly || lib.tag != nil || lib.source != "all" || !lib.exQuery.isEmpty
    }
    private func clear() {
        lib.muscles = []; lib.pattern = nil; lib.equipment = nil; lib.inUseOnly = false; lib.noCuesOnly = false; lib.tag = nil; lib.source = "all"; lib.exQuery = ""
    }

    private var filters: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                PadLibraryBodyMap(selected: lib.muscles, onTap: toggleMuscle)
                PadLab(lib.muscles.isEmpty ? "Tap a muscle" : lib.muscles.sorted().joined(separator: ", "), size: 11)
                    .lineLimit(2).multilineTextAlignment(.center).frame(width: 140)
            }
            .padding(.vertical, 8).frame(width: 150)
            .background(RoundedRectangle(cornerRadius: 12).fill(Pad.well))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundColor(Pad.mute)
                    TextField("Find an exercise", text: $lib.exQuery).font(PadFont.ui(14)).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 10).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Pad.well))
                PadSeg(options: [(id: "all", label: "All"), (id: "mine", label: "Yours \(lib.mine.count)"), (id: "standard", label: "Standard"), (id: "typed", label: "Typed \(lib.typed.count)")], selection: $lib.source)
                PadLibraryFlow(spacing: 6) {
                    ForEach(patterns, id: \.self) { p in
                        PadLibraryChip(text: p, on: lib.pattern == p) { lib.pattern = lib.pattern == p ? nil : p }
                    }
                }
                PadLibraryFlow(spacing: 6) {
                    ForEach(kit, id: \.self) { e in
                        PadLibraryChip(text: e, on: lib.equipment == e) { lib.equipment = lib.equipment == e ? nil : e }
                    }
                    PadLibraryChip(text: "In use", on: lib.inUseOnly) { lib.inUseOnly.toggle() }
                    PadLibraryChip(text: "No cues", on: lib.noCuesOnly) { lib.noCuesOnly.toggle() }
                    if let t = lib.tag { PadLibraryChip(text: "#\(t) ✕", on: true) { lib.tag = nil } }
                }
            }
        }
        .padding(12)
    }

    private func toggleMuscle(_ m: String) {
        if lib.muscles.contains(m) { lib.muscles.remove(m) } else { lib.muscles.insert(m) }
    }

    private func row(_ x: LibExercise) -> some View {
        let on: Bool = selected?.key == x.key
        let who: String = x.clients.isEmpty ? "nobody yet" : x.clients.count.plural("client")
        return Button { lib.exerciseKey = x.key } label: {
            HStack(spacing: 12) {
                PadLibraryThumb(video: x.hasVideo)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(x.name).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).lineLimit(1)
                        if x.isMine { PadTag(text: "yours", kind: .volt) }
                        if x.isTyped { PadTag(text: "typed", kind: .warn) }
                    }
                    Text(x.isTyped ? "typed into workouts · not in your library" : x.detailLine).font(PadFont.cond(13)).foregroundColor(Pad.mute).lineLimit(1)
                }
                Spacer(minLength: 6)
                if x.spark.reduce(0, +) > 0 { PadLibrarySpark(values: x.spark) }
                Text(who).font(PadFont.cond(12)).foregroundColor(x.clients.isEmpty ? Pad.faint : Pad.mute).frame(width: 74, alignment: .trailing)
            }
            .padLibraryRow(on)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .draggable(PadLibraryItem.exercise(x.key).payload) { PadLibraryDragPreview(icon: "dumbbell", title: x.name, sub: "\(x.defaultSets) × \(x.defaultReps)") }
    }

    /// The builder's starting point for one exercise: its default sets × reps and rest.
    static func draft(_ x: LibExercise) -> DraftExercise {
        var d = DraftExercise()
        d.name = x.name
        d.muscle = x.muscleGroup
        d.rest = x.restSeconds > 0 ? min(max(x.restSeconds, 15), 600) : 90
        let reps: String = x.defaultReps > 0 ? "\(x.defaultReps)" : ""
        d.sets = (0..<max(1, min(x.defaultSets, 10))).map { _ in DraftSet(reps: reps) }
        return d
    }
}

// MARK: - The exercise page

struct PadLibraryExercisePage: View {
    let x: LibExercise
    @EnvironmentObject var store: AppStore
    @ObservedObject private var lib = PadLibraryStore.shared
    @Environment(\.padLibrary) private var actions
    @Environment(\.padGo) private var go
    @Environment(\.openURL) private var openURL

    private var d: LibExerciseDetail? { lib.details[x.key] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if x.isTyped { typedNote }
                HStack(alignment: .top, spacing: 14) {
                    video.frame(width: 300)
                    coaching.frame(maxWidth: .infinity, alignment: .leading)
                }
                facts
                ladder
                whoPane
                HStack(alignment: .top, spacing: 12) {
                    usedPane.frame(maxWidth: .infinity)
                    rxPane.frame(maxWidth: .infinity)
                }
                if let h = d?.history, !h.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        PadLab("HISTORY", color: Pad.faint, size: 11)
                        ForEach(Array(h.prefix(6).enumerated()), id: \.offset) { _, e in
                            PadLab("\(PadDay.short(e.at)) · \(e.text)", size: 12)
                        }
                    }
                }
            }
            .padding(18)
        }
        .task { await lib.detail(x) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(x.name).font(PadFont.display(32)).foregroundColor(Pad.text).lineLimit(1).minimumScaleFactor(0.6)
            if x.isMine { PadTag(text: "yours", kind: .volt) }
            if x.isTyped { PadTag(text: "typed", kind: .warn) }
            if x.source == "standard" { PadTag(text: "standard") }
            if let b = x.basedOn, x.isMine, b.caseInsensitiveCompare(x.name) == .orderedSame {
                PadLab("from the standard one", size: 13).lineLimit(1)
            }
            Spacer(minLength: 6)
            if x.isTyped {
                Button { actions.sheet(.exerciseEditor(x)) } label: { Label("Add to your library", systemImage: "plus") }
                    .buttonStyle(PadButtonStyle(kind: .primary, small: true))
            } else {
                Button { actions.sheet(.exerciseEditor(x)) } label: { Label(x.isMine ? "Edit" : "Make it yours", systemImage: "pencil") }
                    .buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
            PadLibraryGiveMenu(item: .exercise(x.key), label: "Add to a workout…")
        }
    }

    private var typedNote: some View {
        let match = lib.likelyMatch(x.name)
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Pad.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Typed into workouts \(x.totalTimes.plural("time")), but it isn't in your library.").font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                Text(match.map { "Looks like \($0.name). Add it to give it cues and a video, or use \($0.name) from now on." } ?? "Add it to give it cues, a video and defaults.")
                    .font(PadFont.ui(13)).foregroundColor(Pad.mute)
            }
            Spacer(minLength: 6)
            if let m = match {
                Button("Open \(m.name)") { lib.exerciseKey = m.key }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.orange.opacity(Pad.isLight ? 0.07 : 0.10)))
    }

    private var video: some View {
        Button {
            if let s = x.videoUrl, let u = URL(string: s.hasPrefix("http") ? s : "https://" + s) { openURL(u) }
            else { actions.sheet(.exerciseEditor(x)) }
        } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 12).fill(x.hasVideo ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x3B3C40), Color(hex: 0x141416)], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Pad.well))
                Image(systemName: x.hasVideo ? "play.fill" : "video.badge.plus").font(.system(size: 22, weight: .semibold))
                    .foregroundColor(x.hasVideo ? .white : Pad.mute)
                    .frame(width: 54, height: 54).background(Circle().fill(x.hasVideo ? Color.white.opacity(0.18) : Pad.raised))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(x.hasVideo ? "Your video · opens in the browser" : "No video yet · add one")
                    .font(PadFont.cond(12)).foregroundColor(x.hasVideo ? .white : Pad.mute).padding(12)
            }
            .frame(height: 170)
        }
        .buttonStyle(.plain)
    }

    private var coaching: some View {
        VStack(alignment: .leading, spacing: 4) {
            PadLab("CUES", color: Pad.faint, size: 11)
            if x.cueLines.isEmpty {
                PadLab("No cues yet. Clients see them on the exercise, in order.", size: 13)
            } else {
                ForEach(Array(x.cueLines.prefix(5).enumerated()), id: \.offset) { _, c in bullet(c, Pad.volt) }
            }
            let faults = d?.faultLines ?? []
            if !faults.isEmpty {
                PadLab("WATCH FOR · only you see these", color: Pad.faint, size: 11).padding(.top, 8)
                ForEach(Array(faults.prefix(4).enumerated()), id: \.offset) { _, f in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Pad.orange).frame(width: 6, height: 6).padding(.top, 7)
                        (Text(f.fault).foregroundColor(Pad.text) + Text(f.fix.isEmpty ? "" : " → " + f.fix).foregroundColor(Pad.mute))
                            .font(PadFont.ui(14)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func bullet(_ t: String, _ c: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(c).overlay(Circle().stroke(Color.black.opacity(Pad.isLight ? 0.25 : 0), lineWidth: 1)).frame(width: 6, height: 6).padding(.top, 7)
            Text(t).font(PadFont.ui(14)).foregroundColor(Pad.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var facts: some View {
        HStack(alignment: .center, spacing: 14) {
            PadLibraryBodyMap(primary: x.muscleGroup, secondary: Set(x.secondaryList), scale: 0.7)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    PadTag(text: x.muscleGroup.isEmpty ? "No muscle set" : x.muscleGroup, kind: .volt)
                    ForEach(x.secondaryList, id: \.self) { m in PadTag(text: m, kind: .blue) }
                }
                Text([x.pattern, x.mechanics, x.laterality, x.level, x.equipment].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(PadFont.ui(14)).foregroundColor(Pad.mute)
                Text("Default \(x.defaultSets) × \(x.defaultReps > 0 ? "\(x.defaultReps)" : "AMRAP") · rest \(PadLibraryKit.rest(x.restSeconds))" + (x.loadText.isEmpty ? "" : " · \(x.loadText)"))
                    .font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text)
                HStack(spacing: 6) { ForEach(x.tags, id: \.self) { t in PadTag(text: "#" + t, kind: .line) } }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                PadNumber(value: "\(d?.sessions30 ?? x.used30)", size: 30)
                PadLab("sessions, 30 days", size: 12)
                PadNumber(value: "\(x.totalTimes)", size: 22).padding(.top, 4)
                PadLab("times ever", size: 12)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Pad.well))
    }

    @ViewBuilder
    private var ladder: some View {
        let rungs: [LibExerciseDetail.Rung] = d?.ladder ?? []
        if rungs.count >= 2 || !(d?.swaps ?? []).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if rungs.count >= 2 {
                    PadLab("THE LADDER · easier ← → harder", color: Pad.faint, size: 11)
                    HStack(spacing: 4) {
                        ForEach(Array(rungs.enumerated()), id: \.offset) { i, r in
                            if i > 0 { Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundColor(Pad.faint) }
                            rung(r)
                        }
                    }
                }
                if let swaps = d?.swaps, !swaps.isEmpty {
                    HStack(spacing: 6) {
                        PadLab("Swaps:", size: 13)
                        ForEach(swaps.prefix(6), id: \.self) { s in
                            Button { if let m = lib.exercise(named: s) { lib.exerciseKey = m.key } } label: { PadTag(text: s) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func rung(_ r: LibExerciseDetail.Rung) -> some View {
        let n: Int = lib.exercise(named: r.name)?.clients.count ?? 0
        return Button { if !r.current, let m = lib.exercise(named: r.name) { lib.exerciseKey = m.key } } label: {
            VStack(spacing: 1) {
                Text(r.name).font(PadFont.ui(13, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(n == 0 ? (r.exists ? "nobody" : "not in library") : n.plural("client")).font(PadFont.cond(11)).opacity(0.75)
            }
            .foregroundColor(r.current ? (Pad.isLight ? .white : Pad.ink) : Pad.text)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(r.current ? Pad.text : Pad.well))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .draggable(PadLibraryItem.exercise(r.name.lowercased()).payload)
    }

    private var whoPane: some View {
        let rows: [LibExerciseDetail.Usage] = d?.clientUsage ?? []
        return PadPane(title: "Who's doing it", aside: "estimated max · last 12 weeks") {
            if d == nil {
                PadSkeleton(height: 80)
            } else if rows.isEmpty {
                PadEmptyLine(text: "Nobody's logged it yet.")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        hd("Client").frame(maxWidth: .infinity, alignment: .leading)
                        hd("Now").frame(width: 70, alignment: .trailing)
                        hd("12 wks").frame(width: 54, alignment: .trailing)
                        hd("Trend").frame(width: 104, alignment: .center)
                        hd("Best set").frame(width: 100, alignment: .trailing)
                    }
                    ForEach(rows) { u in usageRow(u) }
                }
            }
        }
    }

    private func hd(_ t: String) -> some View { Text(t).font(PadFont.cond(12)).foregroundColor(Pad.faint).padding(.bottom, 4) }

    private func usageRow(_ u: LibExerciseDetail.Usage) -> some View {
        let me: Bool = u.id == store.selfClientId
        let ch: Double = u.change ?? 0
        let chText: String = ch == 0 ? "0" : (ch > 0 ? "+" : "−") + StatsUnits.weightText(abs(ch), unit: false)
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                PadAvatar(name: me ? "You" : u.name, size: 26)
                Text(me ? "You" : u.name).font(PadFont.ui(14, .semibold)).foregroundColor(Pad.text).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(u.e1rm.map { StatsUnits.weightText($0) } ?? "—").font(PadFont.ui(14, .bold)).foregroundColor(Pad.text).frame(width: 70, alignment: .trailing)
            Text(chText).font(PadFont.ui(13, .semibold)).foregroundColor(ch > 0 ? Pad.voltText : (ch < 0 ? Pad.orange : Pad.mute)).frame(width: 54, alignment: .trailing)
            PadLibraryLine(values: u.trend, width: 92, height: 22).frame(width: 104)
            Text(u.bestSet ?? "").font(PadFont.cond(12)).foregroundColor(Pad.mute).frame(width: 100, alignment: .trailing).lineLimit(1)
        }
        .frame(minHeight: 38)
        .overlay(alignment: .top) { PadRule() }
        .contentShape(Rectangle())
        .onTapGesture { if !me { PadOpen.client(u.id, .stats, go: go) } }
    }

    private var usedPane: some View {
        let used: [LibExerciseDetail.UsedIn] = d?.usedIn ?? []
        return PadPane(title: "Used in", aside: x.totalTimes > 0 ? "\(x.totalTimes) times programmed" : nil) {
            if used.isEmpty {
                PadEmptyLine(text: d == nil ? "" : "Not in any program or saved workout.")
            } else {
                PadLibraryFlow(spacing: 6) {
                    ForEach(used, id: \.self) { u in
                        Button {
                            if u.kind == "program" { lib.programId = u.id; lib.open(.programs) } else { lib.workoutId = u.id; lib.open(.workouts) }
                        } label: {
                            Label(u.name, systemImage: u.kind == "program" ? "calendar" : "list.bullet")
                                .font(PadFont.ui(13, .semibold)).foregroundColor(Pad.text)
                                .padding(.horizontal, 10).frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Pad.well))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var rxPane: some View {
        let rx: [LibExerciseDetail.Prescription] = d?.prescriptions ?? []
        return PadPane(title: "By goal", aside: "what the builder suggests") {
            if rx.isEmpty {
                PadEmptyLine(text: d == nil ? "" : "Default \(x.defaultSets) × \(x.defaultReps) only.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rx.enumerated()), id: \.offset) { i, p in
                        if i > 0 { PadRule() }
                        HStack(spacing: 8) {
                            Text(p.goal).font(PadFont.ui(13, p.isDefault == true ? .bold : .semibold)).foregroundColor(Pad.text).frame(width: 90, alignment: .leading)
                            Text("\(p.sets) × \(p.reps)").font(PadFont.ui(13)).foregroundColor(Pad.text)
                            Text(p.load ?? "").font(PadFont.cond(12)).foregroundColor(Pad.mute).lineLimit(1)
                            Spacer(minLength: 4)
                            if let r = p.rest, r > 0 { PadLab(PadLibraryKit.rest(r), size: 12) }
                            if let t = p.tempo, !t.isEmpty { PadLab(t, color: Pad.faint, size: 12) }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }
}

// MARK: - Body map

/// A front and a back figure. Tap a muscle to filter (selected = accent); or show one exercise's
/// primary (accent) and secondary (blue) muscles.
struct PadLibraryBodyMap: View {
    var selected: Set<String> = []
    var primary: String? = nil
    var secondary: Set<String> = []
    var scale: CGFloat = 1
    var onTap: ((String) -> Void)? = nil

    private struct Part { let muscle: String; let x: CGFloat; let y: CGFloat; let w: CGFloat; let h: CGFloat }
    private static let front: [Part] = [
        Part(muscle: "Shoulders", x: 8, y: 23, w: 10, h: 10), Part(muscle: "Shoulders", x: 44, y: 23, w: 10, h: 10),
        Part(muscle: "Chest", x: 19, y: 24, w: 24, h: 17), Part(muscle: "Core", x: 20, y: 43, w: 22, h: 22),
        Part(muscle: "Biceps", x: 5, y: 35, w: 9, h: 14), Part(muscle: "Biceps", x: 48, y: 35, w: 9, h: 14),
        Part(muscle: "Forearms", x: 4, y: 51, w: 9, h: 14), Part(muscle: "Forearms", x: 49, y: 51, w: 9, h: 14),
        Part(muscle: "Quads", x: 18, y: 67, w: 12, h: 37), Part(muscle: "Quads", x: 32, y: 67, w: 12, h: 37),
        Part(muscle: "Calves", x: 19, y: 107, w: 10, h: 34), Part(muscle: "Calves", x: 33, y: 107, w: 10, h: 34),
    ]
    private static let back: [Part] = [
        Part(muscle: "Shoulders", x: 8, y: 23, w: 10, h: 10), Part(muscle: "Shoulders", x: 44, y: 23, w: 10, h: 10),
        Part(muscle: "Back", x: 17, y: 24, w: 28, h: 27), Part(muscle: "Triceps", x: 5, y: 35, w: 9, h: 14), Part(muscle: "Triceps", x: 48, y: 35, w: 9, h: 14),
        Part(muscle: "Forearms", x: 4, y: 51, w: 9, h: 14), Part(muscle: "Forearms", x: 49, y: 51, w: 9, h: 14),
        Part(muscle: "Glutes", x: 18, y: 53, w: 26, h: 15),
        Part(muscle: "Hamstrings", x: 18, y: 70, w: 12, h: 34), Part(muscle: "Hamstrings", x: 32, y: 70, w: 12, h: 34),
        Part(muscle: "Calves", x: 19, y: 107, w: 10, h: 34), Part(muscle: "Calves", x: 33, y: 107, w: 10, h: 34),
    ]

    var body: some View {
        HStack(spacing: 6 * scale) {
            figure(Self.front, label: "front")
            figure(Self.back, label: "back")
        }
    }

    private func color(_ m: String) -> Color {
        if selected.contains(m) || primary == m || (primary == "Full Body") { return Pad.volt }
        if secondary.contains(m) { return Pad.blue }
        return Pad.isLight ? Color(hex: 0xC9CAC5) : Pad.raised
    }

    private func figure(_ parts: [Part], label: String) -> some View {
        ZStack(alignment: .topLeading) {
            Circle().fill(Pad.isLight ? Color(hex: 0xC9CAC5) : Pad.raised).frame(width: 18 * scale, height: 18 * scale).position(x: 31 * scale, y: 12 * scale)
            ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                RoundedRectangle(cornerRadius: min(p.w, p.h) / 2.4 * scale)
                    .fill(color(p.muscle))
                    .overlay(RoundedRectangle(cornerRadius: min(p.w, p.h) / 2.4 * scale).stroke(Color.black.opacity(Pad.isLight && color(p.muscle) == Pad.volt ? 0.25 : 0), lineWidth: 1))
                    .frame(width: p.w * scale, height: p.h * scale)
                    .position(x: (p.x + p.w / 2) * scale, y: (p.y + p.h / 2) * scale)
                    .onTapGesture { onTap?(p.muscle) }
            }
        }
        .frame(width: 62 * scale, height: 146 * scale)
        .contentShape(Rectangle())
        .accessibilityLabel("Body map, \(label)")
    }
}

/// A thumbnail: a dark tile with play when there's a video, a well with a dumbbell when not.
struct PadLibraryThumb: View {
    let video: Bool
    var body: some View {
        ZStack {
            if video {
                RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [Color(hex: 0x6C6D70), Color(hex: 0x3B3C40)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Pad.well)
                Image(systemName: "dumbbell").font(.system(size: 15, weight: .semibold)).foregroundColor(Pad.faint)
            }
        }
        .frame(width: 58, height: 42)
    }
}

/// Filter chip, 30 tall.
struct PadLibraryChip: View {
    let text: String
    var on = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(PadFont.ui(13, .semibold)).lineLimit(1)
                .foregroundColor(on ? (Pad.isLight ? .white : Pad.ink) : Pad.text)
                .padding(.horizontal, 11).frame(height: 30)
                .background(Capsule().fill(on ? Pad.text : Color.clear))
                .overlay(Capsule().stroke(on ? Pad.text : Pad.line2, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

/// Wrapping row layout (chips).
struct PadLibraryFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Editor: edit yours, make a standard one yours, or add a typed name

struct PadLibraryExerciseEditor: View {
    let base: LibExercise?
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lib = PadLibraryStore.shared

    @State private var name = ""
    @State private var muscle = ""
    @State private var secondary: Set<String> = []
    @State private var equipment = ""
    @State private var pattern = ""
    @State private var level = ""
    @State private var sides = "Both together"
    @State private var cues = ""
    @State private var faults = ""
    @State private var video = ""
    @State private var sets = "3"
    @State private var reps = "8"
    @State private var rest = "90"
    @State private var load = ""
    @State private var ladder = ""
    @State private var swaps = ""
    @State private var tags = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var filled = false

    static let muscles = ["Chest", "Back", "Shoulders", "Quads", "Hamstrings", "Glutes", "Calves", "Biceps", "Triceps", "Forearms", "Core", "Full Body", "Cardio"]
    static let patterns = ["Squat", "Hinge", "Lunge", "Horizontal push", "Vertical push", "Horizontal pull", "Vertical pull", "Carry", "Core", "Isolation", "Power", "Conditioning"]
    static let levels = ["Beginner", "Intermediate", "Advanced"]

    private var mode: String {
        guard let b = base else { return "new" }
        return b.isMine ? "edit" : (b.isTyped ? "typed" : "adopt")
    }
    private var title: String {
        switch mode {
        case "edit": return "Edit \(base?.name ?? "")"
        case "adopt": return "Make \(base?.name ?? "") yours"
        case "typed": return "Add \(base?.name ?? "") to your library"
        default: return "New exercise"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if mode == "adopt" { PadLab("Starts from the standard \(base?.name ?? ""). Your changes, video and tags stay with it.", size: 13) }
                    section("Basics") {
                        field("Name") { TextField("e.g. Pause Squat", text: $name).padInput() }
                        field("Equipment") {
                            HStack(spacing: 8) {
                                TextField("Barbell, Dumbbell…", text: $equipment).padInput()
                                Menu {
                                    ForEach(["Barbell", "Dumbbell", "Bodyweight", "Machine", "Cable", "Kettlebell", "EZ Bar", "Trap Bar", "Smith Machine", "Band"], id: \.self) { e in Button(e) { equipment = e } }
                                } label: { PadMenuLabel(text: "Pick", icon: "chevron.down") }
                            }
                        }
                        field("Pattern") { PadLibraryFlow(spacing: 6) { ForEach(Self.patterns, id: \.self) { p in PadLibraryChip(text: p, on: pattern == p) { pattern = p } } } }
                        field("Level") { PadLibraryFlow(spacing: 6) { ForEach(Self.levels, id: \.self) { l in PadLibraryChip(text: l, on: level == l) { level = level == l ? "" : l } } } }
                        field("Sides") { PadSeg(options: [(id: "Both together", label: "Both together"), (id: "One side at a time", label: "One side at a time")], selection: $sides) }
                    }
                    section("Muscles · tap once for primary, again for secondary, again to clear") {
                        HStack(alignment: .center, spacing: 16) {
                            PadLibraryBodyMap(primary: muscle.isEmpty ? nil : muscle, secondary: secondary, onTap: tapMuscle)
                            PadLibraryFlow(spacing: 6) {
                                ForEach(Self.muscles, id: \.self) { m in
                                    PadLibraryChip(text: m + (muscle == m ? " · primary" : (secondary.contains(m) ? " · secondary" : "")), on: muscle == m || secondary.contains(m)) { tapMuscle(m) }
                                }
                            }
                        }
                    }
                    section("Coaching") {
                        field("Cues · one per line, clients see them in order") { TextEditor(text: $cues).frame(minHeight: 96).scrollContentBackground(.hidden).padInput(multiline: true) }
                        field("Common faults · only you see these (fault → fix, one per line)") { TextEditor(text: $faults).frame(minHeight: 80).scrollContentBackground(.hidden).padInput(multiline: true) }
                        field("Video link") { TextField("youtube.com/watch?v=…", text: $video).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).padInput() }
                    }
                    section("Defaults · what the builder fills in") {
                        HStack(spacing: 10) {
                            field("Sets") { TextField("3", text: $sets).keyboardType(.numberPad).padInput() }
                            field("Reps (0 = AMRAP)") { TextField("8", text: $reps).keyboardType(.numberPad).padInput() }
                            field("Rest (seconds)") { TextField("90", text: $rest).keyboardType(.numberPad).padInput() }
                            field("Load") { TextField("RPE 8, 75%…", text: $load).padInput() }
                        }
                    }
                    section("Related · names, comma-separated; blank uses the standard ones") {
                        field("Ladder (easier → harder, include this one)") { TextField("Goblet Squat, Box Squat, Back Squat, Pause Squat", text: $ladder).padInput() }
                        field("Swaps") { TextField("Safety Bar Squat, Hack Squat", text: $swaps).padInput() }
                        field("Tags") { TextField("main lift, meet prep", text: $tags).textInputAutocapitalization(.never).padInput() }
                    }
                    if let error { PadLab(error, color: Pad.orange, size: 13) }
                    if mode == "edit" {
                        Button("Delete from your library", role: .destructive) { confirmDelete = true }
                            .font(PadFont.ui(15, .semibold)).foregroundColor(Pad.red)
                    }
                }
                .padding(24)
            }
            .background(Pad.surface.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : (mode == "edit" ? "Save" : "Save to library")) { save() }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete \(base?.name ?? "") from your library?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Workouts that already have it keep it. A standard exercise of the same name comes back.") }
        }
        .tint(Pad.isLight ? Pad.text : Pad.volt)
        .task { await fill() }
    }

    private func section<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t).font(PadFont.ui(16, .bold)).foregroundColor(Pad.text)
            c()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Pad.page))
    }

    private func field<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { PadLab(t, size: 12); c() }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tapMuscle(_ m: String) {
        if muscle == m { muscle = ""; secondary.insert(m) }
        else if secondary.contains(m) { secondary.remove(m) }
        else { if !muscle.isEmpty { secondary.insert(muscle) }; muscle = m; secondary.remove(m) }
    }

    private func fill() async {
        guard !filled else { return }
        filled = true
        guard let x = base else { return }
        name = x.name; muscle = x.muscleGroup; secondary = Set(x.secondaryList); equipment = x.equipment
        pattern = x.pattern; level = x.level; sides = x.laterality.isEmpty ? "Both together" : x.laterality
        cues = x.cueLines.joined(separator: "\n"); video = x.videoUrl ?? ""
        sets = "\(x.defaultSets)"; reps = "\(x.defaultReps)"; rest = "\(x.restSeconds)"; load = x.loadText
        tags = x.tags.joined(separator: ", ")
        await lib.detail(x)
        if let d = lib.details[x.key] {
            faults = d.faults ?? ""
            if x.isMine {
                ladder = d.ladder.map { $0.name }.joined(separator: ", ")
                swaps = d.swaps.joined(separator: ", ")
            }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { error = "Give the exercise a name."; return }
        var body: [String: Any] = [
            "name": n, "muscleGroup": muscle, "secondaryMuscles": secondary.sorted().joined(separator: ", "),
            "equipment": equipment.trimmingCharacters(in: .whitespaces), "pattern": pattern,
            "mechanics": (pattern == "Isolation" || pattern == "Conditioning") ? "Isolation" : "Compound",
            "laterality": sides, "level": level,
            "cues": cues.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n"),
            "faults": faults, "videoUrl": video.trimmingCharacters(in: .whitespaces),
            "defaultSets": max(1, Int(sets) ?? 3), "defaultReps": max(0, Int(reps) ?? 8), "restSeconds": max(0, Int(rest) ?? 90),
            "loadText": load, "tags": tags.lowercased(), "progressions": ladder, "swaps": swaps,
        ]
        if mode == "adopt", let b = base { body["basedOn"] = b.name }
        saving = true
        error = nil
        Task {
            do {
                try await APIClient.shared.saveLibraryExercise(id: mode == "edit" ? base?.serverId : nil, body: body)
                await lib.reloadExercises()
                lib.exerciseKey = n.lowercased()
                PadToasts.shared.show(mode == "edit" ? "Saved" : "Added to your library")
                dismiss()
            } catch {
                self.error = "Couldn't save. " + ((error as? LocalizedError)?.errorDescription ?? "Check your connection and try again.")
            }
            saving = false
        }
    }

    private func delete() {
        guard let id = base?.serverId else { return }
        Task {
            do {
                try await APIClient.shared.deleteLibraryExercise(id: id)
                await lib.reloadExercises()
                PadToasts.shared.show("Deleted")
                dismiss()
            } catch { self.error = "Couldn't delete it. Try again." }
        }
    }
}
