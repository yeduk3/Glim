import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Bumped whenever the watched folder changes on disk so the tree re-reads.
/// Both the root list and every expanded `FileRow` observe it. The change can come
/// from this tab, another tab, or an external app — the FSEvents watcher fires
/// regardless, which is what keeps sidebars across tabs synced to the filesystem.
final class FileTreeModel: ObservableObject {
    @Published var version = 0
    private lazy var watcher = DirectoryWatcher { [weak self] in self?.reload() }

    func reload() { version &+= 1 }

    /// Points the filesystem watcher at `url` (nil stops watching). The watcher
    /// no-ops when already on that path, so this is safe to call on every update.
    func watch(_ url: URL?) {
        if let url { watcher.start(url: url) } else { watcher.stop() }
    }
}

/// Drives keyboard control of the sidebar: which row is selected, which (if any)
/// is being renamed inline, and a pulse to pull keyboard focus into the list
/// (⌘⇧E). Mirrors the `FindController` pattern so the menu command can reach it.
final class SidebarController: ObservableObject {
    @Published var selection: URL?
    @Published var renamingURL: URL?
    @Published var renameText = ""
    /// Bumped to move keyboard focus into the list (⌘⇧E, or after a rename commits).
    @Published var focusPulse = 0
    /// Set by the key monitor (Space / ⌘↓) and row clicks to ask SwiftUI to open a
    /// file; SwiftUI owns `openDocument`, the AppKit monitor doesn't, so it routes
    /// through here. `focusDetail` distinguishes ⌘↓/click (move focus to the file
    /// view) from Space (preview, keep focus in the sidebar). `token` makes a repeat
    /// of the same request still fire `onChange`.
    @Published var openRequest: OpenRequest?
    /// The List's backing outline view, captured by the keyboard bridge so the key
    /// monitor can tell whether *this* tab's sidebar is the first responder.
    weak var outlineView: NSView?

    struct OpenRequest: Equatable { let url: URL; let focusDetail: Bool; let token: Int }
    private var openToken = 0

    /// True when the *next* selection change is being driven by a sidebar mouse click
    /// (set by the bridge's mouse monitor, cleared by any keypress). Lets the selection
    /// `onChange` open on click while leaving arrow-key navigation as plain selection.
    var selectionFromClick = false

    func focus() { focusPulse &+= 1 }
    func requestOpen(_ url: URL, focusDetail: Bool) {
        openToken &+= 1
        openRequest = OpenRequest(url: url, focusDetail: focusDetail, token: openToken)
    }
    func beginRename(_ url: URL) { selection = url; renamingURL = url }
    func endRename() { renamingURL = nil; focus() }

    /// Snapshots the sidebar scroll position so the tab an open switches to can restore it
    /// (a fresh tab's sidebar otherwise renders at the top). Call right before opening.
    func captureScroll(root: URL?) { SidebarScroll.capture(outline: outlineView, root: root) }
}

struct SidebarView: View {
    let rootURL: URL?
    let currentFile: URL?
    @ObservedObject var tree: FileTreeModel
    @ObservedObject var sidebar: SidebarController
    @ObservedObject var detailFocus: DetailFocusController
    @Environment(\.openDocument) private var openDocument

    var body: some View {
        Group {
            if let rootURL {
                List(selection: $sidebar.selection) {
                    Section {
                        ForEach(FileEntry.children(of: rootURL)) { entry in
                            FileRow(entry: entry, root: rootURL, currentFile: currentFile,
                                    tree: tree, sidebar: sidebar)
                        }
                    } header: {
                        HStack {
                            Text(rootURL.lastPathComponent.removingPercentEncoding ?? rootURL.lastPathComponent)
                            Spacer()
                            Button { newFile(in: rootURL) } label: {
                                Image(systemName: "doc.badge.plus")
                            }
                            .buttonStyle(.plain)
                            .help("New Markdown File  (⌘N)")
                        }
                    }
                }
                .listStyle(.sidebar)
                // AppKit bridge: `.focused()` on a List doesn't make its NSOutlineView
                // first responder on macOS, so ⌘⇧E wouldn't enable arrow keys. This
                // grabs first responder on `focusPulse` (native ↑↓←→) and runs a key
                // monitor for the custom space / ⌘↓ / Return actions the outline view
                // would otherwise swallow.
                .background(SidebarKeyboardBridge(controller: sidebar, pulse: sidebar.focusPulse))
                .background(SidebarScrollRestorer(root: rootURL))
                .onChange(of: sidebar.focusPulse) { _, _ in
                    if sidebar.selection == nil {
                        sidebar.selection = currentFile ?? FileEntry.children(of: rootURL).first?.url
                    }
                }
                .onChange(of: sidebar.openRequest) { _, req in
                    guard let req else { return }
                    sidebar.openRequest = nil
                    activate(req.url, focusDetail: req.focusDetail)
                }
                // Keep the visible selection on the file this tab is showing, so
                // switching tabs (or following a rename) never leaves a stale row
                // highlighted from a different tab.
                .onChange(of: currentFile) { _, f in sidebar.selection = f }
                // Single click opens. The outline view drives `selection` reliably on
                // mouseDown; the mouse monitor flags that the change came from a click so
                // arrow-key navigation (which clears the flag) stays selection-only.
                .onChange(of: sidebar.selection) { _, s in
                    guard sidebar.selectionFromClick else { return }
                    sidebar.selectionFromClick = false
                    if let s { sidebar.requestOpen(s, focusDetail: true) }
                }
            } else {
                ContentUnavailableView("No Folder", systemImage: "folder",
                    description: Text("Open a Markdown file to browse its folder."))
            }
        }
        .frame(minWidth: 180)
        .onAppear {
            tree.watch(rootURL)
            if sidebar.selection == nil { sidebar.selection = currentFile }
        }
        .onChange(of: rootURL) { _, new in tree.watch(new) }
    }

    private func newFile(in dir: URL) {
        guard let url = FileEntry.makeNewFile(in: dir) else { return }
        tree.reload()
        sidebar.captureScroll(root: rootURL)
        Task { try? await openDocument(at: url) }
    }

    /// Opens / re-focuses for a sidebar row. `focusDetail` distinguishes ⌘↓ and click
    /// (move focus to the file view) from Space (preview — keep focus in the sidebar).
    /// Folders are left to the list's native ←/→ expand.
    private func activate(_ url: URL, focusDetail: Bool) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard !isDir.boolValue else { return }

        // Already the open file -> don't reopen, just move focus where asked.
        if currentFile?.standardizedFileURL == url.standardizedFileURL {
            if focusDetail { detailFocus.focus() } else { sidebar.focus() }
            return
        }
        guard FileEntry.isMarkdown(url) else {
            NSWorkspace.shared.open(url)   // hand non-markdown to its default app
            return
        }
        // Opening may switch to another tab; park the focus intent for the destination
        // ContentView to claim once it shows this file.
        OpenFocusRouter.shared.pending = PendingFocus(url: url, target: focusDetail ? .detail : .sidebar)
        // Park this sidebar's root so a file in a subfolder tabs into THIS window and keeps
        // the same tree, instead of re-rooting at the subfolder / opening a new window.
        if let rootURL { OpenRootRouter.shared.roots[url.standardizedFileURL] = rootURL }
        sidebar.captureScroll(root: rootURL)
        Task { try? await openDocument(at: url) }
    }
}

private struct FileRow: View {
    let entry: FileEntry
    let root: URL?
    let currentFile: URL?
    @ObservedObject var tree: FileTreeModel
    @ObservedObject var sidebar: SidebarController
    @ObservedObject private var expansion = SidebarExpansion.shared

    @State private var children: [FileEntry] = []
    @FocusState private var renameFocused: Bool
    @Environment(\.openDocument) private var openDocument

    private var isRenaming: Bool { sidebar.renamingURL == entry.url }

    /// Disclosure state read from the shared store so it's one source of truth across tabs.
    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { expansion.expanded.contains(entry.url) },
            set: { if $0 { expansion.expanded.insert(entry.url) } else { expansion.expanded.remove(entry.url) } }
        )
    }

    private func reloadChildrenIfExpanded() {
        children = expansion.expanded.contains(entry.url) ? FileEntry.children(of: entry.url) : []
    }

    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: expandedBinding) {
                ForEach(children) { FileRow(entry: $0, root: root, currentFile: currentFile, tree: tree, sidebar: sidebar) }
            } label: {
                if isRenaming {
                    renameField
                } else {
                    Label(entry.name, systemImage: "folder")
                        .lineLimit(1)
                }
            }
            .tag(entry.url)
            // Shared expansion -> load children when this folder becomes expanded (here or in
            // another tab), and on first appearance if it's already expanded.
            .onAppear { reloadChildrenIfExpanded() }
            .onChange(of: expansion.expanded) { _, _ in reloadChildrenIfExpanded() }
            .onChange(of: tree.version) { _, _ in reloadChildrenIfExpanded() }
            .contextMenu { rowMenu(newFileTarget: entry.url) }
        } else {
            Group {
                if isRenaming {
                    renameField
                } else {
                    Label {
                        Text(entry.name).lineLimit(1)
                    } icon: {
                        Image(systemName: entry.isMarkdown ? "doc.text" : "doc")
                            .foregroundStyle(entry.isMarkdown ? Color.accentColor : Color.secondary)
                    }
                    .contentShape(Rectangle())
                    // Opening on click is handled in SidebarView's `selection` onChange (a
                    // SwiftUI TapGesture here was intermittently swallowed by the table's
                    // own mouse tracking, so a click would select the row but not open it).
                }
            }
            .tag(entry.url)
            .fontWeight(isCurrent ? .semibold : .regular)
            .contextMenu { rowMenu(newFileTarget: entry.url.deletingLastPathComponent()) }
        }
    }

    /// Inline editor shown in place of the row label while renaming.
    private var renameField: some View {
        TextField("", text: $sidebar.renameText)
            .textFieldStyle(.plain)
            .focused($renameFocused)
            .onAppear { sidebar.renameText = entry.name; renameFocused = true }
            .onSubmit { commitRename() }
            .onExitCommand { sidebar.endRename() }
    }

    /// `newFileTarget` is the folder a "New File" here lands in: the directory itself
    /// for a folder row, the containing folder for a file row.
    @ViewBuilder private func rowMenu(newFileTarget: URL) -> some View {
        Button("New File") { newFile(in: newFileTarget) }
        Button("Rename") { sidebar.beginRename(entry.url) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            FileEntry.trash(entry.url)
            tree.reload()
        }
    }

    private var isCurrent: Bool {
        guard let currentFile else { return false }
        return entry.url.standardizedFileURL == currentFile.standardizedFileURL
    }

    private func commitRename() {
        if let new = FileEntry.rename(entry.url, to: sidebar.renameText) {
            if sidebar.selection == entry.url { sidebar.selection = new }
            tree.reload()
        }
        sidebar.endRename()
    }

    private func newFile(in dir: URL) {
        guard let url = FileEntry.makeNewFile(in: dir) else { return }
        if entry.isDirectory { expansion.expanded.insert(entry.url) }
        if let root { OpenRootRouter.shared.roots[url.standardizedFileURL] = root }
        tree.reload()
        Task { try? await openDocument(at: url) }
    }

}

struct FileEntry: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool

    var id: URL { url }

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdwn", "mkdn"]

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    var isMarkdown: Bool { FileEntry.isMarkdown(url) }

    static func children(of dir: URL) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }

        return items.compactMap { url -> FileEntry? in
            let vals = try? url.resourceValues(forKeys: Set(keys))
            let isDir = vals?.isDirectory ?? false
            let name = vals?.name ?? url.lastPathComponent
            return FileEntry(url: url, name: name, isDirectory: isDir)
        }
        .sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Creates a unique `Untitled[ N].md` in `dir` and returns it (nil on write failure).
    static func makeNewFile(in dir: URL) -> URL? {
        let fm = FileManager.default
        var url = dir.appendingPathComponent("Untitled.md")
        var i = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("Untitled \(i).md")
            i += 1
        }
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Renames `url` to `newName` within the same folder. Returns the new URL, or nil
    /// if the name is empty, contains a path separator, or collides with an existing item.
    ///
    /// Uses a *coordinated* move (NSFileCoordinator + `didMoveTo:`) rather than a bare
    /// `FileManager.moveItem`, so that if the file is open in a tab its NSDocument (a
    /// file presenter) follows to the new URL instead of dangling on the old path.
    static func rename(_ url: URL, to newName: String) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        let dest = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if dest.standardizedFileURL == url.standardizedFileURL { return url }
        guard !FileManager.default.fileExists(atPath: dest.path) else { return nil }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var moved = false
        coordinator.coordinate(writingItemAt: url, options: .forMoving,
                               writingItemAt: dest, options: .forReplacing,
                               error: &coordError) { src, dst in
            coordinator.item(at: src, willMoveTo: dst)
            do {
                try FileManager.default.moveItem(at: src, to: dst)
                coordinator.item(at: src, didMoveTo: dst)   // notifies the open document
                moved = true
            } catch {
                moved = false
            }
        }
        return moved ? dest : nil
    }

    /// Moves `url` to the Trash (reversible, so no confirmation needed).
    static func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// Bridges the SwiftUI sidebar to AppKit for keyboard control, working around two
/// macOS limitations of `List`:
///   1. `.focused()` won't make the backing `NSOutlineView` first responder, so
///      ⌘⇧E couldn't enable arrow-key navigation — `grabFocus()` does it directly.
///   2. A focused outline view swallows Space/Return, so SwiftUI `.onKeyPress`
///      never sees them — a local key monitor intercepts Space / ⌘↓ / Return and
///      routes them to the controller (open / begin-rename) before the view reacts.
/// The monitor is scoped to this tab via `controller.outlineView`, so other tabs'
/// monitors ignore the event.
private struct SidebarKeyboardBridge: NSViewRepresentable {
    let controller: SidebarController
    let pulse: Int

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.lastPulse = pulse
        let v = NSView()
        context.coordinator.bridgeView = v   // its `.window` scopes the mouse monitor to this tab
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard pulse != context.coordinator.lastPulse else { return }
        context.coordinator.lastPulse = pulse
        context.coordinator.grabFocus(near: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        private let controller: SidebarController
        private var monitor: Any?
        private var mouseMonitor: Any?
        weak var bridgeView: NSView?
        var lastPulse = -1

        init(controller: SidebarController) {
            self.controller = controller
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // `handle` returns nil to SWALLOW (e.g. ⌘↓ opens the file and must NOT
                // also let the outline view move the selection down). Don't fold that nil
                // into `?? event` — that would re-dispatch the swallowed key. Only fall
                // back to passing the event through when `self` is gone.
                guard let self else { return event }
                // Any keypress in this tab means the *next* selection change is keyboard
                // navigation, not a click — so it must not open. (Set before the outline
                // view processes an arrow key and moves the selection.)
                if event.window === self.bridgeView?.window { self.controller.selectionFromClick = false }
                return self.handle(event)
            }
            // A reliable click signal the flaky SwiftUI row TapGesture couldn't provide:
            // the outline view always updates `selection` on mouseDown, but the gesture's
            // onEnded was intermittently swallowed by the table's own tracking. Marking the
            // click here lets the selection `onChange` open it.
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.noteSidebarClick(event)
                return event   // observe only; never swallow
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            monitor = nil
            mouseMonitor = nil
        }

        /// Flags a left click that lands on a row of *this* tab's sidebar outline view, so
        /// the resulting selection change opens the file. Scoped to this tab's window and
        /// the outline's bounds so detail-pane / header / empty-area clicks don't open.
        private func noteSidebarClick(_ event: NSEvent) {
            guard let win = bridgeView?.window, event.window === win,
                  let outline = Self.findOutlineView(in: win.contentView) as? NSTableView else { return }
            controller.outlineView = outline   // also captures it without needing a ⌘⇧E focus first
            let p = outline.convert(event.locationInWindow, from: nil)
            guard outline.bounds.contains(p), outline.row(at: p) >= 0 else { return }
            controller.selectionFromClick = true
        }

        /// Makes this tab's sidebar outline view first responder (deferred so a
        /// just-revealed sidebar has laid out). Captures the view so the monitor
        /// can scope to it. Retries once if the view isn't built yet.
        func grabFocus(near anchor: NSView, retry: Bool = true) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = anchor.window else { return }
                if let outline = Self.findOutlineView(in: window.contentView) {
                    self.controller.outlineView = outline
                    window.makeFirstResponder(outline)
                } else if retry {
                    self.grabFocus(near: anchor, retry: false)
                }
            }
        }

        /// Intercepts the custom keys only while this sidebar's outline view is the
        /// first responder and no inline rename is active. Returns nil to swallow.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let outline = controller.outlineView,
                  event.window?.firstResponder === outline,
                  controller.renamingURL == nil,
                  let sel = controller.selection else { return event }

            switch event.keyCode {
            case 36, 76:                     // Return / Enter -> rename
                controller.beginRename(sel)
                return nil
            case 49:                         // Space -> preview (keep focus in sidebar)
                controller.requestOpen(sel, focusDetail: false)
                return nil
            case 125 where event.modifierFlags.contains(.command):  // ⌘↓ -> open + focus file view
                controller.requestOpen(sel, focusDetail: true)
                return nil
            default:
                return event
            }
        }

        private static func findOutlineView(in view: NSView?) -> NSView? {
            guard let view else { return nil }
            if view is NSTableView { return view }   // NSOutlineView is an NSTableView
            for sub in view.subviews {
                if let found = findOutlineView(in: sub) { return found }
            }
            return nil
        }
    }
}
