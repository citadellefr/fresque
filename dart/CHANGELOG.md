# Changelog

## 0.2.0

- Images: `BoardController.insertImage` puts an image file on the board. The
  picture travels inside the board as a data URL, kept as it is when small
  enough, otherwise scaled down and encoded again (JPEG, or PNG when it has
  transparency) to stay under the server's default element limit. Images are
  moved, stacked, erased and exported like any element; older clients leave
  them alone.
- Zoom: Ctrl and the wheel zoom on the web too, where the browser reports them
  as a pinch. Ctrl with `+`, `-` or `0` zooms in, out and back to 100 %, and
  `BoardController.zoomBy` zooms around the middle of the view.

## 0.1.1

- Text tool: typing works. The field takes the focus, a tap inside it moves
  the caret instead of closing it, it follows the view while panning and
  zooming, and looks the same being edited as once drawn.
- Client: an edit records again only the few hundred elements around it rather
  than the whole board; new elements no longer sort the board, the eraser only
  tests what it sweeps, and the grid allocates nothing per dot.
- Server: presence frames are relayed after a single scan, element ids are
  read without decoding the element (loading a board is twice as fast), and
  frames of 4 KiB or more are compressed when the connection negotiated it.
  Ids written with escapes or twice in one element are now refused.

## 0.1.0

First release.

- Go hub: in-memory boards, edits ordered by the server, debounced saves
  through a `Store`, presence relay with rate limiting, resumable clients,
  access revocation through the context.
- Flutter client: `BoardView` with pen, highlighter, line, arrow, rectangle,
  ellipse, text, eraser and selection tools; mouse, touch, trackpad and stylus
  input; undo and redo; offline edits; PNG export.
