import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'board.dart';
import 'element.dart';

/// The text link to the server, behind an interface so that sessions can be
/// tested without one.
abstract interface class BoardTransport {
  Stream<String> get messages;
  int? get closeCode;
  String? get closeReason;
  void send(String data);
  Future<void> close();
}

/// Opens a transport for the session whose client id is given; called again
/// on every reconnection.
typedef BoardConnector = Future<BoardTransport> Function(String clientId);

/// A connector over WebSocket. [url] is asked again on every connection, so
/// it may carry a short-lived ticket.
BoardConnector webSocketConnector(Future<Uri> Function(String clientId) url) => (clientId) async {
  final channel = WebSocketChannel.connect(await url(clientId));
  await channel.ready;
  return _WebSocketTransport(channel);
};

class _WebSocketTransport implements BoardTransport {
  _WebSocketTransport(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<String> get messages =>
      _channel.stream.map((m) => m is String ? m : utf8.decode(m as List<int>));

  @override
  int? get closeCode => _channel.closeCode;

  @override
  String? get closeReason => _channel.closeReason;

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  Future<void> close() async => _channel.sink.close();
}

enum BoardStatus { connecting, online, offline, closed }

/// Why the server ended the session: the board could not be opened, or access
/// to it was withdrawn. [reason] is the server's own words.
class BoardClosed implements Exception {
  const BoardClosed(this.code, this.reason);

  final int code;
  final String reason;

  @override
  String toString() => reason;
}

class BoardPeer {
  BoardPeer._(this.sid, this.id, this.name, this.readOnly);

  final int sid;
  final String id;
  final String name;
  final bool readOnly;

  Offset? _cursor;
  BoardElement? _draft;

  Offset? get cursor => _cursor;

  /// What the peer is drawing right now, before it becomes an element.
  BoardElement? get draft => _draft;
}

class _Change {
  _Change(this.before, this.after);

  final Map<String, BoardElement?> before;
  final Map<String, BoardElement?> after;
}

class _Presence extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// One person's connection to a board: keeps [board] in step with the server,
/// sends local edits, reconnects when the link drops and keeps the history
/// [undo] and [redo] walk through.
class BoardSession extends ChangeNotifier {
  BoardSession(this._connect, {String? clientId}) : clientId = clientId ?? randomId();

  static const _historyLimit = 200;
  static const _presenceEvery = Duration(milliseconds: 40);
  static const _backoff = [1, 2, 5, 10, 20, 30];

  final BoardConnector _connect;
  final String clientId;
  final board = Board();

  /// Notifies cursor and draft changes, far more frequent than the others.
  final Listenable presence = _Presence();

  final _peers = <int, BoardPeer>{};
  final _undo = <_Change>[];
  final _redo = <_Change>[];
  final _rejections = StreamController<String>.broadcast();

  BoardStatus _status = BoardStatus.connecting;
  Object? _failure;
  String? _saveError;
  var _readOnly = false;
  var _running = false;
  var _disposed = false;
  var _attempt = 0;
  var _savedVersion = 0;
  var _ackVersion = 0;
  BoardTransport? _transport;
  StreamSubscription<String>? _subscription;
  Timer? _retry;

  Offset? _cursor;
  var _cursorDirty = false;
  BoardElement? _draft;
  var _draftDirty = false;
  var _draftSent = 0;
  Timer? _presenceTimer;

  BoardStatus get status => _status;

  /// Why the session is offline or closed, when it knows.
  Object? get failure => _failure;

  /// Why the last save failed, until one succeeds.
  String? get saveError => _saveError;

  bool get readOnly => _readOnly;

  Iterable<BoardPeer> get peers => _peers.values;

  /// Whether every local edit reached the file.
  bool get saved => !board.hasPending && _savedVersion >= _ackVersion && _saveError == null;

  bool get canUndo => _undo.isNotEmpty;

  bool get canRedo => _redo.isNotEmpty;

  /// Why the server refused a local edit, which has been rolled back.
  Stream<String> get rejections => _rejections.stream;

  void start() {
    if (_running || _disposed) return;
    _running = true;
    _failure = null;
    _attempt = 0;
    unawaited(_open());
  }

  /// Reconnects now, after a close or while waiting for the next retry.
  void retry() {
    _retry?.cancel();
    _retry = null;
    if (_running && (_transport != null || _status == BoardStatus.connecting)) return;
    _running = false;
    start();
  }

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _presenceTimer?.cancel();
    final transport = _transport;
    _transport = null;
    await _subscription?.cancel();
    _subscription = null;
    await transport?.close();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    unawaited(_rejections.close());
    board.dispose();
    (presence as _Presence).dispose();
    super.dispose();
  }

  /// Puts and deletes elements as one edit, which [undo] reverts as a whole.
  void apply({Iterable<BoardElement> put = const [], Iterable<String> delete = const []}) {
    if (_readOnly) return;
    final before = <String, BoardElement?>{};
    final after = <String, BoardElement?>{};
    for (final e in put) {
      before[e.id] = board[e.id];
      after[e.id] = e;
    }
    for (final id in delete) {
      final current = board[id];
      if (current == null) continue;
      before[id] = current;
      after[id] = null;
    }
    if (after.isEmpty) return;
    _commit(after);
    _undo.add(_Change(before, after));
    if (_undo.length > _historyLimit) _undo.removeAt(0);
    _redo.clear();
    notifyListeners();
  }

  void undo() => _travel(_undo, _redo, forward: false);

  void redo() => _travel(_redo, _undo, forward: true);

  /// Reverts a change, element by element, except where somebody else changed
  /// the element since: their edit stands.
  void _travel(List<_Change> from, List<_Change> to, {required bool forward}) {
    if (_readOnly) return;
    while (from.isNotEmpty) {
      final change = from.removeLast();
      final expected = forward ? change.before : change.after;
      final target = forward ? change.after : change.before;
      final state = <String, BoardElement?>{
        for (final entry in target.entries)
          if (_same(board[entry.key], expected[entry.key])) entry.key: entry.value,
      };
      if (state.isEmpty) continue;
      _commit(state);
      to.add(change);
      notifyListeners();
      return;
    }
    notifyListeners();
  }

  void _commit(Map<String, BoardElement?> state) {
    final op = board.edit(
      [for (final e in state.values) ?e],
      [
        for (final entry in state.entries)
          if (entry.value == null) entry.key,
      ],
    );
    if (_status == BoardStatus.online) _transport?.send(op.encode());
  }

  /// Where this person's pointer is on the board, null once it left.
  void moveCursor(Offset? position) {
    if (position == _cursor) return;
    _cursor = position;
    _cursorDirty = true;
    _schedulePresence();
  }

  /// Shows others what is being drawn before it is committed. A stroke's
  /// points are sent as they are added rather than whole every time.
  void showDraft(BoardElement? draft) {
    if (draft?.id != _draft?.id) _draftSent = 0;
    _draft = draft;
    _draftDirty = true;
    _schedulePresence();
  }

  void _schedulePresence() {
    if (_presenceTimer?.isActive ?? false) return;
    _presenceTimer = Timer(_presenceEvery, _flushPresence);
  }

  void _flushPresence() {
    final transport = _transport;
    if (transport == null || _status != BoardStatus.online) return;
    final data = <String, Object?>{};
    if (_cursorDirty) {
      final cursor = _cursor;
      data['c'] = cursor == null ? null : [cursor.dx.round(), cursor.dy.round()];
      _cursorDirty = false;
    }
    if (_draftDirty) {
      final draft = _draft;
      if (draft == null) {
        data['d'] = null;
      } else if (draft.kind == ElementKind.stroke) {
        final from = math.min(_draftSent, draft.points.length) & ~1;
        data['d'] = draft.copyWith(points: Float32List.sublistView(draft.points, from)).toJson()
          ..['o'] = from;
        _draftSent = draft.points.length;
      } else {
        data['d'] = draft.toJson();
      }
      _draftDirty = false;
    }
    if (data.isNotEmpty) transport.send(jsonEncode({'t': 'eph', 'd': data}));
  }

  Future<void> _open() async {
    _setStatus(BoardStatus.connecting);
    final BoardTransport transport;
    try {
      transport = await _connect(clientId);
    } on Object catch (error) {
      if (!_running) return;
      _failure = error;
      _setStatus(BoardStatus.offline);
      _scheduleRetry();
      return;
    }
    if (!_running) {
      await transport.close();
      return;
    }
    _transport = transport;
    _subscription = transport.messages.listen(
      _receive,
      onDone: () => _dropped(transport),
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  void _dropped(BoardTransport transport) {
    if (!identical(transport, _transport)) return;
    _transport = null;
    _subscription = null;
    _peers.clear();
    (presence as _Presence).changed();
    if (!_running) return;
    final code = transport.closeCode;
    if (code == 4000 || code == 4001) {
      _running = false;
      _failure = BoardClosed(code!, transport.closeReason ?? '');
      _setStatus(BoardStatus.closed);
      return;
    }
    _setStatus(BoardStatus.offline);
    _scheduleRetry();
  }

  void _scheduleRetry() {
    final delay = _backoff[math.min(_attempt, _backoff.length - 1)];
    _attempt++;
    _retry = Timer(Duration(seconds: delay), () {
      if (_running) unawaited(_open());
    });
  }

  void _setStatus(BoardStatus status) {
    if (_disposed) return;
    _status = status;
    notifyListeners();
  }

  void _receive(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, Object?>) return;
    switch (decoded['t']) {
      case 'hello':
        _hello(decoded);
      case 'op':
        _remote(decoded);
      case 'ack':
        board.acknowledge(_int(decoded['n']));
        _ackVersion = math.max(_ackVersion, _int(decoded['v']));
        notifyListeners();
      case 'nack':
        board.reject(_int(decoded['n']));
        _rejections.add('${decoded['error'] ?? ''}');
        notifyListeners();
      case 'eph':
        _presence(decoded);
      case 'join':
        final peer = _peer(decoded['peer']);
        if (peer != null) _peers[peer.sid] = peer;
        notifyListeners();
      case 'leave':
        _peers.remove(_int(decoded['sid']));
        notifyListeners();
        (presence as _Presence).changed();
      case 'saved':
        _savedVersion = math.max(_savedVersion, _int(decoded['v']));
        _saveError = null;
        notifyListeners();
      case 'error':
        _saveError = '${decoded['error'] ?? ''}';
        notifyListeners();
    }
  }

  void _hello(Map<String, Object?> hello) {
    _readOnly = hello['ro'] == true;
    _savedVersion = _int(hello['saved']);
    _ackVersion = _int(hello['v']);
    _saveError = hello['error'] is String ? hello['error']! as String : null;
    _peers.clear();
    for (final raw in _list(hello['peers'])) {
      final peer = _peer(raw);
      if (peer != null) _peers[peer.sid] = peer;
    }
    final resend = board.reset(_elements(hello['elements']), _int(hello['ack']));
    _attempt = 0;
    _failure = null;
    _setStatus(BoardStatus.online);
    for (final op in resend) {
      _transport?.send(op.encode());
    }
    _cursorDirty = _cursor != null;
    _draftSent = 0;
    _draftDirty = _draft != null;
    if (_cursorDirty || _draftDirty) _schedulePresence();
    (presence as _Presence).changed();
  }

  void _remote(Map<String, Object?> op) {
    final put = _elements(op['put']);
    final delete = [
      for (final id in _list(op['del']))
        if (id is String) id,
    ];
    board.applyRemote(put, delete);
    final peer = _peers[_int(op['sid'])];
    final draft = peer?._draft;
    if (draft != null && (put.any((e) => e.id == draft.id) || delete.contains(draft.id))) {
      peer!._draft = null;
      (presence as _Presence).changed();
    }
  }

  void _presence(Map<String, Object?> frame) {
    final peer = _peers[_int(frame['sid'])];
    final data = frame['d'];
    if (peer == null || data is! Map<String, Object?>) return;
    if (data.containsKey('c')) {
      final c = _list(data['c']);
      peer._cursor = c.length == 2 && c[0] is num && c[1] is num
          ? Offset((c[0]! as num).toDouble(), (c[1]! as num).toDouble())
          : null;
    }
    if (data.containsKey('d')) {
      final raw = data['d'];
      final draft = BoardElement.fromJson(raw);
      final from = raw is Map<String, Object?> ? _int(raw['o']) : 0;
      final current = peer._draft;
      if (draft == null || from == 0) {
        peer._draft = draft;
      } else if (current != null && current.id == draft.id && current.points.length == from) {
        peer._draft = draft.copyWith(
          points: Float32List(from + draft.points.length)
            ..setAll(0, current.points)
            ..setAll(from, draft.points),
        );
      }
    }
    (presence as _Presence).changed();
  }

  static BoardPeer? _peer(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    return BoardPeer._(
      _int(raw['sid']),
      '${raw['id'] ?? ''}',
      '${raw['name'] ?? ''}',
      raw['ro'] == true,
    );
  }

  static List<BoardElement> _elements(Object? raw) => [
    for (final e in _list(raw)) ?BoardElement.fromJson(e),
  ];

  static List<Object?> _list(Object? raw) => raw is List<Object?> ? raw : const [];

  static int _int(Object? raw) => raw is num ? raw.toInt() : 0;
}

bool _same(BoardElement? a, BoardElement? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return jsonEncode(a.toJson()) == jsonEncode(b.toJson());
}

final _random = math.Random.secure();
const _alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/// 16 random characters: 95 bits, enough for ids nobody coordinates.
String randomId() => String.fromCharCodes([
  for (var i = 0; i < 16; i++) _alphabet.codeUnitAt(_random.nextInt(_alphabet.length)),
]);
