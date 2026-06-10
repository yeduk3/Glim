import SwiftUI
import os

struct ContentView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    @State private var mode: EditorMode = .view
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
            SidebarView(rootURL: fileURL?.deletingLastPathComponent(), currentFile: fileURL)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 420)
        } detail: {
            detail
                .toolbar { toolbarContent }
        }
        .focusedSceneValue(\.editorMode, $mode)
        .focusedSceneValue(\.sidebarVisible, sidebarVisible)
        .background(WindowAccessor(rootKey: fileURL?.deletingLastPathComponent().standardizedFileURL.path ?? "none"))
    }

    @ViewBuilder private var detail: some View {
        switch mode {
        case .view:
            MarkdownWebView(markdown: document.text)
                .ignoresSafeArea(edges: .bottom)
        case .edit:
            MarkdownEditor(text: $document.text)
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
        private static let log = Logger(subsystem: "com.gyu.qmd.win", category: "tab")
        private static let sizeKey = "qmd.windowSize"
        private static let registry = NSHashTable<NSWindow>.weakObjects()
        private let rootKey: String
        private var token: NSObjectProtocol?

        init(rootKey: String) { self.rootKey = rootKey }

        private var tabID: NSWindow.TabbingIdentifier { "qmd::\(rootKey)" }

        func attach(_ window: NSWindow) {
            window.tabbingMode = .preferred
            window.tabbingIdentifier = tabID

            // only windows rooted at the SAME folder are tab siblings.
            // (don't filter on isVisible — it's false during rapid window creation)
            let siblings = Self.registry.allObjects.filter {
                $0 !== window && $0.tabbingIdentifier == tabID
            }
            Self.log.debug("attach root=\(self.rootKey, privacy: .public) sameRootSiblings=\(siblings.count)")
            Self.registry.add(window)

            if let host = siblings.first {
                // a qmd window already exists -> tab into it (share its frame).
                // Note: a standalone window is already in its own tab-group-of-one,
                // so guard on "different group", not "no group".
                if window.tabGroup !== host.tabGroup {
                    // match the host's frame BEFORE tabbing so adding a tab never
                    // resizes the group (otherwise the new window's default size wins)
                    let hostFrame = host.frame
                    window.setFrame(hostFrame, display: false)
                    host.addTabbedWindow(window, ordered: .above)
                    window.setFrame(hostFrame, display: false)
                    window.makeKeyAndOrderFront(nil)
                    Self.log.debug("tabbed into host; group count=\(host.tabbedWindows?.count ?? -1)")
                }
            } else {
                // first window -> restore saved size
                if let d = UserDefaults.standard.dictionary(forKey: Self.sizeKey),
                   let w = d["w"] as? Double, let h = d["h"] as? Double, w > 300, h > 200 {
                    var f = window.frame
                    f.size = NSSize(width: w, height: h)
                    window.setFrame(f, display: true)
                }
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
