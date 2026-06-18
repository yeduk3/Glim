/* glue: markdown-it + texmath(KaTeX) + highlight.js */
'use strict';

const md = window.markdownit({
  html: true,
  linkify: true,
  typographer: true,
  breaks: false,
  highlight: function (str, lang) {
    if (lang && window.hljs.getLanguage(lang)) {
      try {
        return '<pre class="hljs"><code>' +
          window.hljs.highlight(str, { language: lang, ignoreIllegals: true }).value +
          '</code></pre>';
      } catch (e) {}
    }
    try {
      return '<pre class="hljs"><code>' +
        window.hljs.highlightAuto(str).value + '</code></pre>';
    } catch (e) {}
    return '<pre class="hljs"><code>' + md.utils.escapeHtml(str) + '</code></pre>';
  }
}).use(texmath, {
  engine: window.katex,
  delimiters: 'dollars',
  katexOptions: { throwOnError: false, strict: false, output: 'htmlAndMathml' }
});

// ---- source-line mapping (for rendered<->raw scroll sync) -------------------
// Tag every top-level block with the 0-based source line it starts on. Most
// block tokens render through renderToken/renderAttrs, so setting the attr is
// enough; fenced code is special-cased because our `highlight` returns raw <pre>.
md.core.ruler.push('qmd_source_line', function (state) {
  for (const t of state.tokens) {
    if (!t.map || t.level !== 0) continue;
    if (t.nesting === 1 || t.type === 'hr' || t.type === 'code_block' ||
        t.type === 'fence' || t.type === 'html_block') {
      t.attrSet('data-source-line', String(t.map[0]));
    }
  }
});

const baseFence = md.renderer.rules.fence;
md.renderer.rules.fence = function (tokens, idx, options, env, slf) {
  let out = baseFence ? baseFence(tokens, idx, options, env, slf)
                      : slf.renderToken(tokens, idx, options);
  const t = tokens[idx];
  if (t.map && out.indexOf('data-source-line') === -1) {
    out = out.replace(/<pre/, '<pre data-source-line="' + t.map[0] + '"');
  }
  return out;
};

// Render markdown source into #content, preserving scroll ratio when possible.
window.renderMarkdown = function (src) {
  const el = document.getElementById('content');
  const prevRatio = (document.body.scrollHeight > window.innerHeight)
    ? window.scrollY / (document.body.scrollHeight - window.innerHeight)
    : 0;
  el.innerHTML = md.render(src || '');
  const max = document.body.scrollHeight - window.innerHeight;
  if (max > 0) window.scrollTo(0, prevRatio * max);
};

// ---- font zoom -------------------------------------------------------------
// Scale every text size off the body font-size. Headings, code, KaTeX, etc. are
// all sized in `em`, so scaling the body cascades to the whole document.
window.qmdSetFontScale = function (scale) {
  var s = (typeof scale === 'number' && scale > 0) ? scale : 1;
  document.body.style.fontSize = (16 * s) + 'px';
};

// ---- full-width toggle -----------------------------------------------------
// When on, content fills the viewport width; when off (default) it stays capped
// to a readable measure and centered. Kept in sync with the raw editor.
window.qmdSetFullWidth = function (full) {
  document.body.classList.toggle('full-width', !!full);
  // Enable the width transition only after the initial apply has painted, so opening
  // a doc that was saved full-width snaps to width instead of animating on load.
  if (!window.__qmdWidthAnim) {
    window.__qmdWidthAnim = true;
    requestAnimationFrame(function () {
      requestAnimationFrame(function () { document.body.classList.add('anim'); });
    });
  }
};

// ---- scroll sync API -------------------------------------------------------
// 0-based source line of the block at the top of the viewport (interpolated).
window.qmdGetTopLine = function () {
  const els = document.querySelectorAll('[data-source-line]');
  let prev = null;
  for (const el of els) {
    const r = el.getBoundingClientRect();
    const l = parseInt(el.getAttribute('data-source-line'), 10);
    if (isNaN(l)) continue;
    if (r.top <= 0) { prev = { l: l, top: r.top }; continue; }
    if (prev) {
      const span = (r.top - prev.top) || 1;
      const f = Math.max(0, Math.min(1, (0 - prev.top) / span));
      return Math.round(prev.l + (l - prev.l) * f);
    }
    return l;
  }
  return prev ? prev.l : 0;
};

// Scroll so that source `line` sits at the top of the viewport.
window.qmdScrollToLine = function (line) {
  const els = document.querySelectorAll('[data-source-line]');
  if (!els.length) return;
  let lo = null, hi = null;
  for (const el of els) {
    const l = parseInt(el.getAttribute('data-source-line'), 10);
    if (isNaN(l)) continue;
    if (l <= line) lo = { l: l, el: el };
    if (l >= line) { hi = { l: l, el: el }; break; }
  }
  const topOf = function (e) { return e.getBoundingClientRect().top + window.scrollY; };
  let y;
  if (lo && hi && hi.l !== lo.l) {
    const a = topOf(lo.el), b = topOf(hi.el);
    y = a + (b - a) * ((line - lo.l) / (hi.l - lo.l));
  } else if (lo) { y = topOf(lo.el); }
  else if (hi) { y = topOf(hi.el); }
  else return;
  window.scrollTo(0, Math.max(0, y));
};

let qmdScrollTimer = null;
window.addEventListener('scroll', function () {
  if (qmdScrollTimer) return;
  qmdScrollTimer = setTimeout(function () {
    qmdScrollTimer = null;
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.scroll;
    if (h) h.postMessage(window.qmdGetTopLine());
  }, 80);
}, { passive: true });

// ---- selection character count ---------------------------------------------
// Report the selected text's length (code points, ~user-visible chars) to native,
// debounced. 0 when the selection is empty/collapsed so the readout hides.
let qmdSelTimer = null;
function qmdReportSelection() {
  const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selection;
  if (!h) return;
  const s = window.getSelection();
  const str = (s && !s.isCollapsed) ? s.toString() : '';
  h.postMessage(str ? Array.from(str).length : 0);
}
document.addEventListener('selectionchange', function () {
  if (qmdSelTimer) return;
  qmdSelTimer = setTimeout(function () { qmdSelTimer = null; qmdReportSelection(); }, 120);
});

// ---- in-page find ----------------------------------------------------------
window.qmdCountMatches = function (q, caseSensitive) {
  if (!q) return 0;
  const text = document.body.innerText || '';
  const hay = caseSensitive ? text : text.toLowerCase();
  const needle = caseSensitive ? q : q.toLowerCase();
  if (!needle) return 0;
  let n = 0, i = 0;
  while ((i = hay.indexOf(needle, i)) !== -1) { n++; i += needle.length; }
  return n;
};

// `fresh` (new query) searches from the document start; otherwise continues
// from the current selection so next/prev step through matches.
window.qmdFind = function (q, caseSensitive, backwards, fresh) {
  const sel = window.getSelection();
  if (!q) { sel.removeAllRanges(); return false; }
  if (fresh) sel.removeAllRanges();
  return window.find(q, !!caseSensitive, !!backwards, true, false, false, false);
};

// ---- link handling ---------------------------------------------------------
// Route every link click to native (open .md in qmd, files in their default app,
// http/mailto in the browser) instead of letting WebKit navigate. In-page anchors
// (href="#...") are left alone so the page scrolls to the heading as usual.
document.addEventListener('click', function (e) {
  const a = e.target.closest && e.target.closest('a[href]');
  if (!a) return;
  const href = a.getAttribute('href');
  if (!href || href.charAt(0) === '#') return;
  e.preventDefault();
  const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.openLink;
  if (h) h.postMessage(href);
}, true);

// signal native side that the page is ready
if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ready) {
  window.webkit.messageHandlers.ready.postMessage('ready');
}
