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
            SidebarView(rootURL: fileURL?.deletingLastPathComponent(), currentFile: fileURL, tree: tree, sidebar: sidebar)
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
    }

    /// Creates a new markdown file in the open file's folder and opens it as a tab.
    private func createNewFile() {
        guard let dir = fileURL?.deletingLastPathComponent(),
              let url = FileEntry.makeNewFile(in: dir) else { return }
        tree.reload()
        Task { try? await openDocument(at: url) }
    }

    /// Reveals the sidebar (if collapsed) and pulls keyboard focus into it (⌘⇧E).
    private func focusSidebar() {
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
                            initialLine: sync.target(for: .view))
                .ignoresSafeArea(edges: .bottom)
        case .edit:
            MarkdownEditor(text: $document.text, find: find, sync: sync,
                           initialLine: sync.target(for: .edit))
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
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

            // only windows rooted at the SAME folder are tab siblings.
            // (don't filter on isVisible — it's false during rapid window creation)
            let siblings = Self.registry.allObjects.filter {
                $0 !== window && $0.tabbingIdentifier == tabID
            }
            Self.registry.add(window)

            if let host = siblings.first, window.tabGroup !== host.tabGroup {
                // a qmd window already exists -> tab into it, matching its frame so
                // adding a tab never resizes the group.
                let hostFrame = host.frame
                window.setFrame(hostFrame, display: false)
                host.addTabbedWindow(window, ordered: .above)
                window.setFrame(hostFrame, display: false)
                window.makeKeyAndOrderFront(nil)
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

        func detach() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
    }
}
