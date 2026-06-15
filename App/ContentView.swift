import SwiftUI

struct ContentView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    @State private var mode: EditorMode = .view
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @StateObject private var find = FindController()
    @StateObject private var sync = ScrollSync()
    @StateObject private var tree = FileTreeModel()
    @StateObject private var sidebar = SidebarController()
    @StateObject private var detailFocus = DetailFocusController()
    @ObservedObject private var fontScale = FontScale.shared
    @Environment(\.openDocument) private var openDocument

    private var sidebarVisible: Binding<Bool> {
        Binding(
            get: { columnVisibility != .detailOnly },
            set: { show in
                withAnimation(.easeInOut(duration: 0.25)) {
                    columnVisibility = show ? .all : .detailOnly
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(rootURL: fileURL?.deletingLastPathComponent(), currentFile: fileURL,
                        tree: tree, sidebar: sidebar, detailFocus: detailFocus)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 420)
        } detail: {
            detail
                .toolbar { toolbarContent }
        }
        .focusedSceneValue(\.editorMode, $mode)
        .focusedSceneValue(\.sidebarVisible, sidebarVisible)
        .focusedSceneValue(\.findController, find)
        .focusedSceneValue(\.newFileAction, createNewFile)
        .focusedSceneValue(\.focusSidebarAction, focusSidebar)
        .background(WindowAccessor(rootKey: fileURL?.deletingLastPathComponent().standardizedFileURL.path ?? "none"))
        // Toggling to the rendered view focuses it so arrow keys scroll immediately.
        // (The raw editor self-focuses on entry.) Only fires on an actual ⌘E toggle,
        // not on a fresh tab/Space-preview where mode starts at .view.
        .onChange(of: mode) { _, m in
            if m == .view { detailFocus.focus() }
        }
        // A sidebar-initiated open can land in this tab (new or already-open); claim
        // the parked focus intent once we're showing that file.
        .onAppear { claimPendingFocus() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            claimPendingFocus()
        }
    }

    /// If a sidebar open parked a focus intent for this tab's file, apply it (focus the
    /// sidebar for a Space-preview, or the detail view for ⌘↓ / click) and clear it.
    private func claimPendingFocus() {
        guard let p = OpenFocusRouter.shared.pending, let f = fileURL,
              f.standardizedFileURL == p.url.standardizedFileURL else { return }
        OpenFocusRouter.shared.pending = nil
        DispatchQueue.main.async {
            switch p.target {
            case .sidebar: sidebar.focus()
            case .detail: detailFocus.focus()
            }
        }
    }

    /// Creates a new markdown file in the open file's folder and opens it as a tab.
    private func createNewFile() {
        guard let dir = fileURL?.deletingLastPathComponent(),
              let url = FileEntry.makeNewFile(in: dir) else { return }
        tree.reload()
        Task { try? await openDocument(at: url) }
    }

    /// ⌘⇧E toggle: if the sidebar already holds keyboard focus, bounce focus to the
    /// detail view; otherwise reveal the sidebar (if collapsed) and focus it.
    private func focusSidebar() {
        if let ov = sidebar.outlineView, ov.window?.firstResponder === ov {
            detailFocus.focus()
            return
        }
        if columnVisibility == .detailOnly {
            withAnimation(.easeInOut(duration: 0.25)) { columnVisibility = .all }
        }
        sidebar.focus()
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            if find.isVisible {
                FindBar(find: find)
                Divider()
            }
            modeView
        }
    }

    @ViewBuilder private var modeView: some View {
        switch mode {
        case .view:
            MarkdownWebView(markdown: document.text, find: find, sync: sync,
                            initialLine: sync.target(for: .view), focusPulse: detailFocus.pulse,
                            fontScale: fontScale.scale)
                .ignoresSafeArea(edges: .bottom)
        case .edit:
            MarkdownEditor(text: $document.text, find: find, sync: sync,
                           initialLine: sync.target(for: .edit), focusPulse: detailFocus.pulse,
                           fontScale: fontScale.scale)
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Mode", selection: $mode) {
                Image(systemName: "eye").tag(EditorMode.view)
                Image(systemName: "pencil").tag(EditorMode.edit)
            }
            .pickerStyle(.segmented)
            .help("Toggle View / Edit  (⌘E)")
        }
    }
}

/// Bridges to the hosting NSWindow once it exists. Forces additional documents to
/// open as tabs (not separate windows) and persists the window size across launches.
/// Note: NSWindow `frameAutosaveName` is intentionally NOT used — it disables window
/// tabbing — so size persistence is done manually via UserDefaults.
private struct WindowAccessor: NSViewRepresentable {
    /// Files sharing this key (their parent folder) tab together; different keys open new windows.
    let rootKey: String

    func makeCoordinator() -> Coordinator { Coordinator(rootKey: rootKey) }

    func makeNSView(context: Context) -> WindowReaderView {
        let v = WindowReaderView()
        let coord = context.coordinator
        v.onWindow = { window in coord.attach(window) }
        return v
    }
    func updateNSView(_ nsView: WindowReaderView, context: Context) {}
    static func dismantleNSView(_ nsView: WindowReaderView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Fires `onWindow` exactly when the view is placed into its hosting window.
    final class WindowReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private var fired = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window, !fired { fired = true; onWindow?(w) }
        }
    }

    final class Coordinator {
        private static let sizeKey = "qmd.windowSize"
        private static let registry = NSHashTable<NSWindow>.weakObjects()
        private let rootKey: String
        private var token: NSObjectProtocol?

        init(rootKey: String) { self.rootKey = rootKey }

        private var tabID: NSWindow.TabbingIdentifier { "qmd::\(rootKey)" }

        /// Last user-chosen window size, or a sensible default if none cached yet.
        private static func cachedSize() -> NSSize {
            if let d = UserDefaults.standard.dictionary(forKey: sizeKey),
               let w = d["w"] as? Double, let h = d["h"] as? Double, w > 300, h > 200 {
                return NSSize(width: w, height: h)
            }
            return NSSize(width: 1200, height: 820)
        }

        func attach(_ window: NSWindow) {
            window.tabbingMode = .preferred
            window.tabbingIdentifier = tabID

            // An existing qmd window for the SAME root is the tab host. Look past our
            // weak registry to every app window, so a momentary registry miss during
            // rapid opening can't spawn a stray un-tabbed window — that stray window was
            // what knocked a single Magnet-snapped window out of its arrangement.
            let host = existingHost(excluding: window)
            Self.registry.add(window)

            if let host {
                // Tab into the existing group and adopt its exact frame, so adding a tab
                // never moves or resizes the window the user (or Magnet) positioned.
                let hostFrame = host.frame
                if window.tabGroup !== host.tabGroup {
                    host.addTabbedWindow(window, ordered: .above)
                }
                window.setFrame(hostFrame, display: false)
                window.makeKeyAndOrderFront(nil)
                // AppKit/SwiftUI sometimes runs a post-tab layout pass that nudges the
                // group off its Magnet snap; re-assert the frame once it settles.
                DispatchQueue.main.async { [weak host, weak window] in
                    guard let host, let window else { return }
                    let f = host.frame
                    if window.frame != f { window.setFrame(f, display: false) }
                }
            } else {
                // first window of this root -> cached size (or default fallback).
                var f = window.frame
                f.size = Self.cachedSize()
                window.setFrame(f, display: true)
            }

            // persist size on resize
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak window] _ in
                guard let s = window?.frame.size else { return }
                UserDefaults.standard.set(["w": Double(s.width), "h": Double(s.height)], forKey: Self.sizeKey)
            }
        }

        /// An existing live qmd window sharing this tab id — registry first, then a
        /// sweep of all app windows in case the registry hasn't caught up yet.
        private func existingHost(excluding window: NSWindow) -> NSWindow? {
            let match: (NSWindow) -> Bool = { $0 !== window && $0.tabbingIdentifier == self.tabID }
            return Self.registry.allObjects.first(where: match) ?? NSApp.windows.first(where: match)
        }

        func detach() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
    }
}
