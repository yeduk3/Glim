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

// Focused value so the menu's Find commands reach the focused window's controller.
private struct FindControllerKey: FocusedValueKey { typealias Value = FindController }

extension FocusedValues {
    var findController: FindController? {
        get { self[FindControllerKey.self] }
        set { self[FindControllerKey.self] = newValue }
    }
}
