import SwiftUI
import UniformTypeIdentifiers

/// One row of the flat sidebar list: a project header, a session, or a stack of idle shells.
enum SidebarRow: Identifiable, Hashable {
    case group(TabGroup)
    case tab(TabItem, groupID: UUID)
    /// A shell listed under its stack, indented with a guide line.
    case nested(TabItem, groupID: UUID)
    /// Idle shells of a project folded into one row; `expanded` lists them below it.
    case shells(groupID: UUID, tabs: [TabItem], expanded: Bool)
    /// Projects with nothing running folded into one row at the bottom.
    case projects(groups: [TabGroup], expanded: Bool)
    /// A workspace's heading in the list layout, its projects below it.
    case workspace(String)
    /// Over the projects on their own, when workspaces come before them.
    case looseHeading

    var id: UUID {
        switch self {
        case .looseHeading:
            return UUID(uuidString: "00000000-0000-0000-0000-00000001005e")!
        case .workspace(let name):
            // From the name, the same on every redraw (not hashValue, which changes per launch).
            var a: UInt64 = 0xcbf29ce484222325, b: UInt64 = 0x84222325cbf29ce4
            for byte in ("workspace:" + name).utf8 { a = (a ^ UInt64(byte)) &* 0x100000001b3; b = (b &+ UInt64(byte)) &* 0x9e3779b97f4a7c15 }
            return withUnsafeBytes(of: (a, b)) { UUID(uuid: $0.load(as: uuid_t.self)) }
        case .group(let g): return g.id
        case .tab(let t, _), .nested(let t, _): return t.id
        case .shells(let g, _, _):
            // Derived from the project's id, so it never collides with a session's.
            var bytes = g.uuid
            bytes.15 ^= 0xFF
            return UUID(uuid: bytes)
        case .projects:
            return UUID(uuidString: "00000000-0000-0000-0000-00000000bead")!
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: Store
    let theme: Theme
    /// Projects whose idle shells are listed instead of stacked.
    @State private var expandedShells: Set<UUID> = []
    /// Idle projects listed instead of stacked.
    @State private var expandedProjects = false
    /// Workspaces folded to their heading in the list layout.
    @State private var foldedWorkspaces: Set<String> = []
    /// "rail": projects on a narrow strip of initials, with one project's sessions listed beside
    /// it. "list": every project and its sessions in one list.
    @AppStorage(Prefs.sidebarLayout) private var layout = "rail"
    /// Which project the list shows and whether the strip is open; shared with the strip's
    /// other home, at the window's edge when this list is closed.
    @ObservedObject private var railState = RailState.shared
    /// What is being dragged in the sidebar and where it would land, for the marks that say so.
    @ObservedObject private var drag = SidebarDrag.shared

    private var rail: Bool { layout == "rail" }
    private var shownGroup: TabGroup? {
        store.groups.first { $0.id == railState.shownGroupID } ?? store.selectedGroup ?? store.groups.first
    }

    /// The workspace the list shows: the one of the project on show.
    private var shownWorkspace: String? { rail ? (railState.shownWorkspace ?? shownGroup?.workspace) : nil }

    /// The shown project's rows with its header first, so the end of the list knows its last project; the list leaves the header out.
    /// For a workspace, every project of it, each with its header.
    private var railRows: [SidebarRow] {
        if let name = shownWorkspace { return store.projects(inWorkspace: name).flatMap(groupRows) }
        guard var group = shownGroup else { return [] }
        group.isCollapsed = false
        return groupRows(group)
    }

    /// Pinned projects first, then the active projects in the order they were activated, latest first (a
    /// project moves to the top when an agent starts in it or returns after an hour, and stays put
    /// while it is prompted; drags and Move Up/Down hold), then the idle ones; two or more idle projects fold into one row at the bottom. Within a project, two or more idle shells fold into one
    /// row, so agents stay in view. The flat list lets native drag reorder and move sessions.
    private var rows: [SidebarRow] {
        // Workspaces first, in their rail order, each a heading over its projects; the projects
        // on their own follow as before.
        var rows: [SidebarRow] = []
        for name in store.workspaceNames {
            rows.append(.workspace(name))
            if !foldedWorkspaces.contains(name) { rows += store.projects(inWorkspace: name).flatMap(groupRows) }
        }
        let loose = store.groups.filter { $0.workspace == nil }
        if !rows.isEmpty, !loose.isEmpty { rows.append(.looseHeading) }
        // Pinned projects first, in their order; then the rest of the active ones in theirs.
        let working = loose.filter { store.isActive($0) }
        let active = working.filter(\.pinned) + working.filter { !$0.pinned }
        // Idle projects most recently used first, so the one you'll come back to is on top.
        let idle = loose.filter { !store.isActive($0) }.sorted { store.lastActivity($0) > store.lastActivity($1) }
        rows += active.flatMap(groupRows)
        if idle.count >= 2 {
            // Clicking never reorders: a selected session inside the stack opens the stack instead.
            let holdsSelection = idle.contains { group in group.tabs.contains { $0.id == store.selectedTabID } }
            let expanded = expandedProjects || holdsSelection
            rows.append(.projects(groups: idle, expanded: expanded))
            if expanded { rows += idle.flatMap(groupRows) }
        } else {
            rows += idle.flatMap(groupRows)
        }
        return rows
    }

    private func groupRows(_ group: TabGroup) -> [SidebarRow] {
        return { () -> [SidebarRow] in
            guard !group.isCollapsed else { return [.group(group)] }
            // Most recently used first, so the shell you'll want is at the top of the stack.
            let idle = group.tabs.filter { isIdleShell($0) }
                .sorted { (store.runtime[$0.id]?.lastActivity ?? .distantPast) > (store.runtime[$1.id]?.lastActivity ?? .distantPast) }
            guard idle.count >= 2 else { return [.group(group)] + group.tabs.map { .tab($0, groupID: group.id) } }
            let expanded = expandedShells.contains(group.id) || idle.contains { $0.id == store.selectedTabID }
            var rows: [SidebarRow] = [.group(group)]
            var stacked = false
            for tab in group.tabs {
                if idle.contains(tab) {
                    if !stacked {
                        rows.append(.shells(groupID: group.id, tabs: idle, expanded: expanded))
                        if expanded { rows += idle.map { .nested($0, groupID: group.id) } }
                        stacked = true
                    }
                } else {
                    rows.append(.tab(tab, groupID: group.id))
                }
            }
            return rows
        }()
    }

    /// A plain shell with nothing running in it. Selecting one keeps its stack open rather
    /// than pulling it out, so the list doesn't shuffle under the click.
    private func isIdleShell(_ tab: TabItem) -> Bool {
        guard store.provider(of: tab) == .shell else { return false }
        let rt = store.runtime[tab.id]
        return rt == nil || rt!.exited || !rt!.busy
    }

    var body: some View {
        // In the rail layout the list is one project's rows without its header; otherwise all of them.
        let all = rail ? railRows : rows
        let skipped = rail && shownWorkspace == nil ? min(1, all.count) : 0
        let shown = Array(all.dropFirst(skipped))
        // The strip keeps its place; opened under the pointer, it lies over the list.
        return HStack(spacing: 0) {
            if rail { Color.clear.frame(width: ProjectRail.width) }
            listColumn(all: all, skipped: skipped, shown: shown)
                // Under the open strip the list takes nothing: not a click, not a hover.
                .allowsHitTesting(!(rail && railState.open))
                .environment(\.hoverBlocked, rail && railState.open)
        }
        .overlay(alignment: .leading) {
            if rail {
                ZStack(alignment: .leading) {
                    if railState.open {
                        // Whatever misses the strip lands here, not on a row behind it.
                        Color.black.opacity(0.001).onTapGesture { railState.open = false }
                    }
                    // A click goes to the project, on the session last on show in it.
                    ProjectRail(shownID: shownGroup?.id, theme: theme, open: $railState.open, shownWorkspace: shownWorkspace) { group in
                        railState.show(group, in: store)
                    } pickWorkspace: { name in railState.showWorkspace(name, in: store) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .onChange(of: store.selectedTabID) { _, _ in
            // The list follows the selection to its project, wherever it was made.
            railState.noteSelection(in: store)
        }
        .background(Color(nsColor: theme.chrome))
        .contextMenu {
            // Empty-space menu; rows and project headers override it with their own.
            Button("New Project") { store.newGroup() }
            Button("New Remote Project…") { store.showRemoteProject = true }
            Button("Open Folder as Project…") { store.openFolderPanel() }
            Button("Open Recent Conversation…") { store.showRecentSessions = true }
            Button("New Codex Session") { store.newTab(command: "codex") }
            Divider()
            Button("New Session") { store.newTab() }
            Button("New Shell") { store.newTab(command: "") }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { store.openFolder(url.path) }
                }
            }
            return true
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 420)
    }

    @ViewBuilder
    private func listColumn(all: [SidebarRow], skipped: Int, shown: [SidebarRow]) -> some View {
        VStack(spacing: 0) {
            // Traffic lights occupy the top-left; actions sit on the right.
            HStack(spacing: 2) {
                Spacer()
                Button {
                    if let name = shownWorkspace {
                        // In the project of the workspace last worked in; in an empty one, a
                        // new project in the home folder.
                        store.newSession(inWorkspace: name)
                    } else if let group = shownGroup, rail { store.newTab(in: group.id) } else { store.newTab() }
                } label: { Image(systemName: "plus") }
                    .help("New session in current project (⌘T)")
                if !rail {
                    Button { store.openFolderPanel() } label: { Image(systemName: "folder.badge.plus") }
                        .help("Open folder as a project (⌘O)")
                    Button { store.showRecentSessions = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .help("Open recent conversation (⇧⌘O)")
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("Settings (⌘,)")
                }
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .foregroundStyle(.secondary)
            .padding(.trailing, 8)
            .frame(height: 28)
            // The list grows into the title bar's safe area when it touches it, which would put it
            // over the buttons and take their clicks. A 1pt gap keeps it below them.
            Spacer(minLength: 0).frame(height: 1)
            if let name = shownWorkspace {
                RailWorkspaceTitle(name: name)
            } else if rail, let group = shownGroup {
                RailProjectTitle(group: group)
            }

            // Not a List: its own drag reorders only inside itself and keeps a row from being
            // carried anywhere else. Rows here are dragged by hand: within a project, to another
            // project, onto a project's or a workspace's mark on the rail.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { row in
                        rowView(row, all: all)
                    }
                    // Inside the scroll view, not above it: a long list of projects to bring in
                    // must scroll, never push the window's content out of its frame.
                    if let name = shownWorkspace {
                        WorkspaceSetup(name: name, empty: store.projects(inWorkspace: name).isEmpty)
                    }
                    // Below the last row: a session goes last in the last project shown; in a
                    // workspace, a project goes last in it.
                    Color.clear
                        .frame(height: 80)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            if let spot = drag.spot, spot == endSpot(all: all, for: .session(UUID())) || spot == .end { DropLine() }
                        }
                        .modifier(SidebarDropTarget(key: "end", resolve: { item, _, _ in endSpot(all: all, for: item) }, perform: perform))
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
                .animation(.spring(response: 0.3, dampingFraction: 0.82), value: shown.map(\.id))
            }
            .scrollIndicators(.never)

            // On a rail the limits are on the rail itself.
            if !rail {
                Hairline()
                UsageView()
            }
        }
    }
}

extension Sidebar {
    /// One row of the list, with what it takes when something is dragged over it.
    @ViewBuilder
    fileprivate func rowView(_ row: SidebarRow, all: [SidebarRow]) -> some View {
        switch row {
        case .group(let group):
            GroupHeader(group: group, inWorkspace: shownWorkspace != nil)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(ProjectMark.hue(group.name).opacity(drag.spot == .intoProject(group.id) ? 0.18 : 0))
                    .padding(.horizontal, 4))
                .overlay(alignment: .top) { if drag.spot == .beforeProject(group.id) { DropLine() } }
                .modifier(SidebarDropTarget(key: "group:" + group.id.uuidString, resolve: { item, _, _ in
                    switch item {
                    case .session: return .intoProject(group.id)
                    case .project(let id): return id == group.id ? nil : .beforeProject(group.id)
                    }
                }, perform: perform))
        case .tab(let tab, let groupID):
            sessionRow(tab, groupID: groupID, nested: false)
        case .nested(let tab, let groupID):
            sessionRow(tab, groupID: groupID, nested: true)
        case .shells(let groupID, let tabs, let expanded):
            StackRow(title: "Idle shells", count: tabs.count, expanded: expanded) {
                if expanded { expandedShells.remove(groupID) } else { expandedShells.insert(groupID) }
            }
            .padding(.leading, 4)
            .padding(.horizontal, 10)
            .help(tabs.map(\.name).joined(separator: ", "))
            .contextMenu {
                Button(expanded ? "Stack idle shells" : "Show idle shells") {
                    if expanded { expandedShells.remove(groupID) } else { expandedShells.insert(groupID) }
                }
                Button("Close idle shells") { for tab in tabs { store.requestClose(tab.id) } }
            }
            .modifier(SidebarDropTarget(key: "shells:" + groupID.uuidString, resolve: { item, _, _ in
                if case .session = item { return .endOfProject(groupID) }
                return nil
            }, perform: perform))
        case .looseHeading:
            Text("Projects")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
                .padding(.bottom, 2)
                .padding(.horizontal, 14)
                .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.07)).frame(height: 1).padding(.horizontal, 14).padding(.top, 4) }
        case .workspace(let name):
            ListWorkspaceHeader(name: name, folded: foldedWorkspaces.contains(name)) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if foldedWorkspaces.contains(name) { foldedWorkspaces.remove(name) } else { foldedWorkspaces.insert(name) }
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 10)
        case .projects(let groups, let expanded):
            StackRow(title: "Idle projects", count: groups.count, expanded: expanded) { expandedProjects.toggle() }
                .padding(.top, 6)
                .padding(.horizontal, 10)
                .help(groups.map(\.name).joined(separator: ", "))
                .contextMenu {
                    Button(expanded ? "Stack idle projects" : "Show idle projects") { expandedProjects.toggle() }
                }
        }
    }

    @ViewBuilder
    private func sessionRow(_ tab: TabItem, groupID: UUID, nested: Bool) -> some View {
        let selected = store.selectedTabID == tab.id
        SessionRowShell(selected: selected, dragging: drag.item == .session(tab.id)) {
            store.selectedTabID = tab.id
        } content: {
            if nested {
                TabRow(tab: tab)
                    .padding(.leading, 20)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.primary.opacity(0.12)).frame(width: 1).padding(.leading, 12)
                    }
            } else if shownWorkspace != nil {
                // Under its project's header, along a line in the project's colour.
                TabRow(tab: tab)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(ProjectMark.hue(store.groups.first { $0.id == groupID }?.name ?? "").opacity(0.35))
                            .frame(width: 2)
                            .padding(.leading, 4)
                            .padding(.vertical, 2)
                    }
            } else {
                TabRow(tab: tab).padding(.leading, rail ? 2 : 8)
            }
        }
        .contextMenu { TabMenu(tab: tab, groupID: groupID) }
        .overlay(alignment: .top) { if drag.spot == .beforeTab(tab.id) { DropLine() } }
        .overlay(alignment: .bottom) { if drag.spot == .afterTab(tab.id) { DropLine() } }
        // Carried as its id: onto a terminal's edge it opens there in a pane; in the list or on
        // the rail, it moves.
        .onDrag { SidebarDrag.begin(.session(tab.id)) }
        .modifier(SidebarDropTarget(key: "tab:" + tab.id.uuidString, resolve: { item, point, height in
            switch item {
            case .session: return point.y < height / 2 ? .beforeTab(tab.id) : .afterTab(tab.id)
            case .project(let id): return id == groupID ? nil : .beforeProject(groupID)
            }
        }, perform: perform))
    }

    /// Where something dropped below the last row goes.
    fileprivate func endSpot(all: [SidebarRow], for item: ProjectDrag.Item) -> SidebarDrag.Spot? {
        switch item {
        case .session:
            let last = all.last { if case .group = $0 { return true } else { return false } }
            if case .group(let group) = last { return .endOfProject(group.id) }
            return nil
        case .project:
            return shownWorkspace != nil ? .end : nil
        }
    }

    /// Carries out a drop in the list.
    fileprivate func perform(_ item: ProjectDrag.Item, _ spot: SidebarDrag.Spot) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            switch (item, spot) {
            case (.session(let id), .beforeTab(let target)), (.session(let id), .afterTab(let target)):
                guard id != target, let loc = store.location(of: target) else { return }
                let after: Int
                if case .afterTab = spot { after = 1 } else { after = 0 }
                store.placeTab(id, inGroup: store.groups[loc.group].id, at: loc.tab + after)
            case (.session(let id), .intoProject(let group)):
                store.placeTab(id, inGroup: group, at: 0)
            case (.session(let id), .endOfProject(let group)):
                store.placeTab(id, inGroup: group, at: .max)
            case (.project(let id), .beforeProject(let target)):
                // In a workspace the project joins the one it is put among; in the plain list,
                // where workspaces don't show, it keeps its own.
                let keep = store.groups.first { $0.id == id }?.workspace
                store.placeGroup(id, before: target, workspace: nil)
                if shownWorkspace == nil { store.updateGroup(id) { $0.workspace = keep } }
            case (.project(let id), .end):
                store.placeGroup(id, before: nil, workspace: shownWorkspace)
            default:
                break
            }
        }
    }
}

/// The thin bar that says where a dragged row will land.
struct DropLine: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2.5)
            .padding(.horizontal, 8)
            .shadow(color: Color.accentColor.opacity(0.6), radius: 3)
            .transition(.opacity)
            .allowsHitTesting(false)
    }
}

/// A session row outside a List: a click selects it, and it draws its own highlight; dimmed
/// while it is being carried.
private struct SessionRowShell<Content: View>: View {
    let selected: Bool
    let dragging: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false
    @Environment(\.hoverBlocked) private var blocked

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RowHighlight(selected: selected, hovering: hovering && !blocked).padding(.horizontal, -2))
            .opacity(dragging ? 0.4 : 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
    }
}

/// What the sidebar is dragging, known from the moment the drag starts, so whatever it passes
/// over can say whether it takes it and where it would go.
@MainActor
final class SidebarDrag: ObservableObject {
    static let shared = SidebarDrag()

    enum Spot: Equatable {
        case beforeTab(UUID), afterTab(UUID)
        /// First in the project: dropped on its header.
        case intoProject(UUID)
        /// Last in the project.
        case endOfProject(UUID)
        /// A project put before another.
        case beforeProject(UUID)
        /// A project put last in the workspace on show.
        case end
    }

    @Published var item: ProjectDrag.Item?
    @Published var spot: Spot?
    /// The drop target that set `spot`, so leaving one target doesn't clear the next one's.
    var owner: String?

    /// Starts carrying `item`; what goes on the pasteboard, for whatever takes it elsewhere.
    static func begin(_ item: ProjectDrag.Item) -> NSItemProvider {
        shared.item = item
        shared.spot = nil
        shared.watchForEnd()
        switch item {
        case .session(let id): return NSItemProvider(object: id.uuidString as NSString)
        case .project(let id): return ProjectDrag.provider(id)
        }
    }

    func clear() {
        item = nil
        spot = nil
        owner = nil
    }

    /// A drag that ends anywhere else (a terminal's edge, outside the window, cancelled) says
    /// nothing here: the button coming up is the sign it is over.
    private func watchForEnd() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.item != nil else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 { self.clear() } else { self.watchForEnd() }
            }
        }
    }
}

/// A row of the list that takes drops: `resolve` says where the dragged thing would go for a
/// point in the row (nil: it doesn't take it), `perform` carries it out.
struct SidebarDropTarget: ViewModifier {
    let key: String
    let resolve: @MainActor (ProjectDrag.Item, CGPoint, CGFloat) -> SidebarDrag.Spot?
    let perform: @MainActor (ProjectDrag.Item, SidebarDrag.Spot) -> Void
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // Only the drop delegate reads the height: no GeometryReader view in every row.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .onDrop(of: [UTType.plainText], delegate: ListDropDelegate(key: key, height: height, resolve: resolve, perform: perform))
    }
}

private struct ListDropDelegate: DropDelegate {
    let key: String
    let height: CGFloat
    let resolve: @MainActor (ProjectDrag.Item, CGPoint, CGFloat) -> SidebarDrag.Spot?
    let perform: @MainActor (ProjectDrag.Item, SidebarDrag.Spot) -> Void

    @MainActor private var spot: SidebarDrag.Spot? {
        guard let item = SidebarDrag.shared.item else { return nil }
        return resolve(item, location, height)
    }
    // Set by the calls below before `spot` is read.
    @MainActor private var location: CGPoint { ListDropDelegate.lastLocation }
    @MainActor private static var lastLocation = CGPoint.zero

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText]) && !info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: SidebarDrag.shared.spot == nil || SidebarDrag.shared.owner != key ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            let drag = SidebarDrag.shared
            if drag.owner == key {
                withAnimation(.easeOut(duration: 0.12)) { drag.spot = nil }
                drag.owner = nil
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            ListDropDelegate.lastLocation = info.location
            let landing = spot
            let drag = SidebarDrag.shared
            drag.clear()
            guard let landing else { return false }
            let perform = perform
            return ProjectDrag.receive(info.itemProviders(for: [.plainText])) { item in perform(item, landing) }
        }
    }

    private func update(_ info: DropInfo) {
        MainActor.assumeIsolated {
            ListDropDelegate.lastLocation = info.location
            let new = spot
            let drag = SidebarDrag.shared
            guard drag.spot != new || drag.owner != key else { return }
            withAnimation(.easeOut(duration: 0.12)) { drag.spot = new }
            drag.owner = new == nil ? (drag.owner == key ? nil : drag.owner) : key
        }
    }
}

extension Store {
    /// Whether a dragged project or session is already in the workspace: dropped there it would
    /// do nothing, so the workspace doesn't offer to take it.
    func isInWorkspace(_ item: ProjectDrag.Item, _ name: String) -> Bool {
        switch item {
        case .project(let id): return groups.first { $0.id == id }?.workspace == name
        case .session(let id): return group(containing: id)?.workspace == name
        }
    }

    /// A project or a session dropped on a workspace: the project joins it, the session goes to
    /// the project of it last worked in.
    func drop(_ item: ProjectDrag.Item, onWorkspace name: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            switch item {
            case .project(let id):
                setWorkspace(id, name)
            case .session(let id):
                moveSession(id, toWorkspace: name)
            }
        }
    }
}

/// A folded group of idle things, "Idle shells" or "Idle projects", with the count in a badge
/// and a chevron. Clicking lists them below; clicking again restacks.
struct StackRow: View {
    let title: String
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 8)
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            CountBadge(count: count)
        }
        .font(.system(size: 12))
        .frame(height: 22)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

/// Transcript modification dates per session, looked up at most every few minutes: the sidebar
/// asks on every redraw.
@MainActor
final class TranscriptDates {
    static let shared = TranscriptDates()
    private var cache: [UUID: (checked: Date, date: Date?)] = [:]

    func date(for tab: TabItem) -> Date? {
        if let hit = cache[tab.id], Date().timeIntervalSince(hit.checked) < 300 { return hit.date }
        let url = Store.claudeTranscriptURL(tab.claudeSessionID.uuidString.lowercased())
        let date = url.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        cache[tab.id] = (Date(), date)
        return date
    }
}

/// When a session was last used, for its row: "Today 14:32", "Yesterday 09:10", "Tuesday 16 Nov
/// 14:32", in the Mac's language.
enum LastUsed {
    private static let relative: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func text(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) { return "\(relative.string(from: date)) \(time)" }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        let day = sameYear ? date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
                           : date.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(day) \(time)"
    }

    /// The latest of what the app saw of the session and its conversation file.
    @MainActor static func date(_ tab: TabItem, _ runtime: TabRuntime) -> Date? {
        [runtime.lastActivity, TranscriptDates.shared.date(for: tab)].compactMap { $0 }.max()
    }
}

struct TabRow: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var agentSlice: AgentMonitor.Slice
    @ObservedObject private var pulls = PullRequestMonitor.shared
    @ObservedObject private var diffStats = DiffStatMonitor.shared
    let tab: TabItem

    init(tab: TabItem) {
        self.tab = tab
        _agentSlice = ObservedObject(wrappedValue: AgentMonitor.shared.slice(tab.id))
    }
    @State private var pointerOver = false
    @Environment(\.hoverBlocked) private var hoverBlocked
    /// Under the pointer, and nothing lying over the row.
    private var hovering: Bool { pointerOver && !hoverBlocked }
    @AppStorage(Prefs.showFolderPath) private var showFolderPath = true
    @AppStorage(Prefs.sidebarDensity) private var density = "comfortable"
    private var compact: Bool { density == "compact" }

    /// "2 agents" while subagents run; the selected session lists them instead.
    private var agentCount: String? {
        guard store.selectedTabID != tab.id else { return nil }
        let running = agentSlice.agents.filter { !$0.finished }.count
        return running > 0 ? "\(running) agent\(running == 1 ? "" : "s")" : nil
    }

    var body: some View { WithRuntime(tab.id) { _ in sessionBody } }

    /// Under the name: what the agent is doing while it works, waits or failed; otherwise when
    /// the session was last used.
    private func subtitle(_ rt: TabRuntime, showFolder: Bool) -> String? {
        switch rt.statusState {
        case .working, .blocked, .error: return rt.statusLine(showFolder: showFolder)
        default:
            guard let date = LastUsed.date(tab, rt) else { return rt.statusLine(showFolder: showFolder) }
            // Restored at launch and not resumed yet is paused; a program that ended is stopped.
            return (rt.dormant ? "Paused · " : rt.exited ? "Stopped · " : "") + LastUsed.text(date)
        }
    }

    /// Drawn again whenever this session's live state changes; see `WithRuntime`.
    @ViewBuilder private var sessionBody: some View {
        let rt = store.runtime[tab.id] ?? TabRuntime()
        // Top-aligned so the dot stays beside the name when agent rows or buttons follow.
        HStack(alignment: .top, spacing: 8) {
            // The status dot turns into a close button on hover, as in Safari's tabs.
            ZStack {
                if hovering {
                    Button { store.requestClose(tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(IconButtonStyle(size: 16))
                    .help("Close session")
                } else {
                    // A finished turn is nothing to look at: a quiet ring, not a green light.
                    if rt.statusState == .done {
                        Circle().strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5).frame(width: 8, height: 8)
                    } else {
                        StatusDot(color: rt.statusColor ?? tab.color.color ?? Color.secondary.opacity(0.35), pulsing: rt.statusState == .working, size: 8)
                    }
                }
            }
            .frame(width: 10, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                if store.renamingID == tab.id {
                    RenameField(initial: tab.name) { store.rename(tab.id, to: $0) }
                } else {
                    HStack(spacing: 5) {
                        Text(tab.name).lineLimit(1).frame(minHeight: 18)
                        if store.layout(near: tab.id)?.contains(tab.id) == true {
                            // On the project's canvas.
                            Image(systemName: "square.grid.2x2").imageScale(.small).foregroundStyle(.tertiary)
                                .help("Shown in a pane")
                        }
                    }
                }
                if compact {
                    // One line a session: the rest is in the tooltip.
                } else if let worktree = tab.worktree {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").imageScale(.small)
                        Text(([worktree.branch, subtitle(rt, showFolder: false), agentCount].compactMap { $0 })
                            .joined(separator: " · "))
                        if let stat = diffStats.stats[tab.id], !stat.isEmpty {
                            Stat(added: stat.added, removed: stat.removed).layoutPriority(1)
                        }
                        if let pr = pulls.requests[tab.id] {
                            PullRequestBadge(pr: pr).layoutPriority(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else if let line = [subtitle(rt, showFolder: showFolderPath), agentCount].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if rt.awaitsPermission {
                    PermissionButtons(tabID: tab.id).padding(.top, 3)
                }
                if pulls.requests[tab.id]?.state == .merged {
                    Button("Delete Worktree") { store.cleanUpMergedWorktree(tab.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("The pull request was merged. Close this session and delete its worktree and branch.")
                        .padding(.top, 3)
                }
                if store.provider(of: tab) == .codex {
                    CodexAgents(tabID: tab.id)
                } else {
                    AgentRows(tabID: tab.id, selected: store.selectedTabID == tab.id)
                }
            }
            Spacer(minLength: 4)
            // Centred on the name line, like the status dot, whatever follows below the name.
            ZStack {
                if hovering {
                    if rt.busy {
                        Button { store.stop(tab.id) } label: { Image(systemName: "stop.fill").font(.system(size: 8)) }
                            .buttonStyle(IconButtonStyle(size: 18))
                            .help("Interrupt (Ctrl-C)")
                    } else if !rt.agentConnected {
                        Button { store.start(tab.id) } label: { Image(systemName: "play.fill").font(.system(size: 8)) }
                            .buttonStyle(IconButtonStyle(size: 18))
                            .help("Start or continue this session")
                    }
                } else if rt.needsAttention {
                    Image(systemName: "bell.fill").font(.caption).foregroundStyle(Palette.needs)
                } else if rt.hasActivity {
                    Circle().fill(Palette.working).frame(width: 6, height: 6)
                }
            }
            .frame(height: 18)
        }
        .buttonStyle(.plain)
        .opacity(rt.exited && !hovering ? 0.55 : 1)
        // A small nudge under the pointer.
        .offset(x: hovering ? 2 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: hovering)
        .padding(.vertical, compact ? 0 : 3)
        .help(compact ? ([tab.worktree?.branch, subtitle(rt, showFolder: true), agentCount].compactMap { $0 }.joined(separator: " · ")) : "")
        .onHover { over in
            pointerOver = over
            if over, !hoverBlocked { store.refreshBusyOnHover(tab.id) }
        }
    }
}

struct GroupHeader: View {
    @EnvironmentObject var store: Store
    let group: TabGroup
    /// Listed among a workspace's projects: a folder mark says it's a project with a folder.
    var inWorkspace = false
    @State private var hovering = false

    var body: some View {
        if inWorkspace { workspaceBody } else { plainBody }
    }

    /// Among a workspace's projects: the project's own coloured mark, its name over its
    /// folder, and how many of its sessions run and how many are stopped. A hairline above
    /// sets it apart from the project before.
    private var workspaceBody: some View {
        let hue = ProjectMark.hue(group.name)
        let (live, stopped) = store.liveCounts(group.tabs)
        return HStack(spacing: 9) {
            Text(ProjectMark.initials(group.name))
                .font(.system(size: 9, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(hue)
                .frame(width: 22, height: 22)
                .background(hue.opacity(hovering ? 0.26 : 0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                // A small tilt and lift under the pointer.
                .scaleEffect(hovering ? 1.06 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if store.renamingID == group.id {
                        RenameField(initial: group.name) { store.rename(group.id, to: $0) }
                    } else {
                        Text(group.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    if let host = group.host, group.isRemote { MachineBadge(host: host) }
                }
                if let directory = group.directory, !directory.isEmpty {
                    Text(directory.tildeAbbreviated)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if hovering {
                Button { store.updateGroup(group.id) { $0.isCollapsed.toggle() } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                }
                .help(group.isCollapsed ? "Show sessions" : "Hide sessions")
                Button { store.newTab(in: group.id, command: "") } label: { Image(systemName: "plus").font(.system(size: 9, weight: .semibold)) }
                    .help("New shell in \(group.name)")
            } else if !group.tabs.isEmpty {
                CountChips(counts: SessionCounts(states: group.tabs.map { store.runtime[$0.id] ?? TabRuntime() }, live: group.tabs.map(store.isLive)))
            }
        }
        .buttonStyle(IconButtonStyle(size: 18))
        .foregroundStyle(.secondary)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.06)).frame(height: 1).padding(.top, 2) }
        .opacity(live == 0 && !hovering ? 0.75 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.updateGroup(group.id) { $0.isCollapsed.toggle() } }
        .onHover { over in withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) { hovering = over } }
        // Dragged onto another workspace's mark on the rail, the project moves there.
        .onDrag { SidebarDrag.begin(.project(group.id)) }
        .listRowSeparator(.hidden)
        .contextMenu { GroupMenu(group: group) }
    }

    private var plainBody: some View {
        HStack(spacing: 6) {
            if store.renamingID == group.id {
                RenameField(initial: group.name) { store.rename(group.id, to: $0) }
            } else {
                Text(group.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
            }
            if group.pinned {
                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary).help("Pinned to the top")
            }
            if let host = group.host, group.isRemote { MachineBadge(host: host) }
            Spacer()
            if !hovering { counts }
            // Show/hide chevron on hover, then the + at the trailing edge.
            if group.isCollapsed, !hovering {
                Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.tertiary).frame(width: 10)
            }
            if hovering {
                Button { store.updateGroup(group.id) { $0.isCollapsed.toggle() } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                }
                .help(group.isCollapsed ? "Show sessions" : "Hide sessions")
                Button { store.newTab(in: group.id, command: "") } label: { Image(systemName: "plus").font(.system(size: 9, weight: .semibold)) }
                    .help("New shell in \(group.name)")
            }
        }
        .buttonStyle(IconButtonStyle(size: 18))
        .foregroundStyle(.secondary)
        .frame(height: 20)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // A double click folds the project, as on a Finder sidebar's section.
        .onTapGesture(count: 2) { store.updateGroup(group.id) { $0.isCollapsed.toggle() } }
        .onHover { hovering = $0 }
        // Dragged among the projects to reorder, or onto a workspace's mark on the rail.
        .onDrag { SidebarDrag.begin(.project(group.id)) }
        .contextMenu { GroupMenu(group: group) }
    }
}

extension GroupHeader {
    /// How many of the project's sessions are working and how many wait for you, so a glance at
    /// the header is enough; a folded project also says how many sessions it holds.
    @ViewBuilder fileprivate var counts: some View {
        let states = group.tabs.map { store.runtime[$0.id] ?? TabRuntime() }
        let working = states.filter { $0.statusState == .working }.count
        let waiting = states.filter { $0.statusState == .blocked || $0.needsAttention }.count
        let failed = states.filter { $0.statusState == .error }.count
        HStack(spacing: 7) {
            if waiting > 0 { count(waiting, Palette.needs).help("\(waiting) waiting for you") }
            if failed > 0 { count(failed, Palette.error).help("\(failed) stopped with an error") }
            if working > 0 { count(working, Palette.working).help("\(working) working") }
            if group.isCollapsed, waiting + failed + working == 0, !group.tabs.isEmpty {
                Text("\(group.tabs.count)").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
                    .help("\(group.tabs.count) session\(group.tabs.count == 1 ? "" : "s")")
            }
        }
    }

    private func count(_ number: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(number)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// Inline rename editor; commits on Enter or focus loss, cancels on Escape.
struct RenameField: View {
    @EnvironmentObject var store: Store
    let initial: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { draft = initial; focused = true }
            .onSubmit { finish(save: true) }
            .onExitCommand { finish(save: false) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(save: true) }
            }
    }

    private func finish(save: Bool) {
        guard store.renamingID != nil else { return }
        if save { commit(draft) }
        store.renamingID = nil
    }
}

struct TabMenu: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var pulls = PullRequestMonitor.shared
    let tab: TabItem
    let groupID: UUID

    var body: some View {
        Button("Rename") { store.renamingID = tab.id }
        Button("Edit Session…") { store.editingTabID = tab.id }
        if store.splitIDs.contains(tab.id) {
            Button("Close Pane") { store.removeFromSplit(tab.id) }
        } else if let selected = store.selectedTabID, selected != tab.id {
            Menu("Show in Pane") {
                Button("Right of \(store.tab(selected)?.name ?? "current")") { store.splitPane(selected, with: tab.id, axis: .horizontal) }
                Button("Below \(store.tab(selected)?.name ?? "current")") { store.splitPane(selected, with: tab.id, axis: .vertical) }
            }
        }
        if !store.splitIDs.contains(tab.id) {
            // The way into panes from a single session: a shell beside or below it.
            Button("New Shell to the Right") { store.selectedTabID = tab.id; store.splitWithShell(tab.id, axis: .horizontal) }
            Button("New Shell Below") { store.selectedTabID = tab.id; store.splitWithShell(tab.id, axis: .vertical) }
        }
        Menu("Color") {
            ForEach(TabColor.allCases) { color in
                Button(color.label) { store.updateTab(tab.id) { $0.color = color } }
            }
        }
        if store.groups.count > 1 {
            Menu("Move to") {
                ForEach(store.groups.filter { $0.id != groupID }) { group in
                    Button(group.name) { store.moveTab(tab.id, toGroup: group.id) }
                }
            }
        }
        if let worktree = tab.worktree {
            Divider()
            if let pr = pulls.requests[tab.id], pr.state == .open {
                Button("Open Pull Request #\(pr.number)") { NSWorkspace.shared.open(pr.url) }
                if pr.checksResult == .failed {
                    Button("Send Failing Checks to Session") { store.sendFailingChecks(tab.id) }
                }
            } else if let pr = pulls.requests[tab.id], pr.state == .merged {
                Button("Delete Merged Worktree…") { store.cleanUpMergedWorktree(tab.id) }
                    .help("#\(pr.number) was merged")
            } else {
                Button("Create Pull Request…") { store.createPullRequest(tab.id) }
            }
            Button("Merge into \(worktree.base)") { store.mergeWorktree(tab.id) }
            Button("Open Worktree in Finder") {
                if let dir = store.directory(of: tab) { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
            }
        }
        Divider()
        Button("Interrupt (Ctrl-C)") { store.stop(tab.id) }
        Button("Restart Session") { store.restart(tab.id) }
        Button("Kill Session") { store.kill(tab.id) }
        Button("Close Session", role: .destructive) { store.requestClose(tab.id) }
    }
}

struct GroupMenu: View {
    @EnvironmentObject var store: Store
    let group: TabGroup

    var body: some View {
        Button("New Session") { store.newTab(in: group.id) }
        Button("New Session in Worktree…") { store.newWorktreeGroupID = group.id }
        Button("New Shell") { store.newTab(in: group.id, command: "") }
        Divider()
        Button("Rename") { store.renamingID = group.id }
        Button("Edit Project…") { store.editingGroupID = group.id }
        Divider()
        if group.pinned {
            Button("Unpin") { store.pin(group.id, false) }
        } else {
            Button("Pin to Top") { store.pin(group.id, true) }
        }
        Menu("Workspace") {
            ForEach(store.workspaceNames, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { group.workspace == name }, set: { store.setWorkspace(group.id, $0 ? name : nil) }))
            }
            if !store.workspaceNames.isEmpty { Divider() }
            Button("New Workspace") {
                let name = store.newWorkspace(with: group.id)
                RailState.shared.showWorkspace(name, in: store)
            }
            if group.workspace != nil {
                Button("Take Out of Workspace") { store.setWorkspace(group.id, nil) }
            }
        }
        Button("Move Up") { store.moveGroup(group.id, by: -1) }
            .disabled(store.groups.first?.id == group.id)
        Button("Move Down") { store.moveGroup(group.id, by: 1) }
            .disabled(store.groups.last?.id == group.id)
        if group.pinned {
            // Pinned projects never fold into the idle stack.
        } else if group.forcedIdle {
            Button("Move to Active") { store.wake(group.id) }
        } else {
            Button("Move to Idle") { store.updateGroup(group.id) { $0.forcedIdle = true } }
        }
        Divider()
        Button("Delete Project", role: .destructive) { store.deleteGroup(group.id) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
