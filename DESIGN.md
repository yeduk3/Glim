# Glim Design Philosophy

Glim is a native macOS Markdown viewer. Its design follows one rule above all:

> **The document is the interface.** Chrome recedes, content leads.

Everything below serves that rule. When a decision is unclear, choose whatever
makes the *content* read better and the *app* feel more like a part of macOS —
not like a web page in a window.

---

## 1. Principles

1. **Native first.** Every color, font, control, and spacing value derives from
   the macOS system, never from a hand-picked palette. If AppKit has a semantic
   color or a standard control for it, use that. The rendered page uses the same
   system colors as the chrome around it, so the two never disagree.

2. **Hierarchy through type, space, and color — not chrome.** Importance is
   shown by size, weight, and label tier (primary → secondary → tertiary) and by
   the space around an element. Rules, boxes, and borders are a last resort, used
   only to separate, never to decorate. (This is why headings carry no underline:
   their size and weight already rank them.)

3. **One rhythm.** Spacing, type sizes, and bar metrics come from a small shared
   scale. The same gap means the same thing everywhere. Consistency is what makes
   a multi-surface app (preview, editor, sidebar, bars) feel like one tool.

4. **Adapt automatically.** Light/dark and the user's accent color are the
   system's choice, not ours. Semantic colors track them with zero extra code —
   no `prefers-color-scheme` branches, no accent constant to maintain.

5. **Quiet by default.** Status, lint, and warnings live in the lowest tier of
   the hierarchy and appear only when they have something to say. They never
   compete with the document.

---

## 2. Color — semantic, system-driven

The rendered page (CSS) and the chrome (AppKit/SwiftUI) draw from the *same*
NSColor semantics. macOS resolves them per appearance and accent.

| Role            | AppKit (Swift)              | CSS (WKWebView)                | Used for                          |
|-----------------|-----------------------------|--------------------------------|-----------------------------------|
| Primary text    | `NSColor.labelColor`        | `-apple-system-label`          | body, headings                    |
| Secondary text  | `.secondaryLabelColor`      | `-apple-system-secondary-label`| muted text, h5, captions          |
| Tertiary text   | `.tertiaryLabelColor`       | `-apple-system-tertiary-label` | h6, list markers, faint readouts  |
| Page surface    | `.textBackgroundColor`      | `-apple-system-text-background`| document background (view & edit) |
| Hairline        | `.separatorColor`           | `-apple-system-separator`      | rules, table & bar dividers       |
| Accent          | `Color.accentColor`         | `AccentColor`                  | links, selection, active controls |
| Subtle fill     | `.quaternary` ShapeStyle    | `color-mix(... var(--fg) 6%)`  | code/table fills, pills           |

**Rules**
- No hex literals for UI. (Third-party token colors — KaTeX, highlight.js — are
  the only exception, and they sit *inside* a system-colored block.)
- Accent is for interaction and links only. Never accent-tint body text or icons
  that aren't actionable.
- Fills are translucent (`color-mix` over the text color), so one value works in
  both light and dark and layers correctly over any surface.

---

## 3. Typography

System font everywhere (`-apple-system` / SF). Reading body is `16px / 1.65`.
The raw editor is monospace (SF Mono) — the correct, native register for source.

**Heading scale** — size + weight + tier carry the hierarchy; no borders.

| Level | Size    | Weight | Tier      |
|-------|---------|--------|-----------|
| h1    | 2.0em   | 700    | primary   |
| h2    | 1.5em   | 700    | primary   |
| h3    | 1.25em  | 600    | primary   |
| h4    | 1.05em  | 600    | primary   |
| h5    | 1.0em   | 600    | secondary |
| h6    | 0.85em  | 600    | tertiary, uppercase + tracking |

Headings group **down**: top margin is larger than bottom margin, so a heading
binds to the content it introduces, not the content above it.

---

## 4. Spacing rhythm

Block gap is `1em`. Heading top is `1.5em`, heading bottom `0.5em`. Section
rules (`hr`) get `2em`. The reading column is capped at **760px** and centered;
full-width is an explicit, animated opt-in.

**Secondary chrome bars** (find, lint, external-change, selection readout) share
one metric so they read as one family:

- Material: `.bar`
- Padding: `12pt` horizontal, `6pt` vertical (slim readouts may use `4pt`)
- Separated from the document by a hairline `Divider`
- Text: `.caption`; a leading SF Symbol in `.secondary`

---

## 5. Layout & placement

- **Split view** (`NavigationSplitView`): sidebar + detail, the macOS standard
  for browse-then-read.
- **Sidebar**: native `.sidebar` list. Folder name is the section header; the
  open file is **semibold**; Markdown files take the accent doc icon, other files
  a `.secondary` icon — icon tint *is* the file-type hierarchy.
- **Toolbar**: trailing primary actions only (full-width toggle, view/edit
  segmented control) — the document owns the rest of the window.
- **Bars stack** between toolbar and document, top to bottom, in descending
  urgency: external-change → find → document → selection readout. Each is
  hairline-separated and disappears when irrelevant.

---

## 6. Motion

Motion is for continuity, never decoration. Only two transitions exist, both
~0.22s ease: the full-width column grow/shrink (preview and editor share the
curve) and the sidebar reveal/collapse. Everything else is instant.

---

*This document is the source of truth for Glim's look. Code that sets a color,
size, or spacing value should be traceable to a rule here. If it can't be, either
the code is wrong or this document needs a new rule — fix one of them.*
