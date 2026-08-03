import SwiftUI
import MarkdownEditorKit

/// Carries the top-visible source line between the rendered and raw views so the
/// ⌘E switch lands on the same place. `source` records which view last set it;
/// the incoming view scrolls to `line` only when the *other* view set it.
final class ScrollSync: ObservableObject {
    /// Published so the outline panel can highlight the current section as you scroll.
    /// `report()` is only ever called on the main thread (WKScriptMessage delivery and the
    /// editor's main-queue scroll hop), so the publish is main-thread safe.
    @Published private(set) var line = 0
    /// True once either view has reported a position; until then there's nothing to restore.
    private(set) var primed = false

    func report(line: Int, from: EditorMode) {
        self.line = max(0, line)
        self.primed = true
    }

    /// Line the `incoming` view should restore to (nil until a position exists). The
    /// incoming view always restores the shared line — including when it set it last,
    /// which is a no-op — so a plain ⌘E toggle never snaps back to the top.
    func target(for incoming: EditorMode) -> Int? {
        primed ? line : nil
    }
}

/// Pulse asking the active tab's detail view (rendered web view or raw editor) to
/// become first responder. ContentView owns one; ⌘⇧E-toggle, ⌘↓, and click bump it.
final class DetailFocusController: ObservableObject {
    @Published var pulse = 0
    func focus() { pulse &+= 1 }
}

/// Character count of the current text selection, fed by whichever detail view is
/// active (rendered web view or raw editor). 0 means nothing selected -> the count
/// readout hides. ContentView owns one per tab.
final class SelectionController: ObservableObject {
    @Published var count = 0
    func report(_ n: Int) { if n != count { count = n } }
    func clear() { if count != 0 { count = 0 } }
}

/// Single source of truth for the sidebar's expanded/collapsed state, shared across all
/// tabs and windows. Each tab's NavigationSplitView is a separate view with its own
/// column-visibility binding; pointing them all at this one object keeps the sidebar
/// consistent as you switch tabs (and a newly opened tab inherits it). Per-process.
final class SidebarVisibility: ObservableObject {
    static let shared = SidebarVisibility()
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    private init() {}
}

/// Folders the sidebar shows expanded, shared across all tabs/windows so the disclosure
/// state is one source of truth (keyed by absolute folder URL — unique per path, so
/// different windows' trees don't collide). Per-process.
final class SidebarExpansion: ObservableObject {
    static let shared = SidebarExpansion()
    @Published var expanded: Set<URL> = []
    private init() {}
}

/// Carries the browsing root from the tab that triggers an open to the destination tab,
/// so opening a file in a SUBFOLDER tabs into the same window and keeps the same sidebar
/// root — instead of re-rooting at the subfolder and spawning a new window. Matched by the
/// opened file's URL, like OpenFocusRouter. Stale entries are harmless (self-correcting).
final class OpenRootRouter {
    static let shared = OpenRootRouter()
    var roots: [URL: URL] = [:]
    private init() {}
}

/// Which side takes keyboard focus after a sidebar-initiated open.
enum SidebarFocusTarget { case sidebar, detail }

/// A focus request that must outlive the `openDocument` tab switch. Opening a file can
/// activate a *different* tab (a separate ContentView), so the intent can't be passed
/// through SwiftUI state — it's parked here and claimed by the destination tab, matched
/// by URL.
struct PendingFocus { let url: URL; let target: SidebarFocusTarget }

final class OpenFocusRouter {
    static let shared = OpenFocusRouter()
    var pending: PendingFocus?
    private init() {}
}

/// Watches the open file's folder and keeps the editor aligned with the file on disk.
/// When an external edit is detected, the disk version is authoritative and replaces the
/// current buffer immediately. This keeps the editor predictable for workflows where another
/// app, sync service, or formatter owns the file.
@MainActor
final class FileSync: ObservableObject {
    /// Read the live editor text. Set by ContentView.
    var currentText: () -> String = { "" }
    /// Replace the editor text with reloaded disk content. Set by ContentView.
    var applyReload: (String) -> Void = { _ in }

    private lazy var watcher = DirectoryWatcher { [weak self] in self?.recheck() }
    private var url: URL?

    /// Begin watching `url`'s folder (no-op if already watching that file).
    func start(url: URL?) {
        guard let url, url != self.url else { return }
        self.url = url
        // ponytail: watches the whole parent dir (one extra FSEvents stream) and re-reads
        // one file per event — cheap for markdown; swap to a file-scoped watch if it bites.
        watcher.start(url: url.deletingLastPathComponent())
    }

    private func recheck() {
        guard let url, let onDisk = try? String(contentsOf: url, encoding: .utf8) else { return }
        let text = currentText()
        if onDisk == text {                  // already matches (our own save / no real change)
            return
        }

        // The disk version is authoritative. Replace local edits immediately rather than
        // asking which version to keep; the next check then sees matching content and stops.
        applyReload(onDisk)
    }
}

// Focused value so the menu's Find commands reach the focused window's controller.
private struct FindControllerKey: FocusedValueKey { typealias Value = FindController }

extension FocusedValues {
    var findController: FindController? {
        get { self[FindControllerKey.self] }
        set { self[FindControllerKey.self] = newValue }
    }
}
