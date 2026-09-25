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
  eraser, selection, move, bring to front and send to back, undo and redo.
- **Live collaboration**: everyone's cursor, and what they are drawing while
  they draw it. Nobody waits for the server before seeing their own edits.
- **Every input device**: mouse, touch (two fingers pan and zoom), trackpad
  and stylus with palm rejection. The stylus eraser end erases. Keyboard
  shortcuts are included.
- **Resilient**: edits made while disconnected are sent again on
  reconnection, and never applied twice. Access can be withdrawn at any time.
- **Your storage, your rules**: the server calls a two-method `Store`
  interface. Encryption, quotas and permissions stay in your application.
- **Lightweight**: the Go package has no dependency outside the standard
  library and is designed for small servers such as a Raspberry Pi.

## How it works

A board is a set of **elements**: strokes, lines, arrows, rectangles, ellipses
and texts. An edit replaces or deletes whole elements.

The server applies edits in the order it receives them, and every client
applies them in that same order. The last write of an element wins, and all
clients converge on the same board. There is no merge algorithm to reason
about. A client shows its own edits immediately, keeps them on top of what the
server confirmed, and rolls them back if the server refuses them.

Performance comes from doing little:

- the server reads nothing but element ids, without decoding the rest. It
  relays cursors after a single scan, assembles frames by appending bytes and
  saves a board only once edits pause;
- a slow client is disconnected rather than allowed to hold anyone up. It
  catches up from the full board when it reconnects;
- the client records committed elements once, in pictures replayed at any
  zoom level. Each picture holds a few hundred neighbours in stacking order,
  so an edit only records its own again;
- strokes are simplified before they are sent. A stroke in progress travels
  as the points added since the previous frame.

On a laptop CPU, relaying an edit to eight participants takes about 24 µs.

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
- `BoardSession` exposes the connection status, the other participants,
  whether every edit is saved, undo and redo, and the edits the server
  refused.
- `exportPng` renders a board to an image.

The connector is called again on every reconnection. It can fetch a fresh,
short-lived ticket each time.

### Controls

| Input | Action |
| --- | --- |
| One finger, mouse, stylus | use the current tool |
| Two fingers, trackpad | pan and zoom |
| Wheel | pan (zoom with Ctrl or ⌘) |
| Middle button, Space + drag | pan |
| Stylus eraser end | erase |
| `V` `H` `P` `M` `L` `A` `R` `O` `T` `E` | select, hand, pen, highlighter, line, arrow, rectangle, ellipse, text, eraser |
| `Ctrl+Z` / `Ctrl+Shift+Z` or `Ctrl+Y` | undo / redo |
| `Delete`, `Ctrl+A`, `Esc` | delete selection, select all, deselect |

## Protocol

JSON text frames over one WebSocket per board.

| From | Frame | Meaning |
| --- | --- | --- |
| client | `{"t":"op","n":7,"put":[…],"del":["id"]}` | edit number `n` of this client |
| client | `{"t":"eph","d":{…}}` | cursor and drawing in progress, relayed as is |
| server | `{"t":"hello","sid":3,"ack":6,"v":41,"saved":40,"ro":false,"peers":[…],"elements":[…]}` | the whole board, and the last edit of this client already applied |
| server | `{"t":"op","sid":2,"put":[…],"del":[…]}` | someone else's edit |
| server | `{"t":"ack","n":7,"v":42}` | own edit applied, as board version `v` |
| server | `{"t":"nack","n":7,"error":"…"}` | own edit refused |
| server | `{"t":"eph","sid":2,"d":{…}}` | someone else's cursor and drawing in progress |
| server | `{"t":"join","peer":{…}}` / `{"t":"leave","sid":2}` | presence |
| server | `{"t":"saved","v":42}` / `{"t":"error","error":"…"}` | board saved up to version `v`, or save failed |

Close codes: `4000` board could not be loaded, `4001` access withdrawn, `4002`
connection too slow, `4003` server shutting down. Each one carries a reason.

Element ids are 1 to 64 characters from `[A-Za-z0-9_-]`, written without
escapes, once per element. Beyond its id, an element is opaque to the server.

## File format

```json
{"fresque":1,"elements":[
{"id":"k3J9…","k":"s","z":4,"x":120.5,"y":80,"p":[0,0,1.5,2],"c":4280163870,"sw":3},
{"id":"Qa81…","k":"t","z":5,"x":0,"y":0,"w":84,"h":25,"c":4278190080,"sw":3,"tx":"Hello","fs":20}
]}
```

| Key | Meaning |
| --- | --- |
| `k` | kind: `s` stroke, `l` line, `a` arrow, `r` rectangle, `e` ellipse, `t` text |
| `x`, `y` | origin |
| `w`, `h` | size of shapes and texts |
| `p` | points, relative to the origin |
| `c` | ARGB colour |
| `sw` | stroke width |
| `f` | filled shape |
| `tx`, `fs` | text and font size |
| `z` | stacking order, ties broken by id |

The file has one element per line, sorted by id. Saving the same board twice
produces the same bytes, which suits backups and diffs.

## Development

```sh
go test -race ./...
go test -run - -bench . ./...
cd dart && flutter analyze && flutter test
```

Issues and pull requests are welcome.

## License

[MIT](LICENSE) © 2026 Citadelle
