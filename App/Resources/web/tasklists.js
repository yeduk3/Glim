/* Glim task lists — GitHub-style clickable checkboxes for `- [ ] x` / `- [x] x`.
   Stock markdown-it has no task-list support (it renders the literal "[ ] x"), so this
   core-ruler plugin rewrites list items whose text starts with a `[ ]`/`[x]` marker into
   <li class="task-item"><input type="checkbox" …>…. The app WKWebView and the Quick Look
   extension share it (like anchors.js). Loaded after anchors.js; also used by JSRenderer.

   Each checkbox carries data-task-line = the list item's 0-based SOURCE line (from the
   list_item token's .map), so the app can toggle the exact source line on a click.

   opts.interactive: true  -> inputs are enabled (app view mode, clicks toggle the source)
                     false -> inputs get `disabled` (Quick Look, static preview). */
(function (global) {
  // A leading task marker: "[ ] ", "[x] " or "[X] " (one trailing whitespace).
  var MARKER = /^\[([ xX])\]\s/;

  function isInline(t)        { return t && t.type === 'inline'; }
  function isParagraphOpen(t) { return t && t.type === 'paragraph_open'; }
  function isListItemOpen(t)  { return t && t.type === 'list_item_open'; }

  function addClass(token, cls) {
    var existing = token.attrGet('class');
    token.attrSet('class', existing ? existing + ' ' + cls : cls);
  }

  global.glimTaskLists = function (md, opts) {
    opts = opts || {};
    var interactive = !!opts.interactive;

    // Runs after inline parsing so the inline token's children (text runs) exist.
    md.core.ruler.after('inline', 'glim_task_lists', function (state) {
      var tokens = state.tokens;
      for (var i = 2; i < tokens.length; i++) {
        if (!isInline(tokens[i])) continue;
        // Shape of a list item: list_item_open, paragraph_open, inline, …
        // (paragraph_open is present even in tight lists, just hidden.)
        if (!isParagraphOpen(tokens[i - 1])) continue;
        var li = tokens[i - 2];
        if (!isListItemOpen(li)) continue;

        var m = MARKER.exec(tokens[i].content);
        if (!m) continue;
        var checked = (m[1] === 'x' || m[1] === 'X');
        var line = (li.map && li.map.length) ? li.map[0] : 0;

        addClass(li, 'task-item');

        // Strip the marker from the inline content and its first text child so the
        // visible label no longer shows "[ ] ".
        tokens[i].content = tokens[i].content.replace(MARKER, '');
        var children = tokens[i].children || [];
        if (children.length && children[0].type === 'text') {
          children[0].content = children[0].content.replace(MARKER, '');
        }

        // Prepend the checkbox as a raw-HTML inline token.
        var box = new state.Token('html_inline', '', 0);
        box.content = '<input type="checkbox" data-task-line="' + line + '"' +
          (checked ? ' checked' : '') + (interactive ? '' : ' disabled') + '> ';
        children.unshift(box);
        tokens[i].children = children;
      }
    });
    return md;
  };
})(typeof window !== 'undefined' ? window : this);
