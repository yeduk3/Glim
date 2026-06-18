import SwiftUI

/// Drives the in-file find bar. Both the rendered (`MarkdownWebView`) and raw
/// (`MarkdownEditor`) views observe it and perform the search in their own way.
final class FindController: ObservableObject {
    @Published var isVisible = false
    @Published var query = ""
    @Published var caseSensitive = false
    /// Bumped to request a jump to the next/previous match. `backwards` selects direction.
    @Published var navToken = 0
    @Published var backwards = false
    /// Result text shown in the bar, e.g. "3/12" or "Not found".
    @Published var status = ""
    /// Bumped to pull keyboard focus back into the find field (⌘F when already open).
    @Published var focusPulse = 0

    func show() {
        isVisible = true
        focusPulse &+= 1
    }
    func hide() {
        isVisible = false
        query = ""
        status = ""
    }
    func next() { backwards = false; navToken &+= 1 }
    func prev() { backwards = true; navToken &+= 1 }
}

/// Carries the top-visible source line between the rendered and raw views so the
/// ⌘E switch lands on the same place. `source` records which view last set it;
/// the incoming view scrolls to `line` only when the *other* view set it.
final class ScrollSync: ObservableObject {
    private(set) var line = 0
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

/// Remembers the raw-editor caret position for the open file so switching to the rendered
/// view (or another tab) and back restores the cursor instead of resetting to the top.
/// Tab-scoped: lives as long as the file's tab (ContentView) is open.
final class EditCursorStore: ObservableObject {
    /// Caret offset (UTF-16) to restore, or nil until the editor has reported one.
    var location: Int?
}

/// Watches the open file's folder and reconciles external edits with the editor: adopts
/// changes silently when the buffer has no unsaved divergence, and raises a reload/keep-mine
/// prompt when both the file and the buffer changed (so an external edit can't clobber
/// unsaved work, and our own autosave isn't mistaken for an external change).
@MainActor
final class FileSync: ObservableObject {
    /// External disk content awaiting a reload/keep decision; nil = no conflict banner.
    @Published var conflict: String?

    /// Read the live editor text. Set by ContentView.
    var currentText: () -> String = { "" }
    /// Replace the editor text with reloaded disk content. Set by ContentView.
    var applyReload: (String) -> Void = { _ in }

    private lazy var watcher = DirectoryWatcher { [weak self] in self?.recheck() }
    private var url: URL?
    private var snapshot: String?      // content last in sync with disk
    private var acknowledged: String?  // disk content the user chose to keep-mine over

    /// Begin watching `url`'s folder (no-op if already watching that file).
    func start(url: URL?) {
        guard let url, url != self.url else { return }
        self.url = url
        snapshot = currentText()
        // ponytail: watches the whole parent dir (one extra FSEvents stream) and re-reads
        // one file per event — cheap for markdown; swap to a file-scoped watch if it bites.
        watcher.start(url: url.deletingLastPathComponent())
    }

    private func recheck() {
        guard let url, let onDisk = try? String(contentsOf: url, encoding: .utf8) else { return }
        let text = currentText()
        if onDisk == text {                  // already matches (our own save / no real change)
            snapshot = onDisk; acknowledged = nil
            if conflict != nil { conflict = nil }
            return
        }
        if onDisk == acknowledged { return } // user already chose to keep theirs over this
        if text == snapshot {                // no local edits -> adopt the external change
            snapshot = onDisk
            applyReload(onDisk)
        } else {                             // both diverged -> ask the user
            conflict = onDisk
        }
    }

    func reload() {
        guard let c = conflict else { return }
        snapshot = c; acknowledged = nil; conflict = nil
        applyReload(c)
    }

    func keepMine() {
        acknowledged = conflict
        conflict = nil
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
