import SwiftUI
import WebKit
import MarkdownEditorKit

/// Hands ContentView a reference to the live rendered WKWebView so File-menu Print /
/// Export-as-PDF (D1) can drive it. Weak so the web view's lifetime stays owned by the
/// NSViewRepresentable, not this handle.
final class ViewerHandle: ObservableObject {
    weak var webView: WKWebView?
}

struct MarkdownWebView: NSViewRepresentable {
    var markdown: String
    @ObservedObject var find: FindController
    var sync: ScrollSync
    /// Source line to scroll to once loaded (set when arriving from the raw view).
    var initialLine: Int?
    /// Bumped by `DetailFocusController` to pull keyboard focus into the web view.
    var focusPulse: Int = 0
    /// App-wide font zoom (1.0 == default). Applied as the rendered body font-size.
    var fontScale: Double = 1
    /// App-wide full-width toggle (synced with the raw editor). Off caps the measure.
    var fullWidth: Bool = false
    /// Receives the rendered selection's character count for the bottom readout.
    var selection: SelectionController
    /// Folder the open document lives in; relative in-document links resolve against it.
    var docDirectory: URL?
    /// Opens a markdown file in Glim (in-document link to another .md). Non-markdown links
    /// and external (http/mailto) links are handed to the system instead.
    var onOpenFile: (URL) -> Void = { _ in }
    /// A rendered task checkbox was clicked; carries its 0-based source line to toggle (A3).
    var onToggleTask: (Int) -> Void = { _ in }
    /// Reports the href under the pointer for the link-hover status readout (A7); "" on exit.
    var onHoverLink: (String) -> Void = { _ in }
    /// Outline-panel jump (A2): a bumped `jumpToken` scrolls the view to `jumpLine`.
    var jumpToken: Int = 0
    var jumpLine: Int?
    /// Exposes the live web view to the app for Print / Export-as-PDF (D1).
    var viewerHandle: ViewerHandle?

    func makeCoordinator() -> Coordinator { Coordinator(sync: sync, selection: selection) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "ready")
        config.userContentController.add(context.coordinator, name: "scroll")
        config.userContentController.add(context.coordinator, name: "selection")
        config.userContentController.add(context.coordinator, name: "openLink")
        config.userContentController.add(context.coordinator, name: "toggleTask")
        config.userContentController.add(context.coordinator, name: "hoverLink")
        config.userContentController.add(context.coordinator, name: "copyCode")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // let CSS paint bg, avoid white flash
        context.coordinator.webView = webView
        context.coordinator.pendingLine = initialLine
        context.coordinator.lastFocusPulse = focusPulse
        context.coordinator.lastJumpToken = jumpToken
        context.coordinator.fontScale = fontScale
        context.coordinator.fullWidth = fullWidth
        context.coordinator.docDirectory = docDirectory
        context.coordinator.onOpenFile = onOpenFile
        context.coordinator.onToggleTask = onToggleTask
        context.coordinator.onHoverLink = onHoverLink
        viewerHandle?.webView = webView

        if let index = WebResources.indexURL(), let dir = WebResources.directory() {
            webView.loadFileURL(index, allowingReadAccessTo: dir)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.docDirectory = docDirectory
        context.coordinator.onOpenFile = onOpenFile
        context.coordinator.onToggleTask = onToggleTask
        context.coordinator.onHoverLink = onHoverLink
        viewerHandle?.webView = webView
        context.coordinator.render(markdown)
        context.coordinator.applyFontScale(fontScale)
        context.coordinator.applyFullWidth(fullWidth)
        context.coordinator.applyFind(find)
        if focusPulse != context.coordinator.lastFocusPulse {
            context.coordinator.lastFocusPulse = focusPulse
            DispatchQueue.main.async { webView.window?.makeFirstResponder(webView) }
        }
        if jumpToken != context.coordinator.lastJumpToken {
            context.coordinator.lastJumpToken = jumpToken
            if let line = jumpLine {
                context.coordinator.scrollToLine(line)
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private let sync: ScrollSync
        private let selection: SelectionController
        private var ready = false
        private var pending: String?
        private var lastMarkdown: String?
        private var lastRendered: String?
        var pendingLine: Int?
        var lastFocusPulse = 0
        var docDirectory: URL?
        var onOpenFile: (URL) -> Void = { _ in }
        var onToggleTask: (Int) -> Void = { _ in }
        var onHoverLink: (String) -> Void = { _ in }
        var lastJumpToken = 0
        var fontScale: Double = 1
        private var appliedFontScale: Double = .nan
        var fullWidth = false
        private var appliedFullWidth: Bool?

        // Embedded-image cache: resolved absolute path -> (mtime, size, data URI). Lets an
        // unchanged image skip re-reading + re-encoding on every render (every keystroke).
        private var embedCache: [String: (mtime: Date, size: Int, uri: String)] = [:]

        // find de-dup
        private var lastVisible = false
        private var lastQuery = ""
        private var lastCase = false
        private var lastNav = 0

        init(sync: ScrollSync, selection: SelectionController) {
            self.sync = sync
            self.selection = selection
        }

        func render(_ markdown: String) {
            lastMarkdown = markdown
            guard ready else { pending = markdown; return }
            guard markdown != lastRendered else { return }
            lastRendered = markdown
            let toRender = docDirectory.map { embedLocalImages(markdown, in: $0) } ?? markdown
            webView?.evaluateJavaScript("window.renderMarkdown(\(WebResources.jsLiteral(toRender)));",
                                        completionHandler: nil)
        }

        // WKWebView sandbox only allows reading from the bundle's web/ dir (allowingReadAccessTo).
        // Resolve local image paths — both markdown ![alt](path) and raw HTML <img src="path"> —
        // to base64 data URIs so local images render. http/https/data:/file: are left untouched;
        // a missing file keeps its original src (the render.js placeholder then shows the gap).
        private func embedLocalImages(_ md: String, in dir: URL) -> String {
            var result = md
            var referenced = Set<String>()   // resolved paths used this render, for cache pruning

            // 1) Markdown images: ![alt](path) -> ![alt](data:…)
            if let re = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) {
                let ns = result as NSString
                for m in re.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                    let path = ns.substring(with: m.range(at: 2))
                    guard let fileURL = resolveImagePath(path, in: dir),
                          let uri = dataURI(for: fileURL, referenced: &referenced) else { continue }
                    let alt = ns.substring(with: m.range(at: 1))
                    result.replaceSubrange(Range(m.range(at: 0), in: result)!, with: "![\(alt)](\(uri))")
                }
            }

            // 2) Raw HTML images: rewrite only the src="…"/src='…' value in place.
            if let re = try? NSRegularExpression(pattern: #"<img\b[^>]*?\bsrc\s*=\s*(["'])(.*?)\1"#,
                                                 options: [.caseInsensitive]) {
                let ns = result as NSString
                for m in re.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                    let path = ns.substring(with: m.range(at: 2))
                    guard let fileURL = resolveImagePath(path, in: dir),
                          let uri = dataURI(for: fileURL, referenced: &referenced) else { continue }
                    result.replaceSubrange(Range(m.range(at: 2), in: result)!, with: uri)
                }
            }

            // Drop cache entries not referenced this render so it can't grow unbounded.
            embedCache = embedCache.filter { referenced.contains($0.key) }
            return result
        }

        /// Resolve a document image path to an absolute file URL, or nil if it's a remote/
        /// already-embedded reference we must leave alone. Absolute paths pass through; relative
        /// paths resolve against the document folder.
        private func resolveImagePath(_ path: String, in dir: URL) -> URL? {
            let p = path.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty, !p.hasPrefix("http"), !p.hasPrefix("data:"), !p.hasPrefix("file:")
            else { return nil }
            return p.hasPrefix("/") ? URL(fileURLWithPath: p) : dir.appendingPathComponent(p)
        }

        /// Base64 data URI for `fileURL`, served from the cache when the file's mtime+size are
        /// unchanged. Records the key in `referenced` (for pruning). nil if missing/unreadable.
        private func dataURI(for fileURL: URL, referenced: inout Set<String>) -> String? {
            let key = fileURL.standardizedFileURL.path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: key),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? Int else { return nil }   // missing -> leave original src
            referenced.insert(key)
            if let c = embedCache[key], c.mtime == mtime, c.size == size { return c.uri }
            // ponytail: first encode still sync on main; move to a background queue if large-image docs stutter
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            let ext = fileURL.pathExtension.lowercased()
            let mime = ["jpeg": "image/jpeg", "jpg": "image/jpeg", "gif": "image/gif",
                        "svg": "image/svg+xml", "webp": "image/webp"][ext] ?? "image/png"
            let uri = "data:\(mime);base64,\(data.base64EncodedString())"
            embedCache[key] = (mtime, size, uri)
            return uri
        }

        /// Push the current zoom into the page (no-op until ready, and de-duped so a
        /// re-render or find echo doesn't re-evaluate JS for an unchanged scale).
        func applyFontScale(_ scale: Double) {
            fontScale = scale
            guard ready, scale != appliedFontScale else { return }
            appliedFontScale = scale
            webView?.evaluateJavaScript("window.glimSetFontScale(\(scale));", completionHandler: nil)
        }

        /// Scroll the rendered view so 0-based source `line` sits at the top (outline jump, A2).
        func scrollToLine(_ line: Int) {
            guard ready else { pendingLine = line; return }
            webView?.evaluateJavaScript("window.glimScrollToLine(\(line));", completionHandler: nil)
        }

        /// Push the full-width state into the page (no-op until ready, de-duped).
        func applyFullWidth(_ full: Bool) {
            fullWidth = full
            guard ready, full != appliedFullWidth else { return }
            appliedFullWidth = full
            webView?.evaluateJavaScript("window.glimSetFullWidth(\(full));", completionHandler: nil)
        }

        // MARK: find

        func applyFind(_ find: FindController) {
            guard ready else { return }
            let becameVisible = find.isVisible && !lastVisible
            let queryChanged = find.query != lastQuery || find.caseSensitive != lastCase
            let navChanged = find.navToken != lastNav
            let wasVisible = lastVisible
            lastVisible = find.isVisible
            lastQuery = find.query
            lastCase = find.caseSensitive
            lastNav = find.navToken

            guard find.isVisible else {
                if wasVisible { webView?.evaluateJavaScript("window.getSelection().removeAllRanges();") }
                return
            }
            guard becameVisible || queryChanged || navChanged else { return } // ignore status echoes
            guard !find.query.isEmpty else {
                setStatus(find, "")
                webView?.evaluateJavaScript("window.getSelection().removeAllRanges();")
                return
            }
            let fresh = becameVisible || queryChanged
            let backwards = (navChanged && !fresh) ? find.backwards : false
            performFind(find, backwards: backwards, fresh: fresh)
        }

        private func performFind(_ find: FindController, backwards: Bool, fresh: Bool) {
            let q = find.query, cs = find.caseSensitive
            let js = "window.glimFind(\(WebResources.jsLiteral(q)), \(cs), \(backwards), \(fresh));"
            webView?.evaluateJavaScript(js) { [weak self] res, _ in
                let found = (res as? Bool) ?? false
                self?.webView?.evaluateJavaScript(
                    "window.glimCountMatches(\(WebResources.jsLiteral(q)), \(cs));") { c, _ in
                    let n = (c as? Int) ?? Int((c as? Double) ?? 0)
                    if n == 0 && !found { self?.setStatus(find, "Not found") }
                    else { self?.setStatus(find, "\(n) match\(n == 1 ? "" : "es")") }
                }
            }
        }

        private func setStatus(_ find: FindController, _ s: String) {
            if find.status != s { find.status = s }
        }

        // MARK: messages

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "ready":
                ready = true
                let md = pending ?? lastMarkdown ?? ""
                pending = nil
                lastRendered = nil
                render(md)
                appliedFontScale = .nan        // force a fresh apply now that the page exists
                applyFontScale(fontScale)
                appliedFullWidth = nil
                applyFullWidth(fullWidth)
                if let line = pendingLine {
                    pendingLine = nil
                    webView?.evaluateJavaScript(
                        "requestAnimationFrame(function(){window.glimScrollToLine(\(line));});",
                        completionHandler: nil)
                }
            case "scroll":
                let line = (message.body as? Int) ?? Int((message.body as? Double) ?? 0)
                sync.report(line: line, from: .view)
            case "selection":
                let n = (message.body as? Int) ?? Int((message.body as? Double) ?? 0)
                selection.report(max(0, n))
            case "openLink":
                if let href = message.body as? String { openLink(href) }
            case "toggleTask":
                let line = (message.body as? Int) ?? Int((message.body as? Double) ?? 0)
                onToggleTask(line)
            case "hoverLink":
                onHoverLink((message.body as? String) ?? "")
            case "copyCode":
                if let code = message.body as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
            default:
                break
            }
        }

        /// Routes a clicked in-document link: http/https/mailto/ftp go to the system; a
        /// relative/absolute file path resolves against the document's folder — markdown
        /// opens in Glim, anything else (image, PDF, dir…) is handed to its default app.
        private func openLink(_ href: String) {
            let raw = href.trimmingCharacters(in: .whitespaces)
            if let u = URL(string: raw), let scheme = u.scheme?.lowercased(),
               ["http", "https", "mailto", "ftp"].contains(scheme) {
                NSWorkspace.shared.open(u); return
            }
            // Strip #fragment / ?query, percent-decode, then resolve as a file path.
            var path = raw
            if let i = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = String(path[..<i]) }
            guard !path.isEmpty else { return }   // pure in-page anchor — JS handles scrolling
            let decoded = path.removingPercentEncoding ?? path
            let target: URL
            if decoded.hasPrefix("/") { target = URL(fileURLWithPath: decoded) }
            else if let dir = docDirectory { target = URL(fileURLWithPath: decoded, relativeTo: dir) }
            else { return }
            let std = target.standardizedFileURL
            guard FileManager.default.fileExists(atPath: std.path) else { return }
            if FileEntry.isMarkdown(std) { onOpenFile(std) } else { NSWorkspace.shared.open(std) }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
            // allow loading the bundled renderer; route anything user-initiated outward
            if navigationAction.navigationType == .linkActivated ||
               (url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto") {
                if navigationAction.navigationType == .linkActivated {
                    NSWorkspace.shared.open(url)
                    return decisionHandler(.cancel)
                }
            }
            decisionHandler(.allow)
        }
    }
}
