import SwiftUI

// MARK: - Coach HQ on iPad: Library (Oct 8, 2026)
//
// Saved workouts, supplement templates and check-in forms, from the endpoints the app already
// uses. The exercise library and its editor stay in Coach HQ on the web for now.
// Synchronized folder: no target step needed.

struct PadLibraryView: View {
    @EnvironmentObject var store: AppStore
    @State private var workouts: [APILibraryWorkout] = []
    @State private var templates: [APISupplementTemplate] = []
    @State private var forms: [APICheckInForm] = []
    @State private var loaded = false
    @State private var tab = "Saved workouts"
    @State private var open: APILibraryWorkoutDetail?
    @State private var formsSheet = false
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PadPageTop(title: "Library", subtitle: "Saved workouts, supplement templates and check-in forms. Exercises and their editor are in Coach HQ on the web.") {
                    PadSeg(options: [(id: "Saved workouts", label: "Saved workouts"), (id: "Supplement templates", label: "Supplement templates"), (id: "Check-in forms", label: "Check-in forms")], selection: $tab)
                }
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundColor(Pad.mute)
                        TextField("Search", text: $query).font(PadFont.ui(15)).foregroundColor(Pad.text).autocorrectionDisabled()
                    }
                    .padInput()
                    .frame(maxWidth: 420)
                    PadPanel(padding: 0) {
                        if !loaded {
                            VStack(spacing: 0) { ForEach(0..<4, id: \.self) { _ in PadSkeleton(height: 52).padding(12) } }
                        } else {
                            switch tab {
                            case "Supplement templates": templateRows
                            case "Check-in forms": formRows
                            default: workoutRows
                            }
                        }
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
        .background(Pad.page.ignoresSafeArea())
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $open) { d in PadLibraryWorkoutSheet(detail: d) }
        .sheet(isPresented: $formsSheet, onDismiss: { Task { await load() } }) { CheckInFormsLibrary() }
    }

    private func load() async {
        async let w = try? await APIClient.shared.workoutLibrary()
        async let t = try? await APIClient.shared.supplementTemplates()
        async let f = try? await APIClient.shared.checkInForms()
        workouts = (await w) ?? workouts
        templates = (await t) ?? templates
        forms = (await f) ?? forms
        loaded = true
    }

    private func matches(_ s: String) -> Bool { query.trimmingCharacters(in: .whitespaces).isEmpty || s.localizedCaseInsensitiveContains(query) }

    private var workoutRows: some View {
        let list = workouts.filter { matches($0.title) || matches($0.summary) }
        return VStack(spacing: 0) {
            tableHeader(["Workout", "Exercises", "Sets", ""])
            if list.isEmpty { empty("No saved workouts yet. Save one from a client’s workout, or build them in Coach HQ on the web.") }
            ForEach(list) { w in
                Button {
                    Task { if let d = try? await APIClient.shared.libraryWorkout(id: w.id) { open = d } }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.title).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                            Text(w.summary).font(PadFont.ui(13)).foregroundColor(Pad.mute).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(w.exerciseCount)").font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 90, alignment: .trailing)
                        Text("\(w.setCount)").font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 60, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Pad.mute).frame(width: 40)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverEffect(.highlight)
                PadRule()
            }
        }
    }

    private var templateRows: some View {
        let list = templates.filter { matches($0.name) }
        return VStack(spacing: 0) {
            tableHeader(["Template", "Supplements", "", ""])
            if list.isEmpty { empty("No templates yet. Save a client’s protocol as one from their Supplements tab.") }
            ForEach(list) { t in
                HStack(spacing: 12) {
                    Text(t.name).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(t.itemCount)").font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 90, alignment: .trailing)
                    Color.clear.frame(width: 100, height: 1)
                }
                .padding(.horizontal, 14).frame(minHeight: 52)
                PadRule()
            }
            PadLab("Apply a template from a client’s Supplements tab.").padding(14)
        }
    }

    private var formRows: some View {
        let list = forms.filter { matches($0.name) }
        return VStack(spacing: 0) {
            tableHeader(["Form", "Questions", "Clients", ""])
            Button { formsSheet = true } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Default form").font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                        Text(CheckInSchema.custom == nil ? "The standard questions" : "Your questions").font(PadFont.ui(13)).foregroundColor(Pad.mute)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(CheckInSchema.questions.count)").font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 90, alignment: .trailing)
                    Text("everyone else").font(PadFont.ui(13)).foregroundColor(Pad.mute).frame(width: 100, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Pad.mute).frame(width: 40)
                }
                .padding(.horizontal, 14).frame(minHeight: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain).hoverEffect(.highlight)
            PadRule()
            ForEach(list) { f in
                Button { formsSheet = true } label: {
                    HStack(spacing: 12) {
                        Text(f.name).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(CheckInSchema.parse(f.json)?.count ?? 0)").font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 90, alignment: .trailing)
                        Text("\(f.clientCount)").font(PadFont.ui(14)).foregroundColor(Pad.text).frame(width: 100, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Pad.mute).frame(width: 40)
                    }
                    .padding(.horizontal, 14).frame(minHeight: 52).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverEffect(.highlight)
                PadRule()
            }
            HStack {
                Button { formsSheet = true } label: { Label("New form", systemImage: "plus") }.buttonStyle(PadButtonStyle(kind: .outline, small: true))
                Spacer()
            }
            .padding(14)
        }
    }

    private func tableHeader(_ cols: [String]) -> some View {
        HStack(spacing: 12) {
            PadLab(cols[0]).frame(maxWidth: .infinity, alignment: .leading)
            PadLab(cols[1]).frame(width: 90, alignment: .trailing)
            PadLab(cols[2]).frame(width: cols[2].isEmpty ? 60 : 100, alignment: .trailing)
            Color.clear.frame(width: 40, height: 1)
        }
        .padding(.horizontal, 14).frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(Pad.line2).frame(height: 1) }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(PadFont.ui(14)).foregroundColor(Pad.mute).padding(14)
    }
}

struct PadLibraryWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let detail: APILibraryWorkoutDetail
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(detail.title).font(PadFont.display(30)).foregroundColor(Pad.text)
                Spacer()
                PadIconButton(systemName: "xmark", label: "Close", small: true) { dismiss() }
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(detail.exercises, id: \.id) { ex in
                        let m = ex.toModel()
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name).font(PadFont.ui(15, .semibold)).foregroundColor(Pad.text)
                                Text(m.muscleGroup).font(PadFont.cond(13)).foregroundColor(Pad.mute)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(m.sets.map { SetTarget.text($0, in: m) }.joined(separator: " · ")).font(PadFont.ui(14)).foregroundColor(Pad.mute)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, 12)
                        PadRule()
                    }
                }
            }
            PadLab("Use it as a start in New workout (Start from a saved workout). Editing saved workouts lives in Coach HQ on the web.")
        }
        .padding(24)
        .background(Pad.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }
}

extension APILibraryWorkoutDetail: Identifiable {}
