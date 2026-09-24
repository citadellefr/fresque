import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'board.dart';
import 'element.dart';
import 'session.dart';

enum BoardTool { select, hand, pen, highlighter, line, arrow, rectangle, ellipse, text, eraser }

/// What a [BoardView] draws with, what is selected and which part of the board
/// is on screen. Style changes also apply to the selection.
class BoardController extends ChangeNotifier {
  BoardController(this.session, {this._tool = BoardTool.pen, this._color = 0xFF1E1E1E});

  static const minScale = 0.1;
  static const maxScale = 8.0;

  final BoardSession session;

  BoardTool _tool;
  int _color;
  double _strokeWidth = 3;
  bool _filled = false;
  Set<String> _selection = const {};
  double _scale = 1;
  Offset _offset = Offset.zero;

  BoardTool get tool => _tool;
  int get color => _color;
  double get strokeWidth => _strokeWidth;
  bool get filled => _filled;
  Set<String> get selection => _selection;
  double get scale => _scale;
  Offset get offset => _offset;

  set tool(BoardTool tool) {
    if (tool == _tool) return;
    _tool = tool;
    if (tool != BoardTool.select) _selection = const {};
    notifyListeners();
  }

  set color(int color) {
    _color = color;
    _restyle((e) => e.copyWith(color: color));
    notifyListeners();
  }

  set strokeWidth(double width) {
    _strokeWidth = width;
    _restyle((e) => e.kind == ElementKind.text ? e : e.copyWith(strokeWidth: width));
    notifyListeners();
  }

  set filled(bool filled) {
    _filled = filled;
    _restyle(
      (e) => e.kind == ElementKind.rectangle || e.kind == ElementKind.ellipse
          ? e.copyWith(filled: filled)
          : e,
    );
    notifyListeners();
  }

  /// Selected elements that still exist.
  List<BoardElement> get selected => [for (final id in _selection) ?session.board[id]];

  void select(Iterable<String> ids) {
    _selection = Set.unmodifiable(ids);
    notifyListeners();
  }

  void selectAll() {
    _tool = BoardTool.select;
    select(session.board.elements.map((e) => e.id));
  }

  void deleteSelection() {
    session.apply(delete: _selection);
    select(const []);
  }

  void bringToFront() => _restack(front: true);

  void sendToBack() => _restack(front: false);

  void _restack({required bool front}) {
    final board = session.board;
    final elements = selected..sort(compareElements);
    var z = front ? board.topZ : board.bottomZ - elements.length;
    session.apply(put: [for (final e in elements) e.copyWith(z: ++z)]);
  }

  void _restyle(BoardElement Function(BoardElement) change) {
    final changed = <BoardElement>[];
    for (final e in selected) {
      final next = change(e);
      if (!identical(next, e)) changed.add(next);
    }
    if (changed.isNotEmpty) session.apply(put: changed);
  }

  Offset toWorld(Offset screen) => (screen - _offset) / _scale;

  Offset toScreen(Offset world) => world * _scale + _offset;

  Rect visibleRect(Size viewport) =>
      Rect.fromPoints(toWorld(Offset.zero), toWorld(viewport.bottomRight(Offset.zero)));

  void panBy(Offset delta) {
    if (delta == Offset.zero) return;
    _offset += delta;
    notifyListeners();
  }

  /// Zooms by [factor], keeping the board point under [focal] where it is.
  void zoomAt(Offset focal, double factor) {
    final scale = (_scale * factor).clamp(minScale, maxScale);
    if (scale == _scale) return;
    final world = toWorld(focal);
    _scale = scale;
    _offset = focal - world * scale;
    notifyListeners();
  }

  /// Frames every element, or the origin at scale 1 on an empty board.
  void fit(Size viewport, {double padding = 48}) {
    final elements = session.board.elements;
    if (elements.isEmpty || viewport.isEmpty) {
      _scale = 1;
      _offset = Offset(padding, padding);
    } else {
      final bounds = elements.map((e) => e.bounds).reduce((a, b) => a.expandToInclude(b));
      final fits = math.min(
        (viewport.width - 2 * padding) / math.max(bounds.width, 1),
        (viewport.height - 2 * padding) / math.max(bounds.height, 1),
      );
      _scale = fits.clamp(minScale, 1.0);
      _offset = viewport.center(Offset.zero) - bounds.center * _scale;
    }
    notifyListeners();
  }
}
