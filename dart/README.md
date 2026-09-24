# fresque

The Flutter client of [Fresque](https://github.com/citadellefr/fresque), a
real-time collaborative whiteboard: canvas, drawing tools, gestures and the
connection to the Go server.

```dart
import 'package:fresque/fresque.dart';

final session = BoardSession(
  webSocketConnector((clientId) async => Uri.parse('wss://example.com/board?client=$clientId')),
)..start();
final controller = BoardController(session);

BoardView(controller: controller);
```

See the [repository README](https://github.com/citadellefr/fresque#readme)
for the server side, the protocol and the file format.
