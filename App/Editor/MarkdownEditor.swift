import SwiftUI
import AppKit

struct MarkdownEditor: View {
    @Binding var text: String
    @ObservedObject var find: FindController
    var sync: ScrollSync
    var initialLine: Int?
    var focusPulse: Int = 0
    var fontScale: Double = 1
    var fullWidth: Bool = false
    var selection: SelectionController
    var cursor: EditCursorStore
    @State private var issues: [LintIssue] = []

    var body: some View {
        VStack(spacing: 0) {
            RawTextView(text: $text, issues: issues, find: find, sync: sync,
                        initialLine: initialLine, focusPulse: focusPulse, fontScale: fontScale,
                        fullWidth: fullWidth, selection: selection, cursor: cursor)
            if !issues.isEmpty {
                Divider()
                LintBar(issues: issues)
            }
        }
        .onAppear { issues = MarkdownLinter.lint(text) }
        .onChange(of: text) { _, new in issues = MarkdownLinter.lint(new) }
    }
}

private struct LintBar: View {
    let issues: [LintIssue]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Label("\(issues.count)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption.bold())
                ForEach(issues.prefix(40)) { issue in
                    Text("L\(issue.line): \(issue.message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .background(.bar)
    }
}

private struct RawTextView: NSViewRepresentable {
    @Binding var text: String
    var issues: [LintIssue]
    var find: FindController
    var sync: ScrollSync
    var initialLine: Int?
    var focusPulse: Int = 0
    var fontScale: Double = 1
    var fullWidth: Bool = false
    var selection: SelectionController
    var cursor: EditCursorStore

    /// Base text measure (points) used when full-width is off, before zoom scaling.
    static let maxMeasure: CGFloat = 720

    /// Monospace point size at the current zoom (13pt is the 1.0 baseline).
    private var fontSize: CGFloat { 13 * CGFloat(fontScale) }

    /// Capped text measure at the current zoom (scales so zoomed text isn't cramped).
    private var measure: CGFloat { Self.maxMeasure * CGFloat(fontScale) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.string = text

        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        context.coordinator.lastFontSize = fontSize
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.allowsUndo = true
        tv.usesFindBar = false // app provides its own unified find bar
        tv.textContainerInset = NSSize(width: 8, height: 12)
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor

        // soft wrap to the view width
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true

        context.coordinator.textView = tv

        // report scroll position (top source line) for view<->edit sync
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        context.coordinator.observeScroll(clip)

        // full-width: off caps the measure and centers it via horizontal inset, on
        // fills the view width (the original behavior). Recenter when the view resizes.
        context.coordinator.fullWidth = fullWidth
        context.coordinator.measure = measure
        context.coordinator.observeFrame(scroll)

        context.coordinator.lastFocusPulse = focusPulse

        // On entering edit mode: take keyboard focus and land the caret at the line
        // that was at the top of the rendered view (the scroll-sync target), so focus
        // sits at the right height instead of jumping to the document top.
        DispatchQueue.main.async {
            let coord = context.coordinator
            coord.applyWidth(scroll)
            coord.focusEditor()
            // Restore the caret saved earlier this session (mode switch / tab revisit); only
            // fall back to the scroll-sync line on the first entry, when none is saved yet.
            if let loc = cursor.location {
                coord.placeCaret(atOffset: loc)
            } else if let line = initialLine {
                coord.placeCaret(atLine: line)
                coord.scroll(toLine: line)
            }
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
            context.coordinator.matchesStale = true
        }
        if context.coordinator.lastFontSize != fontSize {
            context.coordinator.lastFontSize = fontSize
            tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        let widthChanged = context.coordinator.fullWidth != fullWidth
        context.coordinator.fullWidth = fullWidth
        context.coordinator.measure = measure
        context.coordinator.applyWidth(nsView, animated: widthChanged)
        applyUnderlines(tv)
        context.coordinator.applyFind(find)
        if focusPulse != context.coordinator.lastFocusPulse {
            context.coordinator.lastFocusPulse = focusPulse
            DispatchQueue.main.async { context.coordinator.focusEditor() }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.reportNow() // capture final scroll position before the view goes away
    }

    private func applyUnderlines(_ tv: NSTextView) {
        guard let lm = tv.layoutManager else { return }
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        let style = NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue
        for issue in issues {
            let r = issue.range
            guard r.length > 0, NSMaxRange(r) <= full.length else { continue }
            lm.addTemporaryAttributes([
                .underlineStyle: style,
                .underlineColor: NSColor.systemOrange
            ], forCharacterRange: r)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RawTextView
        weak var textView: NSTextView?
        var lastFocusPulse = 0
        var lastFontSize: CGFloat = 13
        var fullWidth = false
        var measure: CGFloat = RawTextView.maxMeasure
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var widthAnimTimer: Timer?
        private var programmatic = false
        private var reportScheduled = false

        // find state
        private var matches: [NSRange] = []
        private var current = 0
        var matchesStale = false
        private var lastVisible = false
        private var lastQuery = ""
        private var lastCase = false
        private var lastNav = 0

        init(_ parent: RawTextView) { self.parent = parent }

        deinit {
            if let o = boundsObserver { NotificationCenter.default.removeObserver(o) }
            if let o = frameObserver { NotificationCenter.default.removeObserver(o) }
            widthAnimTimer?.invalidate()
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            matchesStale = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let r = tv.selectedRange()
            parent.cursor.location = r.location   // remembered for view<->edit / tab revisits
            // Count grapheme clusters (user-visible characters), not UTF-16 units, so
            // emoji/combining marks read as one. Empty selection -> 0 -> bar hides.
            let n = r.length == 0 ? 0 : (tv.string as NSString).substring(with: r).count
            parent.selection.report(n)
        }

        // MARK: width

        /// Recompute centering whenever the scroll view resizes (full-width-off mode
        /// keeps the measure centered as the window grows/shrinks).
        func observeFrame(_ scroll: NSScrollView) {
            scroll.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self, weak scroll] _ in
                guard let self, let scroll else { return }
                self.applyWidth(scroll)
            }
        }

        /// Off: cap the text measure and center it via a horizontal container inset.
        /// On: fill the available width (8pt gutter), the original editor behavior.
        /// `animated` (toggle only) tweens the inset so the column grows/shrinks
        /// smoothly; resize/zoom/initial layout snap instantly.
        func applyWidth(_ scroll: NSScrollView, animated: Bool = false) {
            guard let tv = scroll.documentView as? NSTextView else { return }
            let viewW = scroll.contentSize.width
            let target = fullWidth ? 8 : max(8, (viewW - measure) / 2)
            let start = tv.textContainerInset.width
            widthAnimTimer?.invalidate(); widthAnimTimer = nil
            guard abs(target - start) > 0.5 else { return }
            guard animated else { return setInset(tv, target) }

            let duration = 0.22, startTime = Date()
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak tv] t in
                guard let self, let tv else { t.invalidate(); return }
                let p = min(1, Date().timeIntervalSince(startTime) / duration)
                let eased = p * p * (3 - 2 * p)   // smoothstep
                self.setInset(tv, start + (target - start) * CGFloat(eased))
                if p >= 1 { t.invalidate(); self.widthAnimTimer = nil }
            }
            widthAnimTimer = timer
            // .common so it keeps ticking during scroll/resize event tracking.
            RunLoop.main.add(timer, forMode: .common)
        }

        private func setInset(_ tv: NSTextView, _ w: CGFloat) {
            tv.textContainerInset = NSSize(width: w, height: tv.textContainerInset.height)
            if let tc = tv.textContainer { tv.layoutManager?.textContainerChangedGeometry(tc) }
        }

        // MARK: scroll sync

        func observeScroll(_ clip: NSView) {
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.reportScroll()
            }
        }

        private func reportScroll() {
            guard !programmatic, !reportScheduled else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                if !self.programmatic { self.parent.sync.report(line: self.topLine(), from: .edit) }
            }
        }

        /// Report the current top line immediately (used at teardown, before ⌘E swaps views).
        func reportNow() {
            guard !programmatic else { return }
            parent.sync.report(line: topLine(), from: .edit)
        }

        /// 0-based source line shown at the top of the visible area.
        private func topLine() -> Int {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return 0 }
            let vr = tv.visibleRect
            let y = max(0, vr.origin.y - tv.textContainerInset.height) + 1
            let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: y), in: tc)
            let char = lm.characterIndexForGlyph(at: glyph)
            let s = tv.string as NSString
            let head = s.substring(to: min(char, s.length))
            return head.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        }

        /// Makes the text view first responder so edit mode is immediately typable.
        func focusEditor() {
            guard let tv = textView else { return }
            tv.window?.makeFirstResponder(tv)
        }

        /// Place the (empty) caret at UTF-16 `offset` (clamped) and scroll it into view.
        func placeCaret(atOffset offset: Int) {
            guard let tv = textView else { return }
            let loc = max(0, min(offset, (tv.string as NSString).length))
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            tv.scrollRangeToVisible(NSRange(location: loc, length: 0))
        }

        /// Place the (empty) caret at the start of 0-based source `line`.
        func placeCaret(atLine line: Int) {
            guard let tv = textView else { return }
            let char = charIndex(forLine: line, in: tv.string as NSString)
            tv.setSelectedRange(NSRange(location: char, length: 0))
        }

        /// Character offset of the start of 0-based source `line`.
        private func charIndex(forLine line: Int, in s: NSString) -> Int {
            var idx = 0, cur = 0
            while cur < line && idx < s.length {
                let lr = s.lineRange(for: NSRange(location: idx, length: 0))
                let nxt = NSMaxRange(lr)
                if nxt <= idx { break }
                idx = nxt; cur += 1
            }
            return min(idx, s.length)
        }

        /// Scroll so 0-based source `line` sits at the top.
        func scroll(toLine line: Int) {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer,
                  let clip = tv.enclosingScrollView?.contentView else { return }
            let s = tv.string as NSString
            let char = charIndex(forLine: line, in: s)
            lm.ensureLayout(for: tc)
            let gr = lm.glyphRange(forCharacterRange: NSRange(location: char, length: 0), actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: gr, in: tc)
            let targetY = max(0, rect.origin.y + tv.textContainerInset.height)
            programmatic = true
            clip.scroll(to: NSPoint(x: 0, y: targetY))
            tv.enclosingScrollView?.reflectScrolledClipView(clip)
            DispatchQueue.main.async { [weak self] in self?.programmatic = false }
        }

        // MARK: find

        func applyFind(_ find: FindController) {
            guard let tv = textView else { return }
            let becameVisible = find.isVisible && !lastVisible
            let queryChanged = find.query != lastQuery || find.caseSensitive != lastCase
            let navChanged = find.navToken != lastNav
            let wasVisible = lastVisible
            lastVisible = find.isVisible
            lastQuery = find.query
            lastCase = find.caseSensitive
            lastNav = find.navToken

            guard find.isVisible else {
                if wasVisible { clearHighlights(tv) }
                return
            }
            guard becameVisible || queryChanged || navChanged else { return } // ignore status echoes
            guard !find.query.isEmpty else {
                matches = []; clearHighlights(tv); setStatus(find, ""); return
            }

            if becameVisible || queryChanged || matchesStale {
                recompute(tv)
                if becameVisible || queryChanged {
                    let caret = tv.selectedRange().location
                    current = matches.firstIndex(where: { $0.location >= caret }) ?? 0
                }
            }
            if navChanged && !matches.isEmpty {
                if find.backwards { current = (current - 1 + matches.count) % matches.count }
                else { current = (current + 1) % matches.count }
            }
            current = matches.isEmpty ? 0 : min(current, matches.count - 1)
            highlight(tv)
            if !matches.isEmpty { jumpToCurrent(tv) }
            setStatus(find, matches.isEmpty ? "Not found" : "\(current + 1)/\(matches.count)")
        }

        private func recompute(_ tv: NSTextView) {
            matches = []
            matchesStale = false
            let q = lastQuery
            guard !q.isEmpty else { return }
            let s = tv.string as NSString
            let opts: NSString.CompareOptions = lastCase ? [] : [.caseInsensitive]
            var loc = 0
            while loc < s.length {
                let r = s.range(of: q, options: opts, range: NSRange(location: loc, length: s.length - loc))
                if r.location == NSNotFound { break }
                matches.append(r)
                loc = r.location + max(1, r.length)
            }
        }

        private func highlight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            for (i, r) in matches.enumerated() where NSMaxRange(r) <= full.length {
                let color = (i == current)
                    ? NSColor.systemOrange.withAlphaComponent(0.7)
                    : NSColor.systemYellow.withAlphaComponent(0.45)
                lm.addTemporaryAttributes([.backgroundColor: color], forCharacterRange: r)
            }
        }

        private func clearHighlights(_ tv: NSTextView) {
            guard let lm = tv.layoutManager else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        }

        private func jumpToCurrent(_ tv: NSTextView) {
            guard current < matches.count else { return }
            let r = matches[current]
            tv.setSelectedRange(r)
            programmatic = true
            tv.scrollRangeToVisible(r)
            DispatchQueue.main.async { [weak self] in self?.programmatic = false }
        }

        private func setStatus(_ find: FindController, _ s: String) {
            if find.status != s { find.status = s }
        }
    }
}
