import Foundation
import JavaScriptCore
import os

/// Renders Markdown to a fully static, self-contained HTML document **in-process**
/// using JavaScriptCore (markdown-it + texmath/KaTeX + highlight.js). No WKWebView,
/// no WebContent process — works inside the restrictive Quick Look sandbox. The
/// output needs no JavaScript at display time (KaTeX is pre-rendered to HTML+CSS),
/// so Quick Look's HTML renderer shows it correctly.
enum JSRenderer {
    private static let log = Logger(subsystem: "com.gyu.glim.ql", category: "jsrender")

    static func htmlDocument(markdown: String, bundle: Bundle) -> String {
        let web = WebResources.directory(in: bundle)
        func read(_ rel: String) -> String {
            guard let web else { return "" }
            return (try? String(contentsOf: web.appendingPathComponent(rel), encoding: .utf8)) ?? ""
        }

        let body = renderBody(markdown: markdown,
                              markdownIt: read("markdown-it.min.js"),
                              katex: read("katex/katex.min.js"),
                              texmath: read("texmath.js"),
                              hljs: read("hljs/highlight.min.js"))

        return assembleDocument(body: body, web: web, read: read)
    }

    // MARK: JavaScriptCore render

    private static func renderBody(markdown: String, markdownIt: String,
                                   katex: String, texmath: String, hljs: String) -> String {
        guard let ctx = JSContext() else { return escapedPre(markdown) }
        ctx.exceptionHandler = { _, exc in
            log.error("JS exception: \(exc?.toString() ?? "nil", privacy: .public)")
        }
        // JSC has no console / globalThis quirks — provide a stub
        ctx.evaluateScript("var console={log:function(){},warn:function(){},error:function(){},info:function(){}};")
        ctx.evaluateScript("var window=this; var self=this;")
        ctx.evaluateScript(markdownIt)
        ctx.evaluateScript(katex)
        ctx.evaluateScript(texmath)
        ctx.evaluateScript(hljs)
        ctx.evaluateScript(#"""
        var __md = markdownit({
          html: true, linkify: true, typographer: true,
          highlight: function (str, lang) {
            try {
              if (lang && hljs.getLanguage(lang))
                return '<pre class="hljs"><code>' +
                  hljs.highlight(str, { language: lang, ignoreIllegals: true }).value + '</code></pre>';
              return '<pre class="hljs"><code>' + hljs.highlightAuto(str).value + '</code></pre>';
            } catch (e) {
              return '<pre class="hljs"><code>' + __md.utils.escapeHtml(str) + '</code></pre>';
            }
          }
        }).use(texmath, {
          engine: katex,
          delimiters: 'dollars',
          katexOptions: { throwOnError: false, strict: false, output: 'html' }
        });
        function __render(src){ return __md.render(src); }
        """#)

        guard let fn = ctx.objectForKeyedSubscript("__render"),
              let result = fn.call(withArguments: [markdown]),
              !result.isUndefined, !result.isNull,
              let html = result.toString(), !html.isEmpty else {
            log.error("render returned empty — markdown-it/katex failed to load?")
            return escapedPre(markdown)
        }
        return html
    }

    // MARK: HTML document assembly (inline CSS + base64 fonts, no JS)

    private static func assembleDocument(body: String, web: URL?, read: (String) -> String) -> String {
        var katexCSS = read("katex/katex.min.css")
        if let web {
            let fontsDir = web.appendingPathComponent("katex/fonts")
            if let fonts = try? FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil) {
                for f in fonts where f.pathExtension.lowercased() == "woff2" {
                    guard let data = try? Data(contentsOf: f) else { continue }
                    let uri = "data:font/woff2;base64,\(data.base64EncodedString())"
                    katexCSS = katexCSS.replacingOccurrences(of: "fonts/\(f.lastPathComponent)", with: uri)
                }
            }
        }
        let hljsLight = read("hljs/github.min.css")
        let hljsDark = read("hljs/github-dark.min.css")
        let style = read("style.css")

        return """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(katexCSS)</style>
        <style>\(hljsLight)</style>
        <style>@media (prefers-color-scheme: dark){\(hljsDark)}</style>
        <style>\(style)</style>
        </head><body><article id="content">\(body)</article></body></html>
        """
    }

    private static func escapedPre(_ s: String) -> String {
        "<pre>" + s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;") + "</pre>"
    }
}
