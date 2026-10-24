# org-appear-mathjax

MathJax previews for Org mode that reveal their source only while point is
inside a formula.

The package uses Org's own syntax parser for formula detection and a persistent
MathJax worker for rendering. It does not require a TeX installation.

## Features

- Reveal source at point and restore the preview after leaving the formula.
- Support `$...$`, `$$...$$`, `\(...\)`, `\[...\]`, and LaTeX environments.
- Ignore delimiter-like text in source, example, and comment blocks.
- Render asynchronously and cache color-independent SVG results on disk.
- Update previews after edits, theme changes, and font scaling.
- Optionally show a framed live preview below display-math source while editing.
- Work independently of `org-appear`; both modes can be enabled together.

## Requirements

- Emacs 29.1 or newer with SVG image support
- Org 9.6 or newer
- [mathjax.el](https://github.com/astoff/mathjax.el) 0.1 or newer
- Node.js available on `exec-path`

No LaTeX distribution is needed.

## Installation

Install the `mathjax` dependency with `M-x package-install RET mathjax RET`,
then clone this repository and add it to `load-path`.

With `use-package`:

```elisp
(use-package org-appear-mathjax
  :ensure nil
  :load-path "~/src/org-appear-mathjax"
  :hook (org-mode . org-appear-mathjax-mode))
```

Without `use-package`:

```elisp
(add-to-list 'load-path "~/src/org-appear-mathjax")
(require 'org-appear-mathjax)
(add-hook 'org-mode-hook #'org-appear-mathjax-mode)
```

You can also enable the mode manually in an Org buffer with
`M-x org-appear-mathjax-mode`.

## Configuration

The defaults favor math aligned with the surrounding text baseline:

```elisp
(setq org-appear-mathjax-scale 1.0
      org-appear-mathjax-inline-ascent 'baseline
      org-appear-mathjax-center-display t
      org-appear-mathjax-edit-preview nil)
```

For Xenops-style vertically centered images, use:

```elisp
(setq org-appear-mathjax-inline-ascent 'center)
```

Adjust `org-appear-mathjax-scale` to suit your font and display. Values below
`1.0` make previews smaller; values above `1.0` make them larger.

| Option | Default | Purpose |
| --- | --- | --- |
| `org-appear-mathjax-scale` | `1.0` | Preview scale relative to the source font's x-height |
| `org-appear-mathjax-inline-ascent` | `baseline` | Inline vertical alignment: `baseline` or `center` |
| `org-appear-mathjax-center-display` | `t` | Center display formulas in reading mode |
| `org-appear-mathjax-edit-preview` | `nil` | Show a framed live preview while editing display math |
| `org-appear-mathjax-delay` | `0.2` | Idle delay in seconds before reconciling edits |
| `org-appear-mathjax-macros` | `""` | TeX macro definitions prepended to every formula |
| `org-appear-mathjax-cache-directory` | platform cache directory | Location of cached SVG geometry |
| `org-appear-mathjax-timeout` | `30` | Worker response timeout in seconds |

The `org-appear-mathjax-source` and `org-appear-mathjax-preview` faces control
the optional editing panel.

## Commands

- `org-appear-mathjax-mode`: toggle previews in the current Org buffer.
- `org-appear-mathjax-refresh`: rescan all formulas in the current buffer.
  With a prefix argument, also invalidate this buffer's cached formulas.
- `org-appear-mathjax-show-error`: show the complete MathJax diagnostic for the
  formula at point.
- `org-appear-mathjax-stop`: stop the shared worker. The next uncached request
  starts it again.

## Limitations

MathJax and TeX have different fonts and glyph metrics, so previews are not
pixel-identical to Xenops or Org's native LaTeX previews. Manual `\tag` is
supported; document-wide automatic equation numbering and cross-formula
references are not implemented.

## Development

Run the test and validation targets from the repository root:

```sh
make test       # ERT tests, including a real MathJax render
make compile    # Byte compilation with warnings treated as errors
make checkdoc   # Check documentation strings
make check      # All of the above
make clean      # Remove generated files
```

The commands initialize `package.el`, so `org` and `mathjax` must be installed
in the package directory visible to Emacs. `make lint` additionally runs
`package-lint` when that development dependency is installed.

## Attribution

This package is adapted from Thysrael's
[`markdown-ts-appear-mathjax`](https://github.com/Thysrael/markdown-ts-appear).
The MathJax worker, cache, rendering, and editing presentation derive from that
implementation. Org syntax detection and Org minor-mode integration are
specific to this package.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
