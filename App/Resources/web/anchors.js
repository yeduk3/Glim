/* Glim heading anchors — GitHub-style slugged ids for h1–h6.
   markdown-it emits no heading ids, so in-document links like [x](#section) are dead.
   This plugin adds id="slug" to every heading so the fragment scroll works (app WKWebView
   and the Quick Look extension share it). Loaded before render.js; also used by JSRenderer.

   Slug rules (GitHub): lowercase; keep Unicode letters/digits (Korean survives); spaces
   -> '-'; strip other punctuation; duplicate slugs get -1, -2, … suffixes.

   The seen-map is LOCAL to each ruler invocation (the core ruler runs once per parse), so
   re-rendering the same document does NOT accumulate suffixes across renders. */
(function (global) {
  function slugify(text) {
    return text
      .trim()
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\s-]/gu, '') // drop punctuation/symbols; keep letters, digits, spaces, hyphens
      .replace(/\s+/g, '-');             // spaces -> single hyphen
  }

  // Heading text = concatenated text/inline-code of the heading's inline token children,
  // falling back to raw content. (Runs after inline parsing, so children exist.)
  function headingText(inline) {
    if (!inline) return '';
    if (inline.children && inline.children.length) {
      var out = '';
      for (var i = 0; i < inline.children.length; i++) {
        var c = inline.children[i];
        if (c.type === 'text' || c.type === 'code_inline') out += c.content;
      }
      return out;
    }
    return inline.content || '';
  }

  global.glimAnchors = function (md) {
    md.core.ruler.push('glim_heading_anchors', function (state) {
      var seen = Object.create(null); // local per parse -> resets each render
      var tokens = state.tokens;
      for (var i = 0; i < tokens.length; i++) {
        if (tokens[i].type !== 'heading_open') continue;
        var base = slugify(headingText(tokens[i + 1])) || 'section';
        var slug = base;
        if (base in seen) { seen[base] += 1; slug = base + '-' + seen[base]; }
        else { seen[base] = 0; }
        tokens[i].attrSet('id', slug);
      }
    });
    return md;
  };
})(typeof window !== 'undefined' ? window : this);
