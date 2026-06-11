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

// Focused value so the menu's Find commands reach the focused window's controller.
private struct FindControllerKey: FocusedValueKey { typealias Value = FindController }

extension FocusedValues {
    var findController: FindController? {
        get { self[FindControllerKey.self] }
        set { self[FindControllerKey.self] = newValue }
    }
}
