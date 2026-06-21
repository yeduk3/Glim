import Cocoa
import Quartz
import UniformTypeIdentifiers
import os

/// Data-based Quick Look preview provider for Markdown (macOS 12+ via
/// `QLIsDataBasedPreview` in Info.plist). Renders to static HTML in-process with
/// JavaScriptCore and hands it to Quick Look's own HTML renderer — no WKWebView /
/// WebContent (which cannot spawn in the QL preview sandbox).
class MarkdownPreviewProvider: NSViewController, QLPreviewingController {
    private static let log = Logger(subsystem: "com.gyu.glim.ql", category: "provider")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        Self.log.notice("providePreview: \(url.lastPathComponent, privacy: .public)")
        let bundle = Bundle(for: Self.self)

        return QLPreviewReply(dataOfContentType: .html,
                              contentSize: CGSize(width: 1000, height: 800)) { reply in
            reply.stringEncoding = .utf8
            reply.title = url.lastPathComponent

            let text: String
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                text = s
            } else {
                text = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
            }
            let html = JSRenderer.htmlDocument(markdown: text, bundle: bundle)
            Self.log.notice("html bytes=\(html.utf8.count, privacy: .public)")
            return Data(html.utf8)
        }
    }
}
