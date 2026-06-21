# Glim demo

A minimal native Markdown editor. **View** renders, **Edit** is raw + lint.

## Math (KaTeX, offline)

Inline: the mass–energy relation $E = mc^2$ and Euler's identity $e^{i\pi} + 1 = 0$.

Display:

$$
\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
\qquad
\frac{\partial u}{\partial t} = \alpha \nabla^2 u
$$

A matrix:

$$
A = \begin{pmatrix} a & b \\ c & d \end{pmatrix},\quad \det A = ad - bc
$$

## Code

```swift
func greet(_ name: String) -> String {
    "Hello, \(name)!"
}
```

## Table

| Feature      | View | Edit |
|--------------|:----:|:----:|
| Rendering    |  ✅  |  —   |
| Raw + lint   |  —   |  ✅  |
| LaTeX        |  ✅  |  ✅  |

## List

- [x] WKWebView + KaTeX bundled
- [x] Sidebar file tree
- [ ] Your notes here

> Press **space** in Finder for Quick Look.
