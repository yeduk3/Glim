import SwiftUI
import AppKit

/// Preserves the sidebar's scroll position across an open.
///
/// Opening a file spawns a new document tab, and the new tab's sidebar `List` is a fresh
/// `NSOutlineView` that renders at the top — so a click made while scrolled down would
/// snap the sidebar back to the start. We snapshot the current scroll offset (keyed by the
/// folder being browsed) right before opening, then restore it once the new tab's outline
/// view has laid out. The sidebar is never scrolled programmatically otherwise, so its
/// position only ever moves by a direct user scroll (this just carries that position over).
enum SidebarScroll {
    private static var store: [String: CGFloat] = [:]

    private static func key(_ root: URL?) -> String? { root?.standardizedFileURL.path }

    /// Remembers where `outline`'s sidebar is scrolled, under `root`. Call right before opening.
    static func capture(outline: NSView?, root: URL?) {
        guard let k = key(root), let clip = outline?.enclosingScrollView?.contentView else { return }
        store[k] = clip.bounds.origin.y
    }

    /// Restores the remembered offset for `root` onto the sidebar reachable from `anchor`'s
    /// window. Retries across runloop turns until the outline view exists and its content is
    /// tall enough to scroll (the new tab's list lays out asynchronously).
    static func scheduleRestore(near anchor: NSView, root: URL?, tries: Int = 12) {
        guard let k = key(root), let y = store[k], y > 0 else { return }
        DispatchQueue.main.async { [weak anchor] in
            guard let anchor, let window = anchor.window else { return }
            guard let outline = findOutline(window.contentView),
                  let scroll = outline.enclosingScrollView,
                  let doc = scroll.documentView else {
                if tries > 0 { scheduleRestore(near: anchor, root: root, tries: tries - 1) }
                return
            }
            let clip = scroll.contentView
            let maxY = doc.frame.height - clip.bounds.height
            guard maxY > 0 else {                       // not scrollable yet (or no longer) -> wait/skip
                if tries > 0 { scheduleRestore(near: anchor, root: root, tries: tries - 1) }
                return
            }
            var origin = clip.bounds.origin
            origin.y = min(y, maxY)
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }
    }

    private static func findOutline(_ view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is NSTableView { return view }   // NSOutlineView is an NSTableView
        for sub in view.subviews { if let found = findOutline(sub) { return found } }
        return nil
    }
}

/// Drops an invisible probe into the sidebar so `SidebarScroll` can restore the saved offset
/// once this tab's outline view is in a window and laid out.
struct SidebarScrollRestorer: NSViewRepresentable {
    let root: URL?

    func makeNSView(context: Context) -> NSView {
        let v = ProbeView()
        v.onWindow = { [weak v] in
            guard let v else { return }
            SidebarScroll.scheduleRestore(near: v, root: v.rootURL)
        }
        v.rootURL = root
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProbeView)?.rootURL = root
    }

    final class ProbeView: NSView {
        var onWindow: (() -> Void)?
        var rootURL: URL?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onWindow?() }
        }
    }
}
