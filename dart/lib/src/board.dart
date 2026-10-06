import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:trame/trame.dart';

import 'element.dart';

/// The elements of a board as this client sees them, read from the document
/// of its session: confirmed edits and local ones alike, which the session
/// rebases as others arrive.
///
/// It follows the document edit by edit ([follow]) and keeps what the view
/// asks of it at hand: the elements in stacking order, and which ones changed
/// since it last looked.
class Board extends ChangeNotifier {
  Board(this._document);

  final Tree Function() _document;
  final _elements = <String, BoardElement>{};
  final _changed = <String>{};
  var _everything = true;
  var _topZ = 0;
  var _bottomZ = 0;
  List<BoardElement>? _sorted;
  Rect? _area;

  BoardElement? operator [](String id) => _elements[id];

  /// Every element, bottom to top.
  List<BoardElement> get elements => _sorted ??= (_elements.values.toList()..sort(compareElements));

  /// At least the highest z of the board, without sorting it: an element
  /// given `topZ + 1` goes above all the others.
  int get topZ => _topZ;

  /// At most the lowest z of the board.
  int get bottomZ => _bottomZ;

  /// What the last edit touched, before and after.
  Rect? get lastArea => _area;

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

  /// Takes up an edit the document has just made.
  void follow(Edit edit) {
    final document = _document();
    Rect? area;
    for (final change in edit.changes) {
      if (change.kind != ChangeKind.create && change.kind != ChangeKind.set && change.kind != ChangeKind.delete) {
        continue;
      }
      final before = _elements[change.id];
      final node = document[change.id];
      final after = node == null ? null : BoardElement.fromNode(node);
      if (before == null && after == null) continue;
      if (after == null) {
        _elements.remove(change.id);
      } else {
        _elements[change.id] = after;
        _topZ = math.max(_topZ, after.z);
        _bottomZ = math.min(_bottomZ, after.z);
      }
      _changed.add(change.id);
      _sorted = null;
      for (final box in [?before?.bounds, ?after?.bounds]) {
        area = area?.expandToInclude(box) ?? box;
      }
    }
    if (area == null) return;
    _area = area;
    notifyListeners();
  }
}

int compareElements(BoardElement a, BoardElement b) {
  final byZ = a.z.compareTo(b.z);
  return byZ != 0 ? byZ : a.id.compareTo(b.id);
}
