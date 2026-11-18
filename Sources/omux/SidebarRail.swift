import SwiftUI
import UniformTypeIdentifiers

// The rail layout of the sidebar: every project is a mark on a narrow strip, and the list
// beside it shows the sessions of the one picked. However many projects there are, each is one
// click away and the list stays short.

/// The strip of project marks, with the app's own buttons at its foot.
struct ProjectRail: View {
    @EnvironmentObject var store: Store
    let shownID: UUID?
    let theme: Theme
    /// Open while the pointer rests on the strip: every project by name, over the list. The
    /// sidebar holds it, so the list underneath can stop taking clicks meanwhile.
    @Binding var open: Bool
    /// The workspace on show, whose mark is lit; nil for a project on its own.
    var shownWorkspace: String? = nil
    let pick: (TabGroup) -> Void
    var pickWorkspace: (String) -> Void = { _ in }
    @State private var hover = 0
    /// The idle projects are listed under their stack instead of folded into it.
    @State private var idleListed = false
    /// The workspace mark a dragged project is over, lit to say it takes the project.
    @State private var dropTarget: String?

    static let width: CGFloat = 46
    static let openWidth: CGFloat = 196

    /// Pinned and active projects, in the sidebar's own order.
    private var active: [TabGroup] {
        let working = store.groups.filter { $0.workspace == nil && store.isActive($0) }
        return working.filter(\.pinned) + working.filter { !$0.pinned }
    }

    /// Projects with nothing going on, most recently used first. Two or more fold into one tile,
    /// as they fold into one row in the list layout.
    private var idle: [TabGroup] {
        store.groups.filter { $0.workspace == nil && !store.isActive($0) }.sorted { store.lastActivity($0) > store.lastActivity($1) }
    }

    /// One mark on the rail: a project on its own, or a workspace and all its projects.
    enum Entry: Identifiable {
        case project(TabGroup)
        case workspace(String, [TabGroup])

        var id: String {
            switch self {
            case .project(let group): return group.id.uuidString
            case .workspace(let name, _): return "workspace:" + name
            }
        }
    }

    @ViewBuilder private func mark(_ entry: Entry, quiet: Bool = false) -> some View {
        switch entry {
        case .project(let group):
            ProjectMark(group: group, shown: shownWorkspace == nil && group.id == shownID, named: open, quiet: quiet) { pick(group) }
                .contextMenu { GroupMenu(group: group) }
                // Dragged onto a workspace's mark, the project goes into that workspace.
                .onDrag { SidebarDrag.begin(.project(group.id)) }
                // A session dropped here moves into this project.
                .modifier(DropLift(key: entry.id, hue: ProjectMark.hue(group.name), target: $dropTarget, accepts: .sessions, spring: { pick(group) }) { item in
                    guard case .session(let id) = item else { return }
                    store.moveTab(id, toGroup: group.id)
                })
        case .workspace(let name, let projects):
            // Drawn as a project holding every session of the workspace, so its dot tells the
            // most pressing state among all of them.
            ProjectMark(group: TabGroup(name: name, tabs: projects.flatMap(\.tabs)), shown: shownWorkspace == name, named: open, quiet: quiet,
                        detail: projects.count == 1 ? "Workspace · 1 project" : "Workspace · \(projects.count) projects", stack: max(projects.count, 1), button: true) {
                pickWorkspace(name)
            }
            .contextMenu { WorkspaceMenu(name: name) }
            // A project dropped here joins the workspace; a session goes with its project.
            .modifier(DropLift(key: entry.id, hue: ProjectMark.hue(name), target: $dropTarget, accepts: .both, spring: { pickWorkspace(name) },
                               refuses: { store.isInWorkspace($0, name) }) { item in
                store.drop(item, onWorkspace: name)
            })
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 7) {
                    // Workspaces first, always in their own order: they don't move with activity.
                    ForEach(store.workspaceNames.map { Entry.workspace($0, store.projects(inWorkspace: $0)) }) { mark($0) }
                    if !store.workspaceNames.isEmpty, !store.groups.filter({ $0.workspace == nil }).isEmpty {
                        Rectangle().fill(.primary.opacity(0.1)).frame(width: 18, height: 1).padding(.leading, 6).padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Then the projects on their own, as before: the ones at work, then the idle ones.
                    ForEach(active.map(Entry.project)) { mark($0) }
                    let idleEntries = idle.map(Entry.project)
                    let idle = idle
                    // The project on show stays in view, so a stack holding it lists itself.
                    let listed = idle.count < 2 || idleListed || idle.contains { $0.id == shownID }
                    if idle.count >= 2 {
                        Button { idleListed.toggle() } label: {
                            HStack(spacing: 9) {
                                Text("+\(idle.count)")
                                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, height: 30)
                                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                if open {
                                    Text("Idle projects").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 7.5, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                        .rotationEffect(.degrees(listed ? 90 : 0))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(idle.map(\.name).joined(separator: ", "))
                    }
                    if listed {
                        ForEach(idleEntries) { mark($0, quiet: true) }
                    }
                    Button {
                        // A workspace is only a name: no folder to pick, and nothing to fill in
                        // first. It is made at once and named in place, in the list beside.
                        open = false
                        pickWorkspace(store.newWorkspace())
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 30, height: 30)
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            if open { Text("New workspace").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1); Spacer(minLength: 0) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New workspace — or drop a project here to start one with it")
                    // A project dropped on the + starts a new workspace with it.
                    .modifier(DropLift(key: "new-workspace", hue: .secondary, target: $dropTarget, accepts: .projects) { item in
                        guard case .project(let id) = item else { return }
                        pickWorkspace(store.newWorkspace(with: id))
                    })
                    .contextMenu {
                        Button("New Workspace") { pickWorkspace(store.newWorkspace()) }
                        Divider()
                        Button("New Project") { store.newGroup() }
                        Button("New Remote Project…") { store.showRemoteProject = true }
                        Button("Open Folder as Project…") { store.openFolderPanel() }
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The limits ride on the rail, so they show whether or not the session list does.
            UsageView(onRail: true, railOpen: open)
                .padding(.leading, 8)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                VStack(spacing: 2) {
                    Button { store.showRecentSessions = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .help("Open recent conversation (⇧⌘O)")
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("Settings (⌘,)")
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
        }
        // Clear of the window's close, minimise and zoom buttons.
        .padding(.top, 34)
        .padding(.bottom, 8)
        .frame(width: open ? Self.openWidth : Self.width, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.18))
        .background(Color(nsColor: theme.chrome))
        .overlay(alignment: .trailing) { Hairline(vertical: true) }
        .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 14, x: 8)
        .contentShape(Rectangle())
        // A click on the strip's own empty space stays here and doesn't reach the list under it.
        .onTapGesture {}
        .onHover { over in
            // A good second's rest opens it: a click on a tile is the quick way, and the names
            // are for when you stop to look.
            hover += 1
            let turn = hover
            if over {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if hover == turn { withAnimation(.easeOut(duration: 0.16)) { open = true } }
                }
            } else {
                withAnimation(.easeOut(duration: 0.14)) { open = false }
            }
        }
    }
}

/// One project on the rail: a dark tile with a faint sheen, its initials in a colour that is
/// the project's own, and a dot on the corner for the most pressing state among its sessions
/// (waiting, failed, working). The one on show fills softly with its colour and has a bar at
/// the strip's edge.
struct ProjectMark: View {
    @EnvironmentObject var store: Store
    let group: TabGroup
    let shown: Bool
    /// The rail is open: the name and what its sessions are doing go beside the mark.
    var named = false
    /// An idle project, listed under the stack: fainter than the ones with work in them.
    var quiet = false
    /// What the open rail says under the name instead of what the sessions are doing, e.g. a
    /// workspace's number of projects.
    var detail: String? = nil
    /// A workspace's number of projects: the mark is drawn as a stack of that many cards, which
    /// fan out under the pointer and while the workspace is on show. 0 for a project.
    var stack = 0
    /// Clicked as a Button rather than through a tap gesture: for a mark that is never dragged
    /// (a workspace's), where a Button's click is the dependable one.
    var button = false
    let action: () -> Void
    @State private var hovering = false
    /// Set once the mark is on screen, so a workspace's cards slide out from behind it.
    @State private var appeared = false

    var body: some View {
        let states = group.tabs.map { store.runtime[$0.id] ?? TabRuntime() }
        let waiting = states.filter { $0.statusState == .blocked || $0.needsAttention }.count
        let failed = states.filter { $0.statusState == .error }.count
        let working = states.filter { $0.statusState == .working }.count
        let (live, stopped) = store.liveCounts(group.tabs)
        let state: Color? = waiting > 0 ? Palette.needs : failed > 0 ? Palette.error : working > 0 ? Palette.working : nil
        let hue = Self.hue(group.name)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        // Not a Button for a project: on macOS a button keeps a drag from starting, and project
        // marks are dragged. A workspace's mark isn't, and is one.
        let face = HStack(spacing: 9) {
            VStack(spacing: 2.5) {
                Text(Self.initials(group.name))
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(hue)
                // One pip a session: filled green while it runs, an empty ring while stopped.
                if live + stopped > 0 { SessionPips(live: live, stopped: stopped, max: 4, size: 3.5) }
            }
                .frame(width: 30, height: 30)
                .background {
                    if shown {
                        shape.fill(hue.opacity(0.22))
                    } else {
                        shape.fill(LinearGradient(colors: [.white.opacity(hovering ? 0.14 : 0.09), .white.opacity(hovering ? 0.06 : 0.03)], startPoint: .top, endPoint: .bottom))
                    }
                }
                .overlay(shape.strokeBorder(shown ? hue.opacity(0.55) : Color.white.opacity(0.09), lineWidth: 1))
                .overlay(alignment: .leading) {
                    // The strip's own edge, eight points to the tile's left.
                    if shown {
                        UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3, style: .continuous)
                            .fill(.primary.opacity(0.9))
                            .frame(width: 3, height: 20)
                            .offset(x: -8)
                    }
                }
                .background { if stack > 0 { cards(shape: shape, hue: hue) } }
                .overlay(alignment: .topTrailing) {
                    if let state {
                        StatusDot(color: state, pulsing: waiting == 0 && failed == 0, size: 8)
                            .padding(2)
                            .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                            .offset(x: 4, y: -4)
                    }
                }
                .opacity(quiet && !shown && !hovering ? 0.55 : 1)
                // A soft glow under the pointer; the mark itself stays where it is.
                .shadow(color: hue.opacity(hovering ? 0.35 : 0), radius: hovering ? 6 : 0)
            if named {
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    let doing = Self.doing(live: live, stopped: stopped, waiting: waiting, failed: failed, working: working)
                    Text(detail.map { $0 + " · " + doing } ?? doing)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
          }
          .contentShape(Rectangle())
        Group {
            if button {
                Button(action: action) { face }.buttonStyle(.plain)
            } else {
                face.onTapGesture(perform: action).accessibilityAddTraits(.isButton)
            }
        }
        .onHover { over in withAnimation(.spring(response: 0.28, dampingFraction: 0.62)) { hovering = over } }
        .animation(.spring(response: 0.32, dampingFraction: 0.64), value: shown)
        .onAppear {
            guard stack > 0, !appeared else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.6).delay(0.05)) { appeared = true }
        }
        // Open, the strip says all this itself.
        .help(named ? "" : Self.summary(group.name, live: live, stopped: stopped, waiting: waiting, failed: failed, working: working))
    }

    /// The cards behind a workspace's mark, one per project up to two, in the workspace's
    /// colour: squared up at rest, fanned out to the upper right under the pointer or on show.
    /// Under the mark's own translucent face sits an opaque one, so the cards only peek out.
    @ViewBuilder private func cards(shape: RoundedRectangle, hue: Color) -> some View {
        let fan: CGFloat = !appeared ? 0 : shown ? 1.5 : 1
        ZStack {
            ForEach((0..<min(stack, 2)).reversed(), id: \.self) { depth in
                let step = CGFloat(depth + 1)
                shape.fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(shape.fill(hue.opacity(0.10 + 0.06 * (2 - step))))
                    .overlay(shape.strokeBorder(hue.opacity(0.30 + 0.15 * (2 - step)), lineWidth: 1))
                    .rotationEffect(.degrees(Double(fan * step * 3)), anchor: .bottomLeading)
                    .offset(x: fan * step * 2.5, y: -fan * step * 2.5)
            }
            shape.fill(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// Six colours a project can have. Which one comes from its name, so it is the same on
    /// every launch and on every Mac.
    private static let hues: [Color] = [
        Color(red: 0.48, green: 0.65, blue: 1.00), Color(red: 0.79, green: 0.55, blue: 0.98), Color(red: 0.37, green: 0.83, blue: 0.60),
        Color(red: 0.96, green: 0.71, blue: 0.38), Color(red: 0.96, green: 0.54, blue: 0.63), Color(red: 0.37, green: 0.82, blue: 0.85),
    ]

    static func hue(_ name: String) -> Color {
        // Not hashValue: that changes with every launch.
        let sum = name.lowercased().unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return hues[Int(sum % UInt32(hues.count))]
    }

    /// "acme-web" → "AW", "infra" → "IN", "My Project" → "MP". A name that is already an
    /// abbreviation in capitals stays whole up to three characters: "ITB", not "IT".
    static func initials(_ name: String) -> String {
        if (2...3).contains(name.count), name.allSatisfy({ $0.isUppercase || $0.isNumber }) { return name }
        let words = name.split { !$0.isLetter && !$0.isNumber }.filter { !$0.isEmpty }
        let letters = words.count >= 2 ? words.prefix(2).compactMap(\.first).map(String.init).joined() : String(name.filter { $0.isLetter || $0.isNumber }.prefix(2))
        return letters.isEmpty ? "·" : letters.uppercased()
    }

    /// "1 waiting · 1 failed", or how many sessions run and are stopped when nothing is going on.
    static func doing(live: Int, stopped: Int, waiting: Int, failed: Int, working: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if failed > 0 { parts.append("\(failed) failed") }
        if working > 0 { parts.append("\(working) working") }
        return parts.isEmpty ? SessionPips.text(live: live, stopped: stopped) : parts.joined(separator: " · ")
    }

    static func summary(_ name: String, live: Int, stopped: Int, waiting: Int, failed: Int, working: Int) -> String {
        var parts = [SessionPips.text(live: live, stopped: stopped)]
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        if failed > 0 { parts.append("\(failed) stopped with an error") }
        if working > 0 { parts.append("\(working) working") }
        return name + " · " + parts.joined(separator: ", ")
    }
}

/// The name of the project the list shows, with where it is, above its sessions.
struct RailProjectTitle: View {
    @EnvironmentObject var store: Store
    let group: TabGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if store.renamingID == group.id {
                    RenameField(initial: group.name) { store.rename(group.id, to: $0) }
                } else {
                    Text(group.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                if group.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary).help("Pinned to the top")
                }
                if let host = group.host, group.isRemote { MachineBadge(host: host) }
            }
            if let directory = group.directory, !directory.isEmpty {
                Text(directory.tildeAbbreviated)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .contextMenu { GroupMenu(group: group) }
    }
}

/// The heading of the list beside the rail when it shows a workspace: its name and how many
/// projects it holds. The projects follow, each under its own header with its folder.
struct RailWorkspaceTitle: View {
    @EnvironmentObject var store: Store
    let name: String

    var body: some View {
        let projects = store.projects(inWorkspace: name)
        let hue = ProjectMark.hue(name)
        let (live, stopped) = store.liveCounts(projects.flatMap(\.tabs))
        HStack(spacing: 10) {
            Text(ProjectMark.initials(name))
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(hue)
                .frame(width: 32, height: 32)
                .background(hue.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(hue.opacity(0.45), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                if store.renamingWorkspace == name {
                    WorkspaceNameField(name: name)
                } else {
                    Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        .onTapGesture(count: 2) { store.renamingWorkspace = name }
                        .help("Double-click to rename")
                }
                // One line of text: the project count used to sit beside pips and a session
                // count and was the part cut short ("2 proje…").
                Text(([projects.count == 1 ? "1 project" : "\(projects.count) projects"]
                      + (live + stopped > 0 ? [SessionPips.text(live: live, stopped: stopped)] : [])).joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .id(name)
        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: name)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.07)).frame(height: 1).padding(.horizontal, 14) }
        .contentShape(Rectangle())
        .contextMenu { WorkspaceMenu(name: name) }
        // A project dropped on the heading joins the workspace; a session goes with its project.
        .modifier(DropLift(key: "title:" + name, hue: hue, target: $dropTarget, accepts: .both, lift: 1.02,
                           refuses: { store.isInWorkspace($0, name) }) { item in
            store.drop(item, onWorkspace: name)
        })
    }

    @State private var dropTarget: String?
}

/// The workspace's name, typed in place where it shows. Return or a click elsewhere keeps it,
/// Escape keeps the name it had.
struct WorkspaceNameField: View {
    @EnvironmentObject var store: Store
    let name: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Workspace name", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(ProjectMark.hue(name).opacity(0.6), lineWidth: 1))
            .padding(.leading, -5)
            .focused($focused)
            .onAppear {
                draft = name
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit { finish(save: true) }
            .onExitCommand { finish(save: false) }
            .onChange(of: focused) { _, now in if !now { finish(save: true) } }
            // Another workspace shown before Return: keep what was typed, and don't leave the
            // field waiting to reappear the next time this one is shown.
            .onDisappear { finish(save: true) }
    }

    private func finish(save: Bool) {
        guard store.renamingWorkspace == name else { return }
        store.renamingWorkspace = nil
        if save { store.renameWorkspace(name, to: draft) }
    }
}

/// What a workspace with no project yet shows under its name: the projects there are, to bring
/// in with a click, and a way to make a new one. All in the list, nothing over the app.
/// Shown at the end of a workspace's list. Empty, the workspace lists the projects there are to
/// bring in at once. With projects, the same list folds behind one "Add project" row, so a
/// workspace can always grow from where it is shown, not only from a context menu.
/// It lives inside the list's scroll view and nothing in it takes a fixed height: a column's
/// minimum height is measured at a narrow width, and wrapped text held at its full height there
/// made the sidebar taller than the window and pushed the whole window's content out of view.
struct WorkspaceSetup: View {
    @EnvironmentObject var store: Store
    let name: String
    let empty: Bool
    @State private var expanded = false

    var body: some View {
        // Projects on their own first: they are the likely ones to bring in.
        let others = store.groups.filter { $0.workspace == nil } + store.groups.filter { $0.workspace != nil && $0.workspace != name }
        VStack(alignment: .leading, spacing: 2) {
            // Nothing to read through first: the actions the workspace has, as quiet rows.
            if empty {
                SetupButton(title: "New session", systemImage: "plus.bubble") { store.newSession(inWorkspace: name) }
            }
            if !others.isEmpty {
                SetupButton(title: "Add project", systemImage: expanded ? "chevron.down" : "plus") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded.toggle() }
                }
                if expanded {
                    VStack(spacing: 1) {
                        ForEach(others) { group in AddProjectRow(group: group, workspace: name) }
                    }
                    .padding(.leading, 8)
                }
            }
            SetupButton(title: "Open folder as project…", systemImage: "folder.badge.plus") {
                store.newGroup(inWorkspace: name)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: name) { _, _ in expanded = false }
    }
}

/// A quiet full-width action in a workspace's list.
private struct SetupButton: View {
    let title: String
    let systemImage: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 20, height: 20)
            Text(title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint.map { AnyShapeStyle($0.opacity(hovering ? 1 : 0.75)) } ?? AnyShapeStyle(hovering ? .primary : .secondary))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
    }
}

/// A project offered to a workspace: its mark, its name and where it is now; a click brings it in.
private struct AddProjectRow: View {
    @EnvironmentObject var store: Store
    let group: TabGroup
    let workspace: String
    @State private var hovering = false

    var body: some View {
        let hue = ProjectMark.hue(group.name)
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.setWorkspace(group.id, workspace) }
        } label: { row(hue) }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Move \(group.name) into \(workspace)")
    }

    private func row(_ hue: Color) -> some View {
        HStack(spacing: 8) {
            Text(ProjectMark.initials(group.name))
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(hue)
                .frame(width: 20, height: 20)
                .background(hue.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(group.name).font(.system(size: 12)).lineLimit(1)
                Text(group.workspace.map { "in " + $0 } ?? "on its own").font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(hovering ? AnyShapeStyle(hue) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
    }
}

/// A session's state at a glance, one pip each: filled green while it runs, an empty ring while
/// it is stopped. Past `max` the last place says how many more there are.
struct SessionPips: View {
    let live: Int
    let stopped: Int
    var max = 5
    var size: CGFloat = 5

    static func text(live: Int, stopped: Int) -> String {
        if live + stopped == 0 { return "No sessions" }
        return [live > 0 ? "\(live) running" : nil, stopped > 0 ? "\(stopped) stopped" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        let total = live + stopped
        let shown = total > max ? max - 1 : total
        HStack(spacing: size * 0.6) {
            ForEach(0..<shown, id: \.self) { index in
                if index < live {
                    Circle().fill(Palette.done).frame(width: size, height: size)
                } else {
                    Circle().strokeBorder(Color.secondary.opacity(0.8), lineWidth: Swift.max(0.9, size * 0.24)).frame(width: size, height: size)
                }
            }
            if total > max {
                Text("+\(total - shown)")
                    .font(.system(size: size * 1.9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .help(Self.text(live: live, stopped: stopped))
    }
}

/// "● 2 active" or "○ 1 stopped", for headings and project headers.
struct LiveCountLabel: View {
    let count: Int
    let live: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(live ? Palette.done : Color.clear)
                .overlay(Circle().strokeBorder(live ? Color.clear : Color.secondary.opacity(0.7), lineWidth: 1.2))
                .frame(width: 6, height: 6)
            Text("\(count) \(live ? "active" : "stopped")")
                .monospacedDigit()
                .foregroundStyle(live && count > 0 ? AnyShapeStyle(.primary.opacity(0.85)) : AnyShapeStyle(.secondary))
        }
        .opacity(count == 0 ? 0.55 : 1)
    }
}

struct WorkspaceMenu: View {
    @EnvironmentObject var store: Store
    let name: String

    var body: some View {
        Button("New Session in \(name)") { store.newSession(inWorkspace: name) }
        Button("Open Folder as Project in \(name)…") { store.newGroup(inWorkspace: name) }
        let others = store.groups.filter { $0.workspace != name }
        if !others.isEmpty {
            Menu("Add Project") {
                ForEach(others) { group in Button(group.name) { store.setWorkspace(group.id, name) } }
            }
        }
        Divider()
        Button("Rename Workspace") {
            RailState.shared.showWorkspace(name, in: store)
            store.renamingWorkspace = name
        }
        if store.projects(inWorkspace: name).isEmpty {
            Button("Delete Workspace", role: .destructive) { store.ungroupWorkspace(name) }
        } else {
            Button("Ungroup Workspace") { store.ungroupWorkspace(name) }
        }
    }
}

/// What the rail shows and whether it is open. Shared, because the rail has two homes: beside
/// the session list in the sidebar, and on its own at the window's edge when the list is closed.
@MainActor
final class RailState: ObservableObject {
    static let shared = RailState()
    /// The project the list shows. It follows the selected session, and a click on the strip
    /// moves it, also to a project with no sessions to select.
    @Published var shownGroupID: UUID?
    /// The workspace on show: the one picked on the rail, also one with no project yet, or the
    /// one of the project the selection is in.
    @Published var shownWorkspace: String?
    /// Open under the pointer, lying over what is beside it.
    @Published var open = false

    private static let lastKey = "railLastSession"
    /// Per project, the session that was on show when the project was last left: kept across
    /// launches, so coming back to a project comes back to where you were in it.
    private var last: [String: String] = UserDefaults.standard.dictionary(forKey: RailState.lastKey) as? [String: String] ?? [:]

    /// The selection moved: its project is the one on show, and it is that project's last session.
    func noteSelection(in store: Store) {
        guard let tab = store.selectedTabID, let group = store.selectedGroup else { return }
        shownGroupID = group.id
        shownWorkspace = group.workspace
        guard last[group.id.uuidString] != tab.uuidString else { return }
        last[group.id.uuidString] = tab.uuidString
        UserDefaults.standard.set(last, forKey: Self.lastKey)
    }

    /// A project picked on the rail: its window, on the session last on show there. Without
    /// one to go back to, the session that waits for you, else the one last worked in.
    func show(_ group: TabGroup, in store: Store) {
        shownGroupID = group.id
        shownWorkspace = group.workspace
        guard store.selectedGroup?.id != group.id else { return }
        let remembered = last[group.id.uuidString].flatMap { id in group.tabs.first { $0.id.uuidString == id } }
        let pick = remembered
            ?? group.tabs.first { store.runtime[$0.id]?.statusState == .blocked }
            ?? group.tabs.max { (store.runtime[$0.id]?.lastActivity ?? .distantPast) < (store.runtime[$1.id]?.lastActivity ?? .distantPast) }
        if let pick { store.selectedTabID = pick.id }
    }

    /// A workspace picked on the rail: its list, on the project of it last worked in.
    func showWorkspace(_ name: String, in store: Store) {
        let projects = store.projects(inWorkspace: name)
        if let latest = projects.max(by: { store.lastActivity($0) < store.lastActivity($1) }) { show(latest, in: store) }
        shownWorkspace = name
    }
}

/// The rail by itself, for when the session list is closed: the strip stays at the window's
/// edge, and a click on a project brings the list back with that project in it.
struct StandaloneRail: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var state = RailState.shared
    let theme: Theme
    let reveal: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            if state.open {
                // Whatever misses the strip lands here, not on the session behind it.
                Color.black.opacity(0.001).onTapGesture { state.open = false }
            }
            ProjectRail(shownID: state.shownGroupID ?? store.selectedGroup?.id, theme: theme, open: $state.open,
                        shownWorkspace: state.shownWorkspace ?? store.selectedGroup?.workspace) { group in
                state.show(group, in: store)
                state.open = false
                // A project with no sessions has nothing to put in the tabs: its list opens.
                if group.tabs.isEmpty { reveal() }
            } pickWorkspace: { name in
                state.showWorkspace(name, in: store)
                state.open = false
                reveal()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// A project carried by drag and drop, as text with a prefix so a session's id (dragged onto
/// a pane) is never taken for it.
enum ProjectDrag {
    static let prefix = "omux-project:"

    static func provider(_ id: UUID) -> NSItemProvider {
        NSItemProvider(object: (prefix + id.uuidString) as NSString)
    }

    /// What a drop on the rail carries: a project, or a session dragged from the list.
    enum Item: Equatable { case project(UUID), session(UUID) }

    /// Calls `take` on the main thread with what was dropped; false when it is neither.
    static func receive(_ providers: [NSItemProvider], take: @escaping @MainActor (Item) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            let item: Item
            if text.hasPrefix(prefix), let id = UUID(uuidString: String(text.dropFirst(prefix.count))) {
                item = .project(id)
            } else if let id = UUID(uuidString: text) {
                item = .session(id)
            } else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { take(item) } }
        }
        return true
    }
}

/// A rail mark that takes drops: it grows and glows in its colour while something is over it.
struct DropLift: ViewModifier {
    enum Accepts { case sessions, projects, both }
    let key: String
    let hue: Color
    @Binding var target: String?
    let accepts: Accepts
    var lift: CGFloat = 1.14
    /// Held over the mark a moment while dragging, it opens what the mark stands for, so the
    /// drop can be made at an exact place in its list.
    var spring: (@MainActor () -> Void)? = nil
    /// Something it would take, but where it already is: a session over its own workspace.
    /// The mark stays dark rather than lighting up for a drop that would do nothing.
    var refuses: (@MainActor (ProjectDrag.Item) -> Bool)? = nil
    let take: @MainActor (ProjectDrag.Item) -> Void

    func body(content: Content) -> some View {
        content
            .scaleEffect(target == key ? lift : 1)
            .shadow(color: hue.opacity(target == key ? 0.6 : 0), radius: 8)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: target)
            .onDrop(of: [UTType.plainText], delegate: RailDropDelegate(key: key, target: $target, accepts: accepts, spring: spring, refuses: refuses, take: take))
    }
}

/// Proposes a move, not the default copy: a row dragged out of the session list allows only a
/// move, and a copy proposal is turned down without a word.
private struct RailDropDelegate: DropDelegate {
    let key: String
    @Binding var target: String?
    let accepts: DropLift.Accepts
    let spring: (@MainActor () -> Void)?
    let refuses: (@MainActor (ProjectDrag.Item) -> Bool)?
    let take: @MainActor (ProjectDrag.Item) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.plainText]), !info.hasItemsConforming(to: [.fileURL]) else { return false }
        if let item = SidebarDrag.shared.item, let refuses, MainActor.assumeIsolated({ refuses(item) }) { return false }
        // What the sidebar is dragging is known before the drop: a mark lights only for what it takes.
        switch SidebarDrag.shared.item {
        case .project: return accepts != .sessions
        case .session: return accepts != .projects
        case nil: return true
        }
    }
    func dropEntered(info: DropInfo) {
        target = key
        guard let spring else { return }
        let key = key, target = $target
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            MainActor.assumeIsolated {
                guard target.wrappedValue == key else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { spring() }
            }
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { if target == key { target = nil } }

    func performDrop(info: DropInfo) -> Bool {
        if target == key { target = nil }
        let accepts = accepts
        return ProjectDrag.receive(info.itemProviders(for: [.plainText])) { item in
            if case .project = item, accepts == .sessions { return }
            if case .session = item, accepts == .projects { return }
            SidebarDrag.shared.item = nil
            take(item)
        }
    }
}

/// A workspace's heading in the list layout: what the rail's mark and title are there. A click
/// folds it; a double click renames it; its menu and drops work as on the rail.
struct ListWorkspaceHeader: View {
    @EnvironmentObject var store: Store
    let name: String
    let folded: Bool
    let toggle: () -> Void
    @State private var hovering = false
    @State private var dropTarget: String?

    var body: some View {
        let projects = store.projects(inWorkspace: name)
        let hue = ProjectMark.hue(name)
        let (live, stopped) = store.liveCounts(projects.flatMap(\.tabs))
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(folded ? 0 : 90))
                .frame(width: 10)
            Text(ProjectMark.initials(name))
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(hue)
                .frame(width: 20, height: 20)
                .background(hue.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            if store.renamingWorkspace == name {
                WorkspaceNameField(name: name)
            } else {
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(projects.isEmpty ? "empty" : SessionPips.text(live: live, stopped: stopped))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering, store.renamingWorkspace != name {
                Button { store.newSession(inWorkspace: name) } label: { Image(systemName: "plus") }
                    .buttonStyle(IconButtonStyle(size: 18))
                    .foregroundStyle(.secondary)
                    .help("New session in \(name)")
            }
        }
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.renamingWorkspace = name }
        .onTapGesture(perform: toggle)
        .contextMenu { WorkspaceMenu(name: name) }
        .help(folded ? "Show \(name)'s projects" : "Fold \(name)")
        .modifier(DropLift(key: "list:" + name, hue: hue, target: $dropTarget, accepts: .both, lift: 1.02,
                           refuses: { store.isInWorkspace($0, name) }) { item in
            store.drop(item, onWorkspace: name)
        })
    }
}
