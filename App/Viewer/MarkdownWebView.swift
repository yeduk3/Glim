import SwiftUI
import WebKit

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

    func makeCoordinator() -> Coordinator { Coordinator(sync: sync, selection: selection) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "ready")
        config.userContentController.add(context.coordinator, name: "scroll")
        config.userContentController.add(context.coordinator, name: "selection")
        config.userContentController.add(context.coordinator, name: "openLink")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // let CSS paint bg, avoid white flash
        context.coordinator.webView = webView
        context.coordinator.pendingLine = initialLine
        context.coordinator.lastFocusPulse = focusPulse
        context.coordinator.fontScale = fontScale
        context.coordinator.fullWidth = fullWidth
        context.coordinator.docDirectory = docDirectory
        context.coordinator.onOpenFile = onOpenFile

        if let index = WebResources.indexURL(), let dir = WebResources.directory() {
            webView.loadFileURL(index, allowingReadAccessTo: dir)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.docDirectory = docDirectory
        context.coordinator.onOpenFile = onOpenFile
        context.coordinator.render(markdown)
        context.coordinator.applyFontScale(fontScale)
        context.coordinator.applyFullWidth(fullWidth)
        context.coordinator.applyFind(find)
        if focusPulse != context.coordinator.lastFocusPulse {
            context.coordinator.lastFocusPulse = focusPulse
            DispatchQueue.main.async { webView.window?.makeFirstResponder(webView) }
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
        var fontScale: Double = 1
        private var appliedFontScale: Double = .nan
        var fullWidth = false
        private var appliedFullWidth: Bool?

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
            webView?.evaluateJavaScript("window.renderMarkdown(\(WebResources.jsLiteral(markdown)));",
                                        completionHandler: nil)
        }

        /// Push the current zoom into the page (no-op until ready, and de-duped so a
        /// re-render or find echo doesn't re-evaluate JS for an unchanged scale).
        func applyFontScale(_ scale: Double) {
            fontScale = scale
            guard ready, scale != appliedFontScale else { return }
            appliedFontScale = scale
            webView?.evaluateJavaScript("window.glimSetFontScale(\(scale));", completionHandler: nil)
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
