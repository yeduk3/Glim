import SwiftUI
import AppKit
import MarkdownEditorKit

/// The two editing surfaces Glim offers. `inline` keeps the Markdown source intact,
/// but presents inactive blocks as a quiet document and reveals their delimiters only
/// when the caret enters them — the small, high-value part of Edmund's interaction model.
enum EditorSurface: String {
    case inline
    case source
}

/// Edmund-inspired WYSIWYG-style editing surface for Glim.
///
/// This is intentionally a presentation layer, not a second document model: the bound
/// value is always the original Markdown source. That keeps View/Edit round-trips,
/// external file watching, undo, and image paths compatible with the existing editor.
/// Markdown delimiters are therefore hidden in the visual surface even while the caret is
/// inside a formatted span; Source remains the explicit escape hatch for syntax work.
struct InlineMarkdownEditor: View {
    @Binding var text: String
    var config: EditorConfig
    var find: FindController?
    var initialLine: Int?
    var focusPulse: Int
    var typewriterMode: Bool
    var cursor: EditCursorStore?
    var buffer: EditorBuffer?
    var imagePolicy: ImagePolicy?
    var docDirectory: URL?
    var jumpRequest: (token: Int, line: Int)?
    var onEvent: (EditorEvent) -> Void

    @State private var issues: [InlineLintIssue] = []
    @State private var jumpToken = 0
    @State private var jumpRange: NSRange?
    @State private var lastRequestToken: Int?

    init(text: Binding<String>,
         config: EditorConfig = .init(),
         find: FindController? = nil,
         initialLine: Int? = nil,
         focusPulse: Int = 0,
         typewriterMode: Bool = true,
         cursor: EditCursorStore? = nil,
         buffer: EditorBuffer? = nil,
         imagePolicy: ImagePolicy? = nil,
         docDirectory: URL? = nil,
         jumpRequest: (token: Int, line: Int)? = nil,
         onEvent: @escaping (EditorEvent) -> Void = { _ in }) {
        _text = text
        self.config = config
        self.find = find
        self.initialLine = initialLine
        self.focusPulse = focusPulse
        self.typewriterMode = typewriterMode
        self.cursor = cursor
        self.buffer = buffer
        self.imagePolicy = imagePolicy
        self.docDirectory = docDirectory
        self.jumpRequest = jumpRequest
        self.onEvent = onEvent
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            if config.lintEnabled && !issues.isEmpty {
                Divider()
                InlineLintBar(issues: issues, onJump: jump)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { relint(text) }
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            relint(text)
        }
        .onChange(of: jumpRequest?.token) { _, _ in handleJumpRequest() }
    }

    @ViewBuilder
    private var content: some View {
        if let find {
            InlineFindObservingEditor(find: find, text: $text, issues: issues,
                                       initialLine: initialLine, focusPulse: focusPulse,
                                       typewriterMode: typewriterMode, config: config,
                                       cursor: cursor, buffer: buffer, imagePolicy: imagePolicy,
                                       docDirectory: docDirectory,
                                       jumpToken: jumpToken, jumpRange: jumpRange,
                                       onEvent: onEvent)
        } else {
            InlineNativeEditor(text: $text, issues: issues, find: nil,
                               initialLine: initialLine, focusPulse: focusPulse,
                               typewriterMode: typewriterMode, config: config,
                               cursor: cursor, buffer: buffer, imagePolicy: imagePolicy,
                               docDirectory: docDirectory,
                               jumpToken: jumpToken, jumpRange: jumpRange,
                               onEvent: onEvent)
        }
    }

    private func handleJumpRequest() {
        guard let request = jumpRequest, request.token != lastRequestToken else { return }
        lastRequestToken = request.token
        jumpRange = NSRange(location: Self.offset(ofLine: request.line, in: text), length: 0)
        jumpToken &+= 1
    }

    private static func offset(ofLine line: Int, in text: String) -> Int {
        guard line > 0 else { return 0 }
        let ns = text as NSString
        var index = 0
        var current = 0
        while current < line && index < ns.length {
            let range = ns.lineRange(for: NSRange(location: index, length: 0))
            let next = NSMaxRange(range)
            guard next > index else { break }
            index = next
            current += 1
        }
        return min(index, ns.length)
    }

    private func relint(_ value: String) {
        issues = config.lintEnabled ? InlineMarkdownLinter.lint(value) : []
    }

    private func jump(to issue: InlineLintIssue) {
        jumpRange = issue.range
        jumpToken &+= 1
    }
}

private struct InlineFindObservingEditor: View {
    @ObservedObject var find: FindController
    @Binding var text: String
    var issues: [InlineLintIssue]
    var initialLine: Int?
    var focusPulse: Int
    var typewriterMode: Bool
    var config: EditorConfig
    var cursor: EditCursorStore?
    var buffer: EditorBuffer?
    var imagePolicy: ImagePolicy?
    var docDirectory: URL?
    var jumpToken: Int
    var jumpRange: NSRange?
    var onEvent: (EditorEvent) -> Void

    var body: some View {
        InlineNativeEditor(text: $text, issues: issues, find: find,
                           initialLine: initialLine, focusPulse: focusPulse,
                           typewriterMode: typewriterMode, config: config,
                           cursor: cursor, buffer: buffer, imagePolicy: imagePolicy,
                           docDirectory: docDirectory,
                           jumpToken: jumpToken, jumpRange: jumpRange,
                           onEvent: onEvent)
    }
}

private struct InlineNativeEditor: NSViewRepresentable {
    @Binding var text: String
    var issues: [InlineLintIssue]
    var find: FindController?
    var initialLine: Int?
    var focusPulse: Int
    var typewriterMode: Bool
    var config: EditorConfig
    var cursor: EditCursorStore?
    var buffer: EditorBuffer?
    var imagePolicy: ImagePolicy?
    var docDirectory: URL?
    var jumpToken: Int
    var jumpRange: NSRange?
    var onEvent: (EditorEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.autoresizingMask = [.width, .height]

        let contentSize = scroll.contentSize
        let size = NSSize(width: max(1, contentSize.width), height: max(1, contentSize.height))
        let storage = buffer?.textStorage ?? NSTextStorage()
        if storage.string != text {
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        }
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: size.width,
                                                       height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = InlineMarkdownTextView(frame: NSRect(origin: .zero, size: size),
                                         textContainer: container)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.delegate = context.coordinator
        tv.imagePolicy = imagePolicy
        tv.onTaskToggle = { [weak coordinator = context.coordinator] line in
            coordinator?.toggleTask(at: line)
        }
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 24)
        tv.textColor = .labelColor
        tv.backgroundColor = .textBackgroundColor
        tv.insertionPointColor = .controlAccentColor
        tv.drawsBackground = true

        context.coordinator.textView = tv
        context.coordinator.lastNativeText = text
        context.coordinator.typewriterMode = typewriterMode
        context.coordinator.fullWidth = config.fullWidth
        context.coordinator.measure = config.maxMeasure * CGFloat(config.fontScale)
        context.coordinator.observeScroll(scroll.contentView)
        context.coordinator.observeFrame(scroll)
        context.coordinator.applyPresentation(to: tv)
        context.coordinator.applyUnderlines(to: tv)
        context.coordinator.lastFocusPulse = focusPulse
        context.coordinator.lastJumpToken = jumpToken
        context.coordinator.lastReplaceToken = find?.replaceToken ?? 0

        scroll.documentView = tv
        DispatchQueue.main.async {
            context.coordinator.applyWidth(to: scroll)
            context.coordinator.focusEditor()
            if let location = context.coordinator.savedCaret {
                context.coordinator.placeCaret(atOffset: location)
            } else if let initialLine {
                context.coordinator.placeCaret(atLine: initialLine)
                context.coordinator.scroll(toLine: initialLine)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? InlineMarkdownTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        tv.imagePolicy = imagePolicy
        tv.onTaskToggle = { [weak coordinator] line in coordinator?.toggleTask(at: line) }
        coordinator.typewriterMode = typewriterMode

        if InlineTextSync.shouldApplyExternalText(bindingText: text,
                                                   lastNativeText: coordinator.lastNativeText,
                                                   hasMarkedText: tv.hasMarkedText()),
           tv.string != text {
            coordinator.isApplying = true
            tv.textStorage?.replaceCharacters(in: NSRange(location: 0,
                                                           length: tv.textStorage?.length ?? 0),
                                               with: text)
            coordinator.isApplying = false
            coordinator.lastNativeText = text
            coordinator.applyPresentation(to: tv)
        }

        let widthChanged = coordinator.fullWidth != config.fullWidth
        coordinator.fullWidth = config.fullWidth
        coordinator.measure = config.maxMeasure * CGFloat(config.fontScale)
        coordinator.applyWidth(to: scroll, animated: widthChanged)
        coordinator.applyUnderlines(to: tv)
        coordinator.applyFind(find)

        if focusPulse != coordinator.lastFocusPulse {
            coordinator.lastFocusPulse = focusPulse
            DispatchQueue.main.async { coordinator.focusEditor() }
        }
        if jumpToken != coordinator.lastJumpToken {
            coordinator.lastJumpToken = jumpToken
            if let jumpRange {
                DispatchQueue.main.async { coordinator.jump(to: jumpRange) }
            }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.reportNow()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineNativeEditor
        weak var textView: InlineMarkdownTextView?
        var lastNativeText = ""
        var lastFocusPulse = 0
        var lastJumpToken = 0
        var lastReplaceToken = 0
        var typewriterMode = true
        var fullWidth = false
        var measure: CGFloat = 720
        var isApplying = false
        var savedCaret: Int? { parent.cursor?.location }

        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var matches: [NSRange] = []
        private var currentMatch = 0
        private var lastQuery = ""
        private var lastCaseSensitive = false
        private var lastNavToken = 0
        private var lastFindVisible = false
        private var matchesStale = false

        init(_ parent: InlineNativeEditor) {
            self.parent = parent
            self.lastNativeText = parent.text
        }

        deinit {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            parent.buffer?.undoManager ?? view.window?.undoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? InlineMarkdownTextView,
                  !tv.hasMarkedText(), !isApplying else { return }
            let snapshot = InlineTextSync.bindingSnapshot(tv.string)
            lastNativeText = snapshot
            parent.text = snapshot
            matchesStale = true
            applyPresentation(to: tv)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let tv = textView as? InlineMarkdownTextView,
                  !tv.hasMarkedText(), selector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            let source = tv.string as NSString
            let selection = tv.selectedRange()
            let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
            var contentLength = lineRange.length
            if contentLength > 0,
               source.substring(with: NSRange(location: lineRange.location + contentLength - 1, length: 1)) == "\n" {
                contentLength -= 1
            }
            let line = source.substring(with: NSRange(location: lineRange.location, length: contentLength))
            guard let prefix = InlineMarkdownTextView.continuationPrefix(for: line) else { return false }
            if prefix.isEmpty {
                let range = NSRange(location: lineRange.location, length: contentLength)
                guard tv.shouldChangeText(in: range, replacementString: "") else { return true }
                tv.textStorage?.replaceCharacters(in: range, with: "")
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            } else {
                tv.insertText("\n" + prefix, replacementRange: selection)
            }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? InlineMarkdownTextView else { return }
            let selection = tv.selectedRange()
            parent.cursor?.location = selection.location
            let count = selection.length == 0 ? 0 : (tv.string as NSString).substring(with: selection).count
            parent.onEvent(.selection(count: count))
            applyPresentation(to: tv)
            if typewriterMode { centerCaret(in: tv) }
        }

        // MARK: Edmund-style presentation

        func applyPresentation(to tv: NSTextView) {
            guard !tv.hasMarkedText(), let storage = tv.textStorage else { return }
            let source = tv.string
            let ns = source as NSString
            let full = NSRange(location: 0, length: ns.length)
            let scale = CGFloat(parent.config.fontScale)
            let bodySize = 16 * scale
            let bodyFont = NSFont.systemFont(ofSize: bodySize, weight: .regular)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.45
            paragraph.paragraphSpacing = 8 * scale
            let imageDecorations = loadImageDecorations(in: source, scale: scale)

            storage.beginEditing()
            if full.length > 0 {
                storage.addAttributes([
                    .font: bodyFont,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.clear,
                    .paragraphStyle: paragraph
                ], range: full)
            }

            let caret = tv.selectedRange().location
            let activeLine = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
            if activeLine.length > 0 {
                storage.addAttribute(.backgroundColor,
                                     value: NSColor.controlAccentColor.withAlphaComponent(0.055),
                                     range: activeLine)
            }

            // Keep the source characters in place for editing, but reserve a document-like
            // line box for successfully resolved local images. The image itself is drawn by
            // a non-intercepting overlay view after TextKit has laid out the line.
            for decoration in imageDecorations {
                let lineRange = ns.lineRange(for: decoration.range)
                let imageStyle = paragraph.mutableCopy() as! NSMutableParagraphStyle
                let height = min(max(decoration.image.size.height * scale, 72 * scale),
                                 240 * scale)
                imageStyle.minimumLineHeight = max(imageStyle.minimumLineHeight, height + 12 * scale)
                imageStyle.maximumLineHeight = max(imageStyle.maximumLineHeight, height + 12 * scale)
                storage.addAttribute(.paragraphStyle, value: imageStyle, range: lineRange)
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.01),
                    .foregroundColor: NSColor.clear
                ], range: decoration.range)
            }

            // Block-level fills and spacing are applied before token styles so inline
            // emphasis can still override the base font without changing the source.
            for token in MarkdownSyntax.tokens(in: source) {
                let range = token.range
                guard range.length > 0, NSMaxRange(range) <= full.length else { continue }
                switch token.kind {
                case .headingMarker(let level):
                    styleDelimiter(storage, range: range)
                    let heading = NSFont.systemFont(ofSize: bodySize * headingScale(level),
                                                    weight: .semibold)
                    storage.addAttribute(.font, value: heading, range: range)
                case .headingText(let level):
                    let heading = NSFont.systemFont(ofSize: bodySize * headingScale(level),
                                                    weight: .semibold)
                    storage.addAttributes([
                        .font: heading,
                        .foregroundColor: NSColor.labelColor
                    ], range: range)
                    let headingStyle = paragraph.mutableCopy() as! NSMutableParagraphStyle
                    headingStyle.paragraphSpacingBefore = 18 * scale
                    headingStyle.paragraphSpacing = 6 * scale
                    storage.addAttribute(.paragraphStyle, value: headingStyle,
                                         range: NSMakeRange(range.location, range.length))
                case .emphasisMarker:
                    styleDelimiter(storage, range: range)
                case .boldText:
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: bodySize, weight: .bold),
                        .foregroundColor: NSColor.labelColor
                    ], range: range)
                case .italicText:
                    storage.addAttributes([
                        .font: italicFont(size: bodySize),
                        .foregroundColor: NSColor.labelColor
                    ], range: range)
                case .codeSpan:
                    storage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: bodySize * 0.9, weight: .regular),
                        .foregroundColor: NSColor.labelColor,
                        .backgroundColor: codeFill
                    ], range: range)
                case .fenceLine:
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: 0.01),
                        .foregroundColor: NSColor.clear,
                        .backgroundColor: codeFill
                    ], range: range)
                case .fencedCode:
                    storage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: bodySize * 0.9, weight: .regular),
                        .foregroundColor: NSColor.labelColor,
                        .backgroundColor: codeFill
                    ], range: range)
                case .linkBracketText:
                    storage.addAttributes([
                        .foregroundColor: NSColor.controlAccentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: NSColor.controlAccentColor
                    ], range: range)
                case .linkURL:
                    styleDelimiter(storage, range: range)
                case .quoteMarker:
                    let line = ns.lineRange(for: range)
                    storage.addAttribute(.backgroundColor,
                                         value: NSColor.controlAccentColor.withAlphaComponent(0.045),
                                         range: line)
                    styleDelimiter(storage, range: range)
                case .quoteText:
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                case .listMarker:
                    storage.addAttributes([
                        .foregroundColor: NSColor.controlAccentColor,
                        .font: NSFont.systemFont(ofSize: bodySize, weight: .semibold)
                    ], range: range)
                }
            }

            // The shared tokenizer intentionally keeps a quote's remainder as one block.
            // Re-scan only quoted lines so inline emphasis/code/links still feel rendered
            // without changing the package's source-editor grammar.
            styleQuoteInlineSyntax(storage, source: source)

            // Inline token styling above can touch the alt/link portions of a Markdown image;
            // the image overlay owns the complete source range, so quiet it again here.
            for decoration in imageDecorations {
                styleDelimiter(storage, range: decoration.range)
            }
            styleTaskLines(storage, source: source, scale: scale)
            styleImageSyntax(storage, source: source)
            let taskDecorations = loadTaskDecorations(in: source, scale: scale)
            for decoration in taskDecorations {
                // Keep the source's horizontal space so the native checkbox does not cover
                // the task text, but remove the literal [ ] / [x] glyphs from the surface.
                storage.addAttributes([
                    .foregroundColor: NSColor.clear,
                    .backgroundColor: NSColor.clear
                ], range: decoration.checkboxRange)
            }
            storage.endEditing()
            if let inline = tv as? InlineMarkdownTextView {
                inline.replaceImageDecorations(imageDecorations)
                inline.replaceTaskDecorations(taskDecorations) { [weak self] line in
                    self?.toggleTask(at: line)
                }
                positionImageDecorations(in: inline)
                positionTaskDecorations(in: inline)
            }
            applyUnderlines(to: tv)
        }

        private func styleQuoteInlineSyntax(_ storage: NSTextStorage, source: String) {
            let ns = source as NSString
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                                   options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
                let line = ns.substring(with: lineRange)
                let indentation = line.prefix { $0 == " " || $0 == "\t" }
                guard line.dropFirst(indentation.count).hasPrefix(">") else { return }
                let localRange = NSRange(location: 0, length: (line as NSString).length)
                if let regex = try? NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#) {
                    for match in regex.matches(in: line, range: localRange) {
                        self.styleDelimiter(storage, range: NSRange(location: lineRange.location + match.range.location,
                                                                     length: 2))
                        let content = match.range(at: 1)
                        storage.addAttributes([
                            .font: NSFont.systemFont(ofSize: 16 * CGFloat(self.parent.config.fontScale), weight: .bold),
                            .foregroundColor: NSColor.labelColor
                        ], range: NSRange(location: lineRange.location + content.location,
                                          length: content.length))
                        self.styleDelimiter(storage, range: NSRange(location: lineRange.location + NSMaxRange(match.range) - 2,
                                                                     length: 2))
                    }
                }

                if let regex = try? NSRegularExpression(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#) {
                    for match in regex.matches(in: line, range: localRange) {
                        let content = match.range(at: 1)
                        storage.addAttributes([
                            .font: self.italicFont(size: 16 * CGFloat(self.parent.config.fontScale)),
                            .foregroundColor: NSColor.labelColor
                        ], range: NSRange(location: lineRange.location + content.location,
                                          length: content.length))
                        self.styleDelimiter(storage, range: NSRange(location: lineRange.location + match.range.location,
                                                                     length: 1))
                        self.styleDelimiter(storage, range: NSRange(location: lineRange.location + NSMaxRange(match.range) - 1,
                                                                     length: 1))
                    }
                }

                if let regex = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#) {
                    for match in regex.matches(in: line, range: localRange) {
                        let content = match.range(at: 1)
                        storage.addAttributes([
                            .font: NSFont.monospacedSystemFont(ofSize: 14.4 * CGFloat(self.parent.config.fontScale), weight: .regular),
                            .foregroundColor: NSColor.labelColor,
                            .backgroundColor: self.codeFill
                        ], range: NSRange(location: lineRange.location + content.location,
                                          length: content.length))
                        self.styleDelimiter(storage, range: NSRange(location: lineRange.location + match.range.location,
                                                                     length: 1))
                        self.styleDelimiter(storage, range: NSRange(location: lineRange.location + NSMaxRange(match.range) - 1,
                                                                     length: 1))
                    }
                }

                if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) {
                    for match in regex.matches(in: line, range: localRange) {
                        let textRange = match.range(at: 1)
                        storage.addAttributes([
                            .foregroundColor: NSColor.controlAccentColor,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .underlineColor: NSColor.controlAccentColor
                        ], range: NSRange(location: lineRange.location + textRange.location,
                                          length: textRange.length))
                        self.styleDelimiter(storage, range: NSRange(location: lineRange.location + match.range.location,
                                                                     length: 1))
                        self.styleDelimiter(storage, range: NSRange(location: lineRange.location + NSMaxRange(textRange),
                                                                     length: 1))
                        self.styleDelimiter(storage, range: NSRange(location: lineRange.location + NSMaxRange(match.range) - 1,
                                                                     length: 1))
                        let urlRange = match.range(at: 2)
                        self.styleDelimiter(storage, range: NSRange(location: lineRange.location + urlRange.location,
                                                                     length: urlRange.length))
                        self.styleDelimiter(storage, range: NSRange(location: lineRange.location + urlRange.location - 1,
                                                                     length: 1))
                    }
                }
            }
        }

        private func styleImageSyntax(_ storage: NSTextStorage, source: String) {
            let ns = source as NSString
            guard let regex = try? NSRegularExpression(pattern: #"!\[(?:[^\]]*)\]\([^)]+\)"#) else { return }
            for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                // MarkdownSyntax already quiets [, ], (, the URL, and ); this handles the
                // image-specific leading bang so unresolved/remote images still read as alt text.
                styleDelimiter(storage, range: NSRange(location: match.range.location, length: 1))
            }
        }

        private func loadTaskDecorations(in source: String, scale: CGFloat) -> [InlineTaskDecoration] {
            let ns = source as NSString
            var lineNumber = 0
            var decorations: [InlineTaskDecoration] = []
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                                   options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
                defer { lineNumber += 1 }
                let line = ns.substring(with: lineRange)
                guard line.range(of: #"^\s*[-*+]\s+\[([ xX])\]"#, options: .regularExpression) != nil else {
                    return
                }
                let marker = line as NSString
                let open = marker.range(of: "[")
                guard open.location != NSNotFound else { return }
                let checkboxRange = NSRange(location: lineRange.location + open.location, length: 3)
                guard NSMaxRange(checkboxRange) <= ns.length else { return }
                let mark = marker.substring(with: NSRange(location: open.location + 1, length: 1))
                decorations.append(InlineTaskDecoration(
                    checkboxRange: checkboxRange,
                    line: lineNumber,
                    checked: mark == "x" || mark == "X",
                    scale: scale
                ))
            }
            return decorations
        }

        private func loadImageDecorations(in source: String, scale: CGFloat) -> [InlineImageDecoration] {
            guard let directory = parent.docDirectory else { return [] }
            let ns = source as NSString
            func makeDecoration(range: NSRange, destination rawDestination: String,
                                alt: String) -> InlineImageDecoration? {
                let destination = rawDestination
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    .first
                    .map(String.init) ?? ""
                guard !destination.isEmpty,
                      !destination.hasPrefix("http://"),
                      !destination.hasPrefix("https://"),
                      !destination.hasPrefix("data:"),
                      !destination.hasPrefix("file:") else { return nil }
                let decoded = destination.removingPercentEncoding ?? destination
                let url = decoded.hasPrefix("/")
                    ? URL(fileURLWithPath: decoded)
                    : directory.appendingPathComponent(decoded)
                guard let image = NSImage(contentsOf: url) else { return nil }
                return InlineImageDecoration(range: range, image: image, alt: alt, scale: scale)
            }

            var decorations: [InlineImageDecoration] = []
            if let markdownRegex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) {
                for match in markdownRegex.matches(in: source,
                                                    range: NSRange(location: 0, length: ns.length)) {
                    let alt = ns.substring(with: match.range(at: 1))
                    let destination = ns.substring(with: match.range(at: 2))
                    if let decoration = makeDecoration(range: match.range,
                                                       destination: destination, alt: alt) {
                        decorations.append(decoration)
                    }
                }
            }
            if let htmlRegex = try? NSRegularExpression(
                pattern: #"<img\b[^>]*?\bsrc\s*=\s*([\"'])(.*?)\1[^>]*>"#,
                options: [.caseInsensitive]) {
                for match in htmlRegex.matches(in: source,
                                                range: NSRange(location: 0, length: ns.length)) {
                    let destination = ns.substring(with: match.range(at: 2))
                    if let decoration = makeDecoration(range: match.range,
                                                       destination: destination, alt: "Image") {
                        decorations.append(decoration)
                    }
                }
            }
            return decorations
        }

        private func positionImageDecorations(in tv: InlineMarkdownTextView) {
            guard let layout = tv.layoutManager, let container = tv.textContainer else { return }
            layout.ensureLayout(for: container)
            let viewportWidth = max(180, (tv.enclosingScrollView?.contentSize.width ?? tv.bounds.width)
                                        - tv.textContainerInset.width * 2)
            for imageView in tv.imageViews {
                let caretRange = NSRange(location: imageView.sourceRange.location, length: 0)
                let glyphRange = layout.glyphRange(forCharacterRange: caretRange,
                                                   actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
                let image = imageView.image ?? NSImage()
                let scale = imageView.displayScale
                let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
                let maxWidth = min(viewportWidth, 720 * scale)
                let width = min(maxWidth, max(160 * scale, image.size.width * scale))
                let height = min(240 * scale, max(72 * scale, width / max(0.1, ratio)))
                imageView.frame = NSRect(x: rect.minX + tv.textContainerOrigin.x,
                                         y: rect.minY + tv.textContainerOrigin.y + 6 * scale,
                                         width: width, height: height)
            }
        }

        private func positionTaskDecorations(in tv: InlineMarkdownTextView) {
            guard let layout = tv.layoutManager, let container = tv.textContainer else { return }
            let length = (tv.string as NSString).length
            guard length > 0 else { return }
            layout.ensureLayout(for: container)
            for button in tv.taskButtons {
                let location = min(button.sourceRange.location, max(0, length - 1))
                let glyphRange = layout.glyphRange(
                    forCharacterRange: NSRange(location: location, length: 1),
                    actualCharacterRange: nil
                )
                let glyph = glyphRange.location
                let lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let textGlyphRange = layout.glyphRange(forCharacterRange: button.sourceRange,
                                                       actualCharacterRange: nil)
                let textRect = layout.boundingRect(forGlyphRange: textGlyphRange, in: container)
                let size = NSSize(width: 16 * button.displayScale, height: 16 * button.displayScale)
                button.frame = NSRect(x: textRect.minX + tv.textContainerOrigin.x,
                                      y: lineRect.midY + tv.textContainerOrigin.y - size.height / 2,
                                      width: size.width,
                                      height: size.height)
            }
        }

        private func styleDelimiter(_ storage: NSTextStorage, range: NSRange) {
            // WYSIWYG surface: delimiters remain in the raw storage but never compete with
            // the document. Source mode is the deliberate place to inspect/edit syntax.
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: 0.01),
                .foregroundColor: NSColor.clear
            ], range: range)
        }

        private var codeFill: NSColor {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.35)
        }

        private func headingScale(_ level: Int) -> CGFloat {
            switch level {
            case 1: return 2.0
            case 2: return 1.5
            case 3: return 1.25
            case 4: return 1.05
            case 5: return 1.0
            default: return 0.85
            }
        }

        private func italicFont(size: CGFloat) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: .regular)
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        }

        private func styleTaskLines(_ storage: NSTextStorage, source: String,
                                    scale: CGFloat) {
            let ns = source as NSString
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                                   options: [.byLines, .substringNotRequired]) { [weak self] _, lineRange, _, _ in
                guard self != nil, lineRange.length > 0 else { return }
                let line = ns.substring(with: lineRange)
                guard let match = line.range(of: #"^\s*[-*+]\s+\[([ xX])\]"#, options: .regularExpression) else { return }
                let matchRange = NSRange(match, in: line)
                let absolute = NSRange(location: lineRange.location + matchRange.location,
                                       length: matchRange.length)
                let checked = line[match].contains("x") || line[match].contains("X")
                storage.addAttributes([
                    .foregroundColor: NSColor.controlAccentColor,
                    .font: NSFont.systemFont(ofSize: 16 * scale, weight: .semibold),
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.08)
                ], range: absolute)
                if checked {
                    let contentStart = NSMaxRange(absolute)
                    let lineEnd = lineRange.location + lineRange.length
                    guard contentStart < lineEnd else { return }
                    storage.addAttributes([
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: NSColor.secondaryLabelColor
                    ], range: NSRange(location: contentStart, length: lineEnd - contentStart))
                }
            }
        }

        // MARK: lint/find overlays

        func applyUnderlines(to tv: NSTextView) {
            guard let layout = tv.layoutManager else { return }
            let full = NSRange(location: 0, length: tv.textStorage?.length ?? 0)
            guard full.length > 0 else { return }
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
            layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
            let style = NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue
            for issue in parent.issues {
                guard issue.range.length > 0, NSMaxRange(issue.range) <= full.length else { continue }
                layout.addTemporaryAttributes([
                    .underlineStyle: style,
                    .underlineColor: NSColor.systemOrange
                ], forCharacterRange: issue.range)
            }
        }

        func applyFind(_ find: FindController?) {
            guard let tv = textView, let find else {
                clearFindHighlights()
                return
            }
            if find.replaceToken != lastReplaceToken {
                lastReplaceToken = find.replaceToken
                guard find.isVisible, !find.query.isEmpty else { return }
                if find.replaceAllRequested { replaceAll(in: tv, find: find) }
                else { replaceOnce(in: tv, find: find) }
                return
            }

            let becameVisible = find.isVisible && !lastFindVisible
            let queryChanged = find.query != lastQuery || find.caseSensitive != lastCaseSensitive
            let navChanged = find.navToken != lastNavToken
            lastFindVisible = find.isVisible
            lastQuery = find.query
            lastCaseSensitive = find.caseSensitive
            lastNavToken = find.navToken

            guard find.isVisible else {
                if becameVisible || !find.query.isEmpty { clearFindHighlights() }
                return
            }
            guard becameVisible || queryChanged || navChanged else { return }
            guard !find.query.isEmpty else {
                matches = []
                clearFindHighlights()
                find.status = ""
                return
            }
            if becameVisible || queryChanged || matchesStale {
                recomputeMatches(for: find)
                matchesStale = false
            }
            if navChanged, !matches.isEmpty {
                if find.backwards { currentMatch = (currentMatch - 1 + matches.count) % matches.count }
                else { currentMatch = (currentMatch + 1) % matches.count }
            }
            currentMatch = matches.isEmpty ? 0 : min(currentMatch, matches.count - 1)
            highlightMatches()
            if !matches.isEmpty { jumpToCurrentMatch() }
            find.status = matches.isEmpty ? "Not found" : "\(currentMatch + 1)/\(matches.count)"
        }

        private func recomputeMatches(for find: FindController) {
            guard let tv = textView else { return }
            matches = []
            let source = tv.string as NSString
            let options: NSString.CompareOptions = find.caseSensitive ? [] : [.caseInsensitive]
            var location = 0
            while location < source.length {
                let range = source.range(of: find.query, options: options,
                                         range: NSRange(location: location, length: source.length - location))
                guard range.location != NSNotFound else { break }
                matches.append(range)
                location = range.location + max(1, range.length)
            }
            currentMatch = matches.firstIndex(where: { $0.location >= tv.selectedRange().location }) ?? 0
        }

        private func highlightMatches() {
            guard let tv = textView, let layout = tv.layoutManager else { return }
            let full = NSRange(location: 0, length: tv.textStorage?.length ?? 0)
            guard full.length > 0 else { return }
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            for (index, range) in matches.enumerated() {
                layout.addTemporaryAttributes([
                    .backgroundColor: index == currentMatch
                        ? NSColor.controlAccentColor.withAlphaComponent(0.28)
                        : NSColor.systemYellow.withAlphaComponent(0.25)
                ], forCharacterRange: range)
            }
        }

        private func clearFindHighlights() {
            guard let tv = textView, let layout = tv.layoutManager else { return }
            let full = NSRange(location: 0, length: tv.textStorage?.length ?? 0)
            if full.length > 0 { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full) }
            matches = []
        }

        private func jumpToCurrentMatch() {
            guard let range = matches[safe: currentMatch], let tv = textView else { return }
            tv.setSelectedRange(range)
            tv.scrollRangeToVisible(range)
            if typewriterMode { centerCaret(in: tv) }
        }

        private func replaceOnce(in tv: NSTextView, find: FindController) {
            if matches.isEmpty { recomputeMatches(for: find) }
            guard let range = matches[safe: currentMatch] else {
                find.status = "Not found"
                return
            }
            tv.insertText(find.replaceText, replacementRange: range)
            recomputeMatches(for: find)
            highlightMatches()
            find.status = matches.isEmpty ? "Not found" : "\(currentMatch + 1)/\(matches.count)"
        }

        private func replaceAll(in tv: NSTextView, find: FindController) {
            if matches.isEmpty { recomputeMatches(for: find) }
            guard !matches.isEmpty else {
                find.status = "Not found"
                return
            }
            let undo = tv.undoManager
            undo?.beginUndoGrouping()
            for range in matches.reversed() {
                tv.insertText(find.replaceText, replacementRange: range)
            }
            undo?.endUndoGrouping()
            recomputeMatches(for: find)
            highlightMatches()
            find.status = matches.isEmpty ? "Not found" : "\(currentMatch + 1)/\(matches.count)"
        }

        // MARK: scrolling/focus

        func observeScroll(_ clip: NSView) {
            clip.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.reportScroll() }
        }

        func observeFrame(_ scroll: NSScrollView) {
            scroll.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: scroll, queue: .main
            ) { [weak self, weak scroll] _ in
                guard let self, let scroll else { return }
                self.applyWidth(to: scroll)
            }
        }

        func reportNow() { parent.onEvent(.scrolled(topLine: topLine())) }

        private func reportScroll() {
            parent.onEvent(.scrolled(topLine: topLine()))
        }

        private func topLine() -> Int {
            guard let tv = textView, let layout = tv.layoutManager,
                  let container = tv.textContainer else { return 0 }
            let y = max(0, tv.visibleRect.origin.y - tv.textContainerInset.height) + 1
            let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
            let character = layout.characterIndexForGlyph(at: glyph)
            let source = tv.string as NSString
            return source.substring(to: min(character, source.length)).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        }

        func applyWidth(to scroll: NSScrollView, animated: Bool = false) {
            guard let tv = scroll.documentView as? NSTextView else { return }
            let target = fullWidth ? 8 : max(8, (scroll.contentSize.width - measure) / 2)
            if abs(tv.textContainerInset.width - target) < 0.5 {
                if let inline = tv as? InlineMarkdownTextView {
                    positionImageDecorations(in: inline)
                    positionTaskDecorations(in: inline)
                }
                return
            }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    tv.animator().textContainerInset = NSSize(width: target,
                                                              height: tv.textContainerInset.height)
                }
            } else {
                tv.textContainerInset = NSSize(width: target, height: tv.textContainerInset.height)
            }
            if let inline = tv as? InlineMarkdownTextView {
                positionImageDecorations(in: inline)
                positionTaskDecorations(in: inline)
            }
        }

        func focusEditor() {
            guard let tv = textView else { return }
            tv.window?.makeFirstResponder(tv)
        }

        func placeCaret(atOffset offset: Int) {
            guard let tv = textView else { return }
            let location = max(0, min(offset, (tv.string as NSString).length))
            tv.setSelectedRange(NSRange(location: location, length: 0))
            tv.scrollRangeToVisible(NSRange(location: location, length: 0))
        }

        func placeCaret(atLine line: Int) {
            guard let tv = textView else { return }
            let source = tv.string as NSString
            var location = 0
            var current = 0
            while current < line && location < source.length {
                let range = source.lineRange(for: NSRange(location: location, length: 0))
                let next = NSMaxRange(range)
                guard next > location else { break }
                location = next
                current += 1
            }
            placeCaret(atOffset: location)
        }

        func scroll(toLine line: Int) {
            placeCaret(atLine: line)
        }

        func jump(to range: NSRange) {
            guard let tv = textView else { return }
            let length = (tv.string as NSString).length
            let location = min(max(0, range.location), length)
            let clamped = NSRange(location: location,
                                   length: min(range.length, max(0, length - location)))
            tv.setSelectedRange(clamped)
            tv.scrollRangeToVisible(clamped)
            tv.window?.makeFirstResponder(tv)
        }

        private func centerCaret(in tv: NSTextView) {
            guard let layout = tv.layoutManager, let container = tv.textContainer,
                  let clip = tv.enclosingScrollView?.contentView else { return }
            let location = min(tv.selectedRange().location, (tv.string as NSString).length)
            let glyph = layout.glyphRange(forCharacterRange: NSRange(location: location, length: 0),
                                          actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyph, in: container)
            let targetY = max(0, rect.midY + tv.textContainerInset.height - clip.bounds.height / 2)
            if abs(clip.bounds.origin.y - targetY) > clip.bounds.height * 0.2 {
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
            }
        }

        // MARK: interactions

        func toggleTask(at line: Int) {
            guard let tv = textView else { return }
            let source = tv.string as NSString
            var location = 0
            var current = 0
            while current < line && location < source.length {
                let range = source.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(range)
                current += 1
            }
            guard location < source.length else { return }
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            let lineText = source.substring(with: range)
            guard let marker = lineText.range(of: #"^\s*[-*+]\s+\[([ xX])\]"#, options: .regularExpression) else { return }
            let markerRange = NSRange(marker, in: lineText)
            let markerText = (lineText as NSString).substring(with: markerRange)
            guard let bracket = markerText.firstIndex(of: "[") else { return }
            let offset = markerText.distance(from: markerText.startIndex, to: bracket) + 1
            let locationInText = range.location + markerRange.location + offset
            let currentMark = (lineText as NSString).substring(with: NSRange(location: offset, length: 1))
            let replacement = currentMark == " " ? "x" : " "
            tv.insertText(replacement, replacementRange: NSRange(location: locationInText, length: 1))
        }
    }
}

private enum InlineTextSync {
    static func bindingSnapshot(_ value: String) -> String {
        var snapshot = value
        snapshot.makeContiguousUTF8()
        return snapshot
    }

    static func shouldApplyExternalText(bindingText: String,
                                         lastNativeText: String,
                                         hasMarkedText: Bool) -> Bool {
        !hasMarkedText && bindingText != lastNativeText
    }
}

private struct InlineImageDecoration {
    let range: NSRange
    let image: NSImage
    let alt: String
    let scale: CGFloat
}

private struct InlineTaskDecoration {
    let checkboxRange: NSRange
    let line: Int
    let checked: Bool
    let scale: CGFloat
}

private final class InlineImageView: NSImageView {
    let sourceRange: NSRange
    let displayScale: CGFloat

    init(decoration: InlineImageDecoration) {
        sourceRange = decoration.range
        displayScale = decoration.scale
        super.init(frame: .zero)
        image = decoration.image
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignTopLeft
        toolTip = decoration.alt.isEmpty ? nil : decoration.alt
        setAccessibilityLabel(decoration.alt.isEmpty ? "Markdown image" : decoration.alt)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The decoration is visual only. Let the text view receive the click and place the
    // caret in the underlying Markdown range instead of making the image an input island.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class InlineTaskButton: NSButton {
    let sourceRange: NSRange
    let sourceLine: Int
    let displayScale: CGFloat
    var onToggle: ((Int) -> Void)?

    init(decoration: InlineTaskDecoration) {
        sourceRange = decoration.checkboxRange
        sourceLine = decoration.line
        displayScale = decoration.scale
        super.init(frame: .zero)
        setButtonType(.switch)
        title = ""
        state = decoration.checked ? .on : .off
        controlSize = .small
        isBordered = false
        setAccessibilityLabel("Task")
        setAccessibilityValue(decoration.checked ? "Completed" : "Not completed")
        target = self
        action = #selector(toggle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggle() {
        onToggle?(sourceLine)
    }
}

private final class InlineMarkdownTextView: NSTextView {
    var onTaskToggle: ((Int) -> Void)?
    private(set) var imageViews: [InlineImageView] = []
    private(set) var taskButtons: [InlineTaskButton] = []
    var imagePolicy: ImagePolicy? {
        didSet {
            guard imagePolicy != nil else { return }
            var types = registeredDraggedTypes
            if !types.contains(.fileURL) { types.append(.fileURL) }
            registerForDraggedTypes(types)
        }
    }

    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "webp", "svg", "tiff", "heic"]

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        if imagePolicy != nil {
            for type in [NSPasteboard.PasteboardType.png, .tiff, .fileURL]
                where !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    func replaceImageDecorations(_ decorations: [InlineImageDecoration]) {
        imageViews.forEach { $0.removeFromSuperview() }
        imageViews = decorations.map(InlineImageView.init(decoration:))
        imageViews.forEach { addSubview($0) }
    }

    func replaceTaskDecorations(_ decorations: [InlineTaskDecoration], onToggle: @escaping (Int) -> Void) {
        taskButtons.forEach { $0.removeFromSuperview() }
        taskButtons = decorations.map { decoration in
            let button = InlineTaskButton(decoration: decoration)
            button.onToggle = onToggle
            return button
        }
        taskButtons.forEach { addSubview($0) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let line = taskLine(at: point) {
            onTaskToggle?(line)
            return
        }
        super.mouseDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard !hasMarkedText(), replacementRange.location == NSNotFound,
              let value = string as? String, value.count == 1,
              let closer = Self.pairs[value] else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let selection = selectedRange()
        let source = self.string as NSString
        if selection.length > 0 {
            let inner = source.substring(with: selection)
            let replacement = value + inner + closer
            guard shouldChangeText(in: selection, replacementString: replacement) else { return }
            textStorage?.replaceCharacters(in: selection, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: selection.location + (value as NSString).length,
                                      length: selection.length))
            return
        }
        if selection.location < source.length,
           (source.substring(with: NSRange(location: selection.location, length: 1)) == closer) {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }
        let replacement = value + closer
        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: selection, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location + (value as NSString).length, length: 0))
    }

    // MARK: Paste and drag images without changing the Markdown source model

    override func pasteAsPlainText(_ sender: Any?) {
        if handleImagePaste() { return }
        super.pasteAsPlainText(sender)
    }

    override func paste(_ sender: Any?) {
        if handleImagePaste() { return }
        guard let pasted = NSPasteboard.general.string(forType: .string),
              selectedRange().length > 0,
              Self.isSingleLineURL(pasted) else {
            super.paste(sender)
            return
        }
        let selection = selectedRange()
        let source = string as NSString
        let selected = source.substring(with: selection)
        guard !Self.isSingleLineURL(selected) else {
            super.paste(sender)
            return
        }
        let url = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = "[\(selected)](\(url))"
        insertText(replacement, replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + (replacement as NSString).length,
                                  length: 0))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if imagePolicy != nil, !imageFileURLs(from: sender.draggingPasteboard).isEmpty {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if imagePolicy != nil, !imageFileURLs(from: sender.draggingPasteboard).isEmpty {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let policy = imagePolicy else { return super.performDragOperation(sender) }
        let urls = imageFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        let paths = urls.compactMap { policy.resolveImageFile($0) }
        guard !paths.isEmpty else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        insertImageMarkdown(paths, at: NSRange(location: index, length: 0))
        window?.makeFirstResponder(self)
        return true
    }

    private func handleImagePaste() -> Bool {
        guard let policy = imagePolicy else { return false }
        let pasteboard = NSPasteboard.general

        let fileURLs = imageFileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            let paths = fileURLs.compactMap { policy.resolveImageFile($0) }
            if !paths.isEmpty {
                insertImageMarkdown(paths, at: selectedRange())
                return true
            }
        }

        if let (data, ext) = imageData(from: pasteboard),
           let path = policy.saveImageData(data, ext) {
            insertImageMarkdown([path], at: selectedRange())
            return true
        }
        return false
    }

    private func insertImageMarkdown(_ paths: [String], at range: NSRange) {
        let markdown = paths.map { "![](\($0))" }
            .joined(separator: "\n")
        insertText(markdown, replacementRange: range)
    }

    private func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return objects.filter(Self.isImageFile)
    }

    private func imageData(from pasteboard: NSPasteboard) -> (Data, String)? {
        if let data = pasteboard.data(forType: .png) { return (data, "png") }
        if let tiff = pasteboard.data(forType: .tiff),
           let representation = NSBitmapImageRep(data: tiff),
           let png = representation.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        return nil
    }

    private static func isImageFile(_ url: URL) -> Bool {
        url.isFileURL && imageExtensions.contains(url.pathExtension.lowercased())
    }

    private static func isSingleLineURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0 == "\n" || $0 == " " || $0 == "\t" }) else {
            return false
        }
        return trimmed.range(of: #"^https?://[^\s]+$"#, options: .regularExpression) != nil
    }

    @objc func toggleMarkdownBold(_ sender: Any?) { wrapSelection(with: "**") }

    @objc func toggleMarkdownItalic(_ sender: Any?) { wrapSelection(with: "*") }

    @objc func insertMarkdownLink(_ sender: Any?) {
        let selection = selectedRange()
        let source = string as NSString
        let selected = selection.length > 0 ? source.substring(with: selection) : "text"
        let replacement = "[\(selected)](url)"
        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: selection, with: replacement)
        didChangeText()
        let urlStart = selection.location + 1 + (selected as NSString).length + 2
        setSelectedRange(NSRange(location: urlStart, length: 3))
    }

    private func wrapSelection(with marker: String) {
        let selection = selectedRange()
        let source = string as NSString
        let selected = selection.length > 0 ? source.substring(with: selection) : "text"
        let replacement = marker + selected + marker
        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: selection, with: replacement)
        didChangeText()
        let start = selection.location + (marker as NSString).length
        setSelectedRange(NSRange(location: start, length: (selected as NSString).length))
    }

    private func taskLine(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        let location = layout.characterIndexForGlyph(at: glyph)
        let source = string as NSString
        guard source.length > 0 else { return nil }
        let lineRange = source.lineRange(for: NSRange(location: min(location, source.length), length: 0))
        let line = source.substring(with: lineRange)
        guard let marker = line.range(of: #"^\s*[-*+]\s+\[[ xX]\]"#, options: .regularExpression) else {
            return nil
        }
        let markerRange = NSRange(marker, in: line)
        guard location >= lineRange.location + markerRange.location,
              location <= lineRange.location + NSMaxRange(markerRange) else { return nil }
        return source.substring(to: lineRange.location).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private static let pairs: [String: String] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"
    ]

    static func continuationPrefix(for line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        if let task = trimmed.range(of: #"^[-*+]\s+\[[ xX]\]\s*"#, options: .regularExpression) {
            let marker = String(trimmed[task]).prefix(1)
            let content = trimmed[task.upperBound...].trimmingCharacters(in: .whitespaces)
            return content.isEmpty ? "" : indent + "\(marker) [ ] "
        }
        if let bullet = trimmed.range(of: #"^[-*+]\s*"#, options: .regularExpression) {
            let marker = String(trimmed[bullet]).prefix(1)
            let content = trimmed[bullet.upperBound...].trimmingCharacters(in: .whitespaces)
            return content.isEmpty ? "" : indent + "\(marker) "
        }
        if let ordered = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            let prefix = String(trimmed[ordered])
            let number = prefix.dropLast().trimmingCharacters(in: .whitespaces)
            let delimiter = prefix.last == ")" ? ")" : "."
            let content = trimmed[ordered.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let value = Int(number), !content.isEmpty else { return content.isEmpty ? "" : nil }
            return indent + "\(value + 1)\(delimiter) "
        }
        if trimmed.hasPrefix(">") {
            let content = trimmed.drop(while: { $0 == ">" || $0 == " " })
            return content.isEmpty ? "" : indent + "> "
        }
        return nil
    }
}

private struct InlineLintIssue: Identifiable {
    let id = UUID()
    let line: Int
    let range: NSRange
    let message: String
}

private enum InlineMarkdownLinter {
    static func lint(_ text: String) -> [InlineLintIssue] {
        let ns = text as NSString
        var issues: [InlineLintIssue] = []
        var lineNumber = 0
        var blankRun = 0
        var fenceOpen = false
        var fenceCount = 0

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            lineNumber += 1
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fenceOpen.toggle()
                fenceCount += 1
            }
            guard !fenceOpen || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return }

            if let tab = line.firstIndex(of: "\t") {
                let offset = line.distance(from: line.startIndex, to: tab)
                issues.append(InlineLintIssue(line: lineNumber,
                                              range: NSRange(location: lineRange.location + offset, length: 1),
                                              message: "Hard tab — use spaces"))
            }
            if !line.isEmpty && line != line.trimmingCharacters(in: .whitespacesAndNewlines) {
                let end = line.trimmingCharacters(in: .whitespacesAndNewlines).count
                if end < line.count {
                    issues.append(InlineLintIssue(line: lineNumber,
                                                  range: NSRange(location: lineRange.location + end,
                                                                 length: line.count - end),
                                                  message: "Trailing whitespace"))
                }
            }
            if line.isEmpty {
                blankRun += 1
                if blankRun == 2 {
                    issues.append(InlineLintIssue(line: lineNumber, range: lineRange,
                                                  message: "Multiple blank lines"))
                }
            } else {
                blankRun = 0
            }
        }

        if fenceCount % 2 != 0 {
            issues.append(InlineLintIssue(line: max(1, lineNumber),
                                          range: NSRange(location: max(0, ns.length - 1), length: 0),
                                          message: "Unclosed code fence"))
        }
        if !text.isEmpty && !text.hasSuffix("\n") {
            issues.append(InlineLintIssue(line: max(1, lineNumber),
                                          range: NSRange(location: max(0, ns.length - 1), length: 0),
                                          message: "File should end with a newline"))
        }
        return issues
    }
}

private struct InlineLintBar: View {
    let issues: [InlineLintIssue]
    let onJump: (InlineLintIssue) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Label("\(issues.count)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption.bold())
                ForEach(issues.prefix(40)) { issue in
                    Button("L\(issue.line): \(issue.message)") { onJump(issue) }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .buttonStyle(.plain)
                        .help("Jump to line \(issue.line)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
