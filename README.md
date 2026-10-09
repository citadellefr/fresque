# Fresque

**A real-time collaborative whiteboard for Go servers and Flutter apps.**

Fresque comes in two parts that work together:

- a **Go package** that hosts boards: it keeps each open board in memory, orders
  and relays the edits of everyone connected, and saves the board through your
  own storage;
- a **Flutter package** that draws and edits them: canvas, tools, gestures,
  and the connection to the server.

It is developed by [Citadelle](https://github.com/citadellefr), where it powers
the whiteboards of the Documents app, and is released under the MIT license.

## Features

- **Drawing tools**: pen, highlighter, line, arrow, rectangle, ellipse, text,
  image (SVG included), eraser, selection, move, resize, copy and paste,
  bring to front and send to back, undo and redo. Any width, solid, dashed or
  dotted.
- **Shape correction**: a stroke drawn with Ctrl held becomes the simple
  shape it stands for: line, circle, ellipse, square, rectangle, triangle or
  diamond.
- **Live collaboration**: everyone's cursor, and what they are drawing while
  they draw it. Nobody waits for the server before seeing their own edits.
  Anyone, a read-only viewer included, can follow someone's edits.
- **Every input device**: mouse, touch (two fingers pan and zoom), trackpad
  and stylus with palm rejection. The stylus eraser end erases. Keyboard
  shortcuts are included.
- **Resilient**: edits made while disconnected are sent again on
  reconnection, and never applied twice. Access can be withdrawn at any time.
- **Your storage, your rules**: the server calls a two-method `Store`
  interface. Encryption, quotas and permissions stay in your application.
- **Lightweight**: the Go package depends on [trame](https://github.com/citadellefr/trame),
  which has nothing outside the standard library, and is designed for small
  servers such as a Raspberry Pi.

## How it works

A board is a set of **elements**: strokes, lines, arrows, rectangles, ellipses,
texts and images, each a node of a [trame](https://github.com/citadellefr/trame)
document, stacked by the order of their keys. An edit creates elements, changes
their attributes (their place, their colour, their points) or deletes them.

The hub orders the edits it receives, rebases late ones over those it applied
since, and every client does the same with what arrives: two people moving and
recolouring the same element both see both changes, the last one winning on an
attribute they both changed, and a deletion wins over everything done to the
element meanwhile. A client shows its own edits immediately, keeps them on top
of what the server confirmed, and rolls them back if the server refuses them.
Undo takes back this person's own edits only, and leaves alone what others
changed since.

Performance comes from doing little:

- cursors are relayed after a single scan, and a board is saved only once
  edits pause;
- a slow client is disconnected rather than allowed to hold anyone up. It
  catches up from the board or from the edits it missed when it reconnects;
- the client records committed elements once, in pictures replayed at any
  zoom level. Each picture holds a few hundred neighbours in stacking order,
  so an edit only records its own again;
- strokes are simplified before they are sent. A stroke in progress travels
  as the points added since the previous frame.

## Server (Go)

```sh
go get github.com/citadellefr/fresque
```

```go
hub := fresque.NewHub(store, fresque.Options{})
defer hub.Close(context.Background()) // saves every board with unsaved edits

// In your WebSocket handler, once the request is authenticated and allowed:
err := hub.Serve(ctx, conn, boardID, fresque.Peer{
	ID:       userID,
	Name:     userName,
	Client:   r.URL.Query().Get("client"),
	ReadOnly: !canWrite,
})
```

`conn` is a `*websocket.Conn` from
[gorilla/websocket](https://github.com/gorilla/websocket) or
[fasthttp/websocket](https://github.com/fasthttp/websocket). Any type with the
same methods works. With `EnableCompression` set on your upgrader, the hub
compresses the frames large enough to gain from it, such as the board sent on
connection, and nothing else.

`store` loads and saves board files:

```go
type Store interface {
	Load(ctx context.Context, board string) ([]byte, error)
	Save(ctx context.Context, board string, data []byte) error
}
```

- Cancelling `ctx` disconnects the peer, with the context's cause as the
  reason shown to the user. Use it to apply withdrawn access.
- Returning an error that wraps `fresque.ErrGone` from `Save` tells the hub
  that the board no longer exists. Everyone is disconnected.
- Any other error is shown to the connected users. The save is retried.

`fresque.Options` sets save delays, size limits and the presence rate limit.
The defaults suit most uses.

## Client (Flutter)

```yaml
dependencies:
  fresque:
    git:
      url: https://github.com/citadellefr/fresque.git
      path: dart
```

```dart
import 'package:fresque/fresque.dart';

final session = BoardSession(
  webSocketConnector((clientId) async => Uri.parse('wss://example.com/board?client=$clientId')),
)..start();
final controller = BoardController(session);

// in your widget tree
BoardView(controller: controller);
```

- `BoardController` holds the tool, colour and stroke width, the selection
  and the viewport. Style changes also apply to the selection.
  `follow(peerId)` keeps one peer's edits on screen until the view is panned
  by hand or the peer leaves.
- `BoardSession` exposes the connection status, the other participants,
  whether every edit is saved, undo and redo, and the edits the server
  refused.
- `BoardController.insertImage` puts an image file on the board. The image
  travels inside the board: it is kept as it is when small enough, or scaled
  down and encoded again to stay under the server's default element limit. An
  SVG is rendered once to a sharp picture.
- `exportPng` renders a board to an image, scaled down past 8192 pixels.
  `exportPdf` lays it out on A4 pages instead, one per drawing, never cut,
  rendered a band at a time so that the app keeps running, and reports its
  progress.

The connector is called again on every reconnection. It can fetch a fresh,
short-lived ticket each time.

### Controls

| Input | Action |
| --- | --- |
| One finger, mouse, stylus | use the current tool |
| Ctrl + pen or highlighter | draw a clean shape |
| Corner of the selection | resize: several elements together, in proportion (Shift keeps a shape's proportions) |
| Two fingers, trackpad | pan and zoom |
| Wheel | pan (zoom with Ctrl or ⌘) |
| `Ctrl` + `+` / `-` / `0` | zoom in, zoom out, 100 % |
| Middle button, Space + drag | pan |
| Stylus eraser end | erase |
| `V` `H` `P` `M` `L` `A` `R` `O` `T` `E` | select, hand, pen, highlighter, line, arrow, rectangle, ellipse, text, eraser |
| `Ctrl+Z` / `Ctrl+Shift+Z` or `Ctrl+Y` | undo / redo |
| `Delete`, `Ctrl+A`, `Esc` | delete selection, select all, deselect |
| `Ctrl+C` / `Ctrl+X` / `Ctrl+V` | copy, cut, paste under the mouse; in a browser, `Ctrl+V` also pastes the picture on the clipboard |

## Protocol

trame's: JSON text frames over one WebSocket per board, described in
[its README](https://github.com/citadellefr/trame#protocol). What belongs to
a board:

- every element is a node of type `e` at the root. Its key is its place in
  the stack, `z` written as 11 hexadecimal digits of `z + 2^40`, which sorts as
  the integers do; ties are broken by id (`fresque.Key`, `zKey` in Dart);
- its attributes are the rest of the element: `k`, `x`, `y`, `w`, `h`, `p`,
  `c`, `sw`, `f`, `d`, `tx`, `fs`, `src` (see below). Those a version does not
  know are kept;
- `{"t":"eph","d":{"c":[x,y],"d":{…}}}` is a cursor and a drawing in
  progress, relayed as is.

Element ids are 1 to 64 characters from `[A-Za-z0-9_-]`. `id` and `z` are not
attributes. A stroke in progress is an element that does not exist yet: the
draft of a stroke carries `"o"`, the index of its first new point.

A board that is not made of elements is refused, as is an edit that would grow
it past `MaxElements`, `MaxElementBytes` or `MaxBoardBytes`; deleting is
always allowed.

## File format

```json
{"fresque":1,"elements":[
{"id":"k3J9…","k":"s","z":4,"x":120.5,"y":80,"p":[0,0,1.5,2],"c":4280163870,"sw":3},
{"id":"Qa81…","k":"t","z":5,"x":0,"y":0,"w":84,"h":25,"c":4278190080,"sw":3,"tx":"Hello","fs":20},
{"id":"Zu7c…","k":"i","z":6,"x":40,"y":60,"w":320,"h":240,"c":4278190080,"sw":2,"src":"data:image/jpeg;base64,…"}
]}
```

| Key | Meaning |
| --- | --- |
| `k` | kind: `s` stroke, `l` line, `a` arrow, `r` rectangle, `e` ellipse, `g` polygon, `t` text, `i` image |
| `x`, `y` | origin |
| `w`, `h` | size of shapes, texts and images |
| `p` | points, relative to the origin |
| `c` | ARGB colour |
| `sw` | stroke width |
| `f` | filled shape |
| `d` | outline: `1` dashed, `2` dotted, solid when absent |
| `tx`, `fs` | text and font size |
| `src` | picture of an image, as a data URL |
| `z` | stacking order, ties broken by id |

The file has one element per line, sorted by id, `id` and `z` first and then
the attributes sorted by name. Saving the same board twice produces the same
bytes, which suits backups and diffs. A file written by an earlier version is
read as it is, and written back in this order.

## Development

```sh
go test -race ./...
cd dart && flutter analyze && flutter test
```

Issues and pull requests are welcome.

## License

[MIT](LICENSE) © 2026 Citadelle
