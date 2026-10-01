# Changelog

## 0.6.0

- Shape correction keeps to simple shapes: a line, an ellipse or a circle, a
  rectangle or a square, a triangle, or a diamond, its corners set on the
  middles of its sides. A stroke standing for anything else stays as drawn.
- Resizing: the corners of any single selected element but a text can be
  dragged, so polygons, lines, arrows and strokes stretch too. A stroke keeps
  its proportions like an image. `BoardElement.box` is what an element spans
  without its stroke width, `BoardElement.fitted` stretches it to another
  box, and `canResize` replaces `isSized`.
- Copy and paste: `BoardController.copySelection`, `cutSelection` and
  `paste`, Ctrl+C, Ctrl+X and Ctrl+V in the view. Pasting puts the copy on top,
  under the mouse, selected. What is copied is shared by every board of the
  app.
- `exportPdf` no longer freezes the app: each page is drawn in bands, waiting
  between them, and compressed in another isolate, or by the browser on the
  web. `onProgress` tells how many pages are done. Pages are capped at
  300 dpi.
- `exportPdf` lays out drawings rather than shapes: elements less than an
  inch apart stay together, and so does what lies near a drawing compared
  with its size, so that a stroke beside a drawing, or two drawings side by
  side, are no longer parted. Drawings that fit together on A4 share a page,
  and pages come row by row, each row from the left.
- No longer depends on `archive`.

## 0.5.0

- Shape correction: a pen or highlighter stroke drawn with Ctrl (or ⌘) held
  becomes the shape it stands for, shown as such while drawing: a straight
  line, levelled when nearly so, an ellipse or a circle, a rectangle or a
  square, or a polygon of up to eight sides. `recognizeShape` is not exported:
  the view does it.
- Polygons: a new kind, `g`, closed and straight-sided, which can be filled.
  Older clients leave them alone.
- Dashes: `BoardController.dash` draws lines, strokes and shapes dashed or
  dotted, stored as `d` and restyling the selection like the other settings.
- Resizing: the corners of a single selected image, rectangle or ellipse can be
  dragged. An image keeps its proportions, a shape keeps them with Shift.
- SVG images: `insertImage` takes SVG files, rendered once to a picture
  1600 pixels long and drawn at the size the file declares. Adds
  `flutter_svg`.

## 0.4.0

- Following: `BoardController.follow` keeps the edits of one peer on screen,
  by peer id. The view moves as little as it can to show what they draw, add
  or erase, zooms out only when that would not fit, and jumps to where they
  last edited as soon as following starts. Panning by hand, or the peer
  leaving, stops it. `BoardController.reveal` brings any area into view.
- `BoardPeer.lastEdit` is where a peer last changed the board, their drawing
  in progress included, and `BoardSession.edits` tells when it moves.

## 0.3.1

- `exportPdf` no longer cuts through shapes: elements less than the margin
  apart form groups, and each page gathers whole groups that fit together on
  A4. A group larger than A4 gets a page of its own, scaled down to it but
  still rendered at full resolution.

## 0.3.0

- `exportPdf` renders a board to a PDF: the drawing is cut at its real size
  into A4 pages, turned like the drawing, each page rendered at full
  resolution and stored without loss. A large board takes more pages instead
  of being scaled down as `exportPng` does past 8192 pixels. Pages the cut
  leaves blank are skipped.

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
