# Changelog

## 0.1.0

First release.

- Go hub: in-memory boards, edits ordered by the server, debounced saves
  through a `Store`, presence relay with rate limiting, resumable clients,
  access revocation through the context.
- Flutter client: `BoardView` with pen, highlighter, line, arrow, rectangle,
  ellipse, text, eraser and selection tools; mouse, touch, trackpad and stylus
  input; undo and redo; offline edits; PNG export.
