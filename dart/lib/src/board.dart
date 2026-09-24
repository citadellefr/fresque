import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'element.dart';

/// A local edit on its way to the server, numbered in the order it was made.
class Operation {
  Operation(this.n, this.put, this.delete);

  final int n;
  final List<BoardElement> put;
  final List<String> delete;

  String encode() => jsonEncode({
    't': 'op',
    'n': n,
    if (put.isNotEmpty) 'put': [for (final e in put) e.toJson()],
    if (delete.isNotEmpty) 'del': delete,
  });
}

/// The elements of a board as this client sees them: the state the server
/// confirmed, with the local edits it has not acknowledged yet on top.
///
/// The server applies edits in the order it receives them and every client
/// applies them in that same order, so an acknowledged edit simply moves from
/// the local layer to the confirmed one.
class Board extends ChangeNotifier {
  final _confirmed = <String, BoardElement>{};
  final _local = <String, BoardElement?>{};
  final _counts = <String, int>{};
  final _pending = ListQueue<Operation>();
  final _changed = <String>{};
  var _everything = true;
  var _next = 1;
  List<BoardElement>? _sorted;

  BoardElement? operator [](String id) => _local.containsKey(id) ? _local[id] : _confirmed[id];

  /// Every element, bottom to top.
  List<BoardElement> get elements => _sorted ??= _sort();

  int get topZ => elements.isEmpty ? 0 : elements.last.z;

  int get bottomZ => elements.isEmpty ? 0 : elements.first.z;

  Iterable<Operation> get pending => _pending;

  bool get hasPending => _pending.isNotEmpty;

  /// The ids whose element changed since the last call, or null when the
  /// whole board did.
  Set<String>? takeChanges() {
    if (_everything) {
      _everything = false;
      _changed.clear();
      return null;
    }
    final changes = {..._changed};
    _changed.clear();
    return changes;
  }

  Operation edit(List<BoardElement> put, List<String> delete) {
    final op = Operation(_next++, put, delete);
    for (final e in put) {
      _overlay(e.id, e);
    }
    for (final id in delete) {
      _overlay(id, null);
    }
    _pending.add(op);
    notifyListeners();
    return op;
  }

  void acknowledge(int n) {
    if (_pending.isEmpty || _pending.first.n != n) return;
    final op = _pending.removeFirst();
    for (final e in op.put) {
      _confirmed[e.id] = e;
    }
    for (final id in op.delete) {
      _confirmed.remove(id);
    }
    _release(op, visible: false);
  }

  void reject(int n) {
    if (_pending.isEmpty || _pending.first.n != n) return;
    _release(_pending.removeFirst(), visible: true);
    notifyListeners();
  }

  void applyRemote(List<BoardElement> put, List<String> delete) {
    for (final e in put) {
      _confirmed[e.id] = e;
      if (!_local.containsKey(e.id)) _touch(e.id);
    }
    for (final id in delete) {
      _confirmed.remove(id);
      if (!_local.containsKey(id)) _touch(id);
    }
    notifyListeners();
  }

  /// Replaces the confirmed state with the board the server sent on
  /// connection, drops the edits it had already applied ([ack] is the last
  /// one) and returns the others, to be sent again.
  List<Operation> reset(Iterable<BoardElement> elements, int ack) {
    _confirmed
      ..clear()
      ..addEntries(elements.map((e) => MapEntry(e.id, e)));
    while (_pending.isNotEmpty && _pending.first.n <= ack) {
      _pending.removeFirst();
    }
    _local.clear();
    _counts.clear();
    for (final op in _pending) {
      for (final e in op.put) {
        _local[e.id] = e;
        _counts.update(e.id, (c) => c + 1, ifAbsent: () => 1);
      }
      for (final id in op.delete) {
        _local[id] = null;
        _counts.update(id, (c) => c + 1, ifAbsent: () => 1);
      }
    }
    _everything = true;
    _sorted = null;
    notifyListeners();
    return _pending.toList();
  }

  void _overlay(String id, BoardElement? e) {
    _local[id] = e;
    _counts.update(id, (c) => c + 1, ifAbsent: () => 1);
    _touch(id);
  }

  void _release(Operation op, {required bool visible}) {
    void release(String id) {
      final count = _counts[id]! - 1;
      if (count > 0) {
        _counts[id] = count;
        return;
      }
      _counts.remove(id);
      _local.remove(id);
      if (visible) _touch(id);
    }

    for (final e in op.put) {
      release(e.id);
    }
    op.delete.forEach(release);
  }

  void _touch(String id) {
    _changed.add(id);
    _sorted = null;
  }

  List<BoardElement> _sort() {
    final all = <BoardElement>[
      for (final e in _confirmed.values)
        if (!_local.containsKey(e.id)) e,
      for (final e in _local.values) ?e,
    ];
    return all..sort(compareElements);
  }
}

int compareElements(BoardElement a, BoardElement b) {
  final byZ = a.z.compareTo(b.z);
  return byZ != 0 ? byZ : a.id.compareTo(b.id);
}
