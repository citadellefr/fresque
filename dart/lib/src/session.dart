import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:trame/trame.dart';

import 'board.dart';
import 'element.dart';

export 'package:trame/trame.dart' show randomId, webSocketConnector;

/// The text link to the server, behind an interface so that sessions can be
/// tested without one.
typedef BoardTransport = DocTransport;

/// Opens a transport for the session whose client id is given; called again
/// on every reconnection.
typedef BoardConnector = DocConnector;

typedef BoardStatus = DocStatus;

/// Why the server ended the session: the board could not be opened, or access
/// to it was withdrawn. [reason] is the server's own words.
typedef BoardClosed = DocClosed;

class BoardPeer {
  BoardPeer._(this._peer);

  final DocPeer _peer;

  Offset? _cursor;
  BoardElement? _draft;
  Rect? _lastEdit;

  int get sid => _peer.sid;
  String get id => _peer.id;
  String get name => _peer.name;
  bool get readOnly => _peer.readOnly;

  Offset? get cursor => _cursor;

  /// What the peer is drawing right now, before it becomes an element.
  BoardElement? get draft => _draft;

  /// Where the peer last changed the board, drawing in progress included.
  Rect? get lastEdit => _lastEdit;
}

class _Presence extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// One person's connection to a board: keeps [board] in step with the server,
/// sends local edits, reconnects when the link drops and keeps the history
/// [undo] and [redo] walk through. The document and its protocol are trame's;
/// what is added here is the board it makes, and what people show of what
/// they are doing — a pointer, a stroke being drawn.
class BoardSession extends ChangeNotifier {
  BoardSession(BoardConnector connect, {String? clientId})
    : _doc = DocSession(connect, clientId: clientId, othersPrevail: true) {
    board = Board(() => _doc.document);
    _subscriptions = [
      _doc.changes.listen(board.follow),
      _doc.authored.listen(_authored),
    ];
    _doc
      ..addListener(_changed)
      ..presence.addListener(_presence.changed)
      ..onShared = _shared;
  }

  static const _presenceEvery = Duration(milliseconds: 40);

  final DocSession _doc;
  late final Board board;
  late final List<StreamSubscription<Object?>> _subscriptions;

  /// Notifies cursor and draft changes, far more frequent than the others.
  final Listenable presence = _Presence();
  _Presence get _presence => presence as _Presence;

  final _peers = <int, BoardPeer>{};
  final _edits = StreamController<BoardPeer>.broadcast();

  var _wasOnline = false;
  var _disposed = false;
  Offset? _cursor;
  var _cursorDirty = false;
  BoardElement? _draft;
  var _draftDirty = false;
  var _draftSent = 0;
  Timer? _presenceTimer;

  String get clientId => _doc.clientId;

  BoardStatus get status => _doc.status;

  /// Why the session is offline or closed, when it knows.
  Object? get failure => _doc.failure;

  /// Why the last save failed, until one succeeds.
  String? get saveError => _doc.saveError;

  bool get readOnly => _doc.readOnly;

  Iterable<BoardPeer> get peers => _doc.peers.map(_peer);

  /// Whether every local edit reached the file.
  bool get saved => _doc.saved;

  bool get canUndo => _doc.canUndo;

  bool get canRedo => _doc.canRedo;

  /// Why the server refused a local edit, which has been rolled back.
  Stream<String> get rejections => _doc.rejections;

  /// The peer whose [BoardPeer.lastEdit] just moved.
  Stream<BoardPeer> get edits => _edits.stream;

  void start() => _doc.start();

  /// Reconnects now, after a close or while waiting for the next retry.
  void retry() => _doc.retry();

  Future<void> stop() async {
    _presenceTimer?.cancel();
    await _doc.stop();
  }

  @override
  void dispose() {
    _disposed = true;
    _presenceTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_edits.close());
    _doc.dispose();
    board.dispose();
    _presence.dispose();
    super.dispose();
  }

  /// Puts and deletes elements as one edit, which [undo] reverts as a whole.
  void apply({Iterable<BoardElement> put = const [], Iterable<String> delete = const []}) {
    if (readOnly) return;
    final changes = <Change>[];
    for (final e in put) {
      if (_put(board[e.id], e) case final change?) changes.add(change);
    }
    for (final id in delete) {
      if (board[id] != null) changes.add(Change.delete(id));
    }
    if (changes.isNotEmpty) _doc.edit(Edit(changes));
  }

  /// What it takes to make [to] of [from]: the element created, or its
  /// attributes and its place in the stack changed — nothing when there is
  /// nothing to change.
  Change? _put(BoardElement? from, BoardElement to) {
    final attributes = to.attributes;
    if (from == null) {
      return Change.create(Node(id: to.id, type: elementType, key: zKey(to.z), attributes: attributes));
    }
    final before = from.attributes;
    final changed = <String, Object?>{
      for (final entry in attributes.entries)
        if (!before.containsKey(entry.key) || !_same(before[entry.key], entry.value)) entry.key: entry.value,
      for (final key in before.keys)
        if (!attributes.containsKey(key)) key: null,
    };
    final key = from.z == to.z ? '' : zKey(to.z);
    if (changed.isEmpty && key.isEmpty) return null;
    return Change.set(to.id, key: key, attributes: changed);
  }

  void undo() => _doc.undo();

  void redo() => _doc.redo();

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
    if (_disposed || _doc.status != BoardStatus.online) return;
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
        data['d'] = draft.copyWith(points: Float32List.sublistView(draft.points, from)).toJson()..['o'] = from;
        _draftSent = draft.points.length;
      } else {
        data['d'] = draft.toJson();
      }
      _draftDirty = false;
    }
    if (data.isNotEmpty) _doc.share(data, now: true);
  }

  /// The session moved: what is shown is told again once it is back online,
  /// and peers who left are forgotten.
  void _changed() {
    final online = _doc.status == BoardStatus.online;
    if (online && !_wasOnline) {
      _cursorDirty = _cursor != null;
      _draftSent = 0;
      _draftDirty = _draft != null;
      if (_cursorDirty || _draftDirty) _schedulePresence();
    }
    _wasOnline = online;
    final here = {for (final peer in _doc.peers) peer.sid};
    _peers.removeWhere((sid, _) => !here.contains(sid));
    notifyListeners();
  }

  BoardPeer _peer(DocPeer peer) => _peers.putIfAbsent(peer.sid, () => BoardPeer._(peer));

  /// What a peer shows: a pointer, a draft.
  void _shared(DocPeer from, Map<String, Object?> data) {
    final peer = _peer(from);
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
      if (peer._draft case final draft?) _edited(peer, draft.bounds);
    }
    _presence.changed();
  }

  /// What others did to the board: where they drew, and the end of the draft
  /// that became an element.
  void _authored(({Edit edit, DocPeer? author}) event) {
    final author = event.author;
    if (author == null) return;
    final peer = _peer(author);
    if (board.lastArea case final area?) _edited(peer, area);
    final draft = peer._draft;
    if (draft != null && event.edit.changes.any((c) => c.id == draft.id)) {
      peer._draft = null;
      _presence.changed();
    }
  }

  void _edited(BoardPeer peer, Rect area) {
    peer._lastEdit = area;
    if (!_edits.isClosed) _edits.add(peer);
  }

  static List<Object?> _list(Object? raw) => raw is List<Object?> ? raw : const [];

  static int _int(Object? raw) => raw is num ? raw.toInt() : 0;
}

/// Whether two JSON values are the same, lists and objects compared by what
/// they hold.
bool _same(Object? a, Object? b) {
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map<String, Object?> && b is Map<String, Object?>) {
    return a.length == b.length && a.entries.every((e) => b.containsKey(e.key) && _same(e.value, b[e.key]));
  }
  return a == b;
}
