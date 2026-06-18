import SwiftUI

struct ContentView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    init(document: Binding<MarkdownDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        // The folder the sidebar browses for this tab. Normally the file's parent, but a
        // file opened from a subfolder inherits the source tab's root (parked in
        // OpenRootRouter), so it tabs into the same window and keeps the same tree.
        let inherited = fileURL.flatMap { OpenRootRouter.shared.roots[$0.standardizedFileURL] }
        _browsingRoot = State(initialValue: inherited ?? fileURL?.deletingLastPathComponent())
    }

    @State private var mode: EditorMode = .view
    @State private var browsingRoot: URL?
    @ObservedObject private var sidebarVis = SidebarVisibility.shared
    @StateObject private var find = FindController()
    @StateObject private var sync = ScrollSync()
    @StateObject private var tree = FileTreeModel()
    @StateObject private var sidebar = SidebarController()
    @StateObject private var detailFocus = DetailFocusController()
    @StateObject private var selection = SelectionController()
    @StateObject private var quickOpen = QuickOpenController()
    @StateObject private var fileSync = FileSync()
    @StateObject private var editCursor = EditCursorStore()
    @ObservedObject private var fontScale = FontScale.shared
    @ObservedObject private var fullWidth = FullWidthMode.shared
    @Environment(\.openDocument) private var openDocument

    private var sidebarVisible: Binding<Bool> {
        Binding(
            get: { sidebarVis.columnVisibility != .detailOnly },
            set: { show in
                withAnimation(.easeInOut(duration: 0.25)) {
                    sidebarVis.columnVisibility = show ? .all : .detailOnly
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVis.columnVisibility) {
            SidebarView(rootURL: browsingRoot, currentFile: fileURL,
                        tree: tree, sidebar: sidebar, detailFocus: detailFocus)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 420)
        } detail: {
            detail
                .toolbar { toolbarContent }
        }
        .sheet(isPresented: Binding(get: { quickOpen.isVisible },
                                    set: { if !$0 { quickOpen.hide() } })) {
            QuickOpenPalette(controller: quickOpen, onOpen: openFromQuickOpen)
        }
        .focusedSceneValue(\.editorMode, $mode)
        .focusedSceneValue(\.sidebarVisible, sidebarVisible)
        .focusedSceneValue(\.findController, find)
        .focusedSceneValue(\.newFileAction, createNewFile)
        .focusedSceneValue(\.focusSidebarAction, focusSidebar)
        .focusedSceneValue(\.quickOpenAction, { quickOpen.show(root: browsingRoot) })
        .background(WindowAccessor(rootKey: browsingRoot?.standardizedFileURL.path ?? "none"))
        // Toggling to the rendered view focuses it so arrow keys scroll immediately.
        // (The raw editor self-focuses on entry.) Only fires on an actual ⌘E toggle,
        // not on a fresh tab/Space-preview where mode starts at .view.
        .onChange(of: mode) { _, m in
            selection.clear()   // stale count from the outgoing view shouldn't linger
            if m == .view { detailFocus.focus() }
        }
        // A sidebar-initiated open can land in this tab (new or already-open); claim
        // the parked focus intent once we're showing that file.
        .onAppear {
            claimPendingFocus()
            if let f = fileURL?.standardizedFileURL { OpenRootRouter.shared.roots[f] = nil }
            fileSync.currentText = { document.text }
            fileSync.applyReload = { document.text = $0 }
            fileSync.start(url: fileURL)
        }
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
        if let root = browsingRoot { OpenRootRouter.shared.roots[url.standardizedFileURL] = root }
        tree.reload()
        sidebar.captureScroll(root: browsingRoot)
        Task { try? await openDocument(at: url) }
    }

    /// Opens a file chosen from the ⌘O palette (markdown opens as a tab; anything else is
    /// handed to its default app), carrying the sidebar scroll position into the new tab.
    private func openFromQuickOpen(_ url: URL) {
        quickOpen.hide()
        guard FileEntry.isMarkdown(url) else { NSWorkspace.shared.open(url); return }
        openInApp(url)
    }

    /// Opens a markdown file in qmd (as a tab in this folder's group), reusing the current
    /// tab if it's already that file. Used by the ⌘O palette and in-document links.
    private func openInApp(_ url: URL) {
        if fileURL?.standardizedFileURL == url.standardizedFileURL { detailFocus.focus(); return }
        OpenFocusRouter.shared.pending = PendingFocus(url: url, target: .detail)
        // Hand the destination tab this tab's root so a subfolder file tabs in here.
        if let root = browsingRoot { OpenRootRouter.shared.roots[url.standardizedFileURL] = root }
        sidebar.captureScroll(root: browsingRoot)
        Task { try? await openDocument(at: url) }
    }

    /// ⌘⇧E toggle: if the sidebar already holds keyboard focus, bounce focus to the
    /// detail view; otherwise reveal the sidebar (if collapsed) and focus it.
    private func focusSidebar() {
        if let ov = sidebar.outlineView, ov.window?.firstResponder === ov {
            detailFocus.focus()
            return
        }
        if sidebarVis.columnVisibility == .detailOnly {
            withAnimation(.easeInOut(duration: 0.25)) { sidebarVis.columnVisibility = .all }
        }
        sidebar.focus()
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            if fileSync.conflict != nil {
                ExternalChangeBar(onReload: { fileSync.reload() }, onKeep: { fileSync.keepMine() })
                Divider()
            }
            if find.isVisible {
                FindBar(find: find)
                Divider()
            }
            modeView
            if selection.count > 0 {
                Divider()
                SelectionCountBar(count: selection.count)
            }
        }
    }

    @ViewBuilder private var modeView: some View {
        switch mode {
        case .view:
            MarkdownWebView(markdown: document.text, find: find, sync: sync,
                            initialLine: sync.target(for: .view), focusPulse: detailFocus.pulse,
                            fontScale: fontScale.scale, fullWidth: fullWidth.isFullWidth, selection: selection,
                            docDirectory: fileURL?.deletingLastPathComponent(), onOpenFile: openInApp)
                .ignoresSafeArea(edges: .bottom)
        case .edit:
            MarkdownEditor(text: $document.text, find: find, sync: sync,
                           initialLine: sync.target(for: .edit), focusPulse: detailFocus.pulse,
                           fontScale: fontScale.scale, fullWidth: fullWidth.isFullWidth, selection: selection,
                           cursor: editCursor)
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { fullWidth.isFullWidth },
                                 set: { _ in fullWidth.toggle() })) {
                Image(systemName: "arrow.left.and.right")
            }
            .help("Toggle Full Width  (⇧⌘F)")
        }
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

/// Banner shown when the open file changed on disk while the buffer also has unsaved edits.
/// Reload adopts the disk version; Keep Mine ignores it (the next save overwrites disk).
private struct ExternalChangeBar: View {
    let onReload: () -> Void
    let onKeep: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("This file changed on disk.").font(.caption)
            Spacer(minLength: 0)
            Button("Reload", action: onReload)
            Button("Keep Mine", action: onKeep)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

/// Small trailing readout of how many characters the current selection spans.
/// Shown only while something is selected (count > 0).
private struct SelectionCountBar: View {
    let count: Int
    var body: some View {
        HStack {
            Spacer()
            Text("\(count) character\(count == 1 ? "" : "s") selected")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(.bar)
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
