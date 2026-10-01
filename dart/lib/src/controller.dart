import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'board.dart';
import 'element.dart';
import 'images.dart';
import 'session.dart';

enum BoardTool { select, hand, pen, highlighter, line, arrow, rectangle, ellipse, text, eraser }

/// What a [BoardView] draws with, what is selected and which part of the board
/// is on screen. Style changes also apply to the selection.
class BoardController extends ChangeNotifier {
  BoardController(this.session, {this._tool = BoardTool.pen, this._color = 0xFF1E1E1E}) {
    session.addListener(_peersChanged);
  }

  static const minScale = 0.1;
  static const maxScale = 8.0;

  /// What was last copied, shared by every board of the app.
  static var _clipboard = const <BoardElement>[];

  final BoardSession session;

  BoardTool _tool;
  int _color;
  double _strokeWidth = 3;
  bool _filled = false;
  BoardDash _dash = BoardDash.solid;
  Set<String> _selection = const {};
  double _scale = 1;
  Offset _offset = Offset.zero;
  String? _following;

  BoardTool get tool => _tool;
  int get color => _color;
  double get strokeWidth => _strokeWidth;
  bool get filled => _filled;
  BoardDash get dash => _dash;
  Set<String> get selection => _selection;
  double get scale => _scale;
  Offset get offset => _offset;

  /// The id of the peer whose edits the view keeps on screen, until the view
  /// is panned by hand or they leave.
  String? get following => _following;

  @override
  void dispose() {
    session.removeListener(_peersChanged);
    super.dispose();
  }

  set tool(BoardTool tool) {
    if (tool == _tool) return;
    _tool = tool;
    if (tool != BoardTool.select) _selection = const {};
    notifyListeners();
  }

  set color(int color) {
    _color = color;
    _restyle((e) => e.kind == ElementKind.image ? e : e.copyWith(color: color));
    notifyListeners();
  }

  set strokeWidth(double width) {
    _strokeWidth = width;
    _restyle(
      (e) => e.kind == ElementKind.text || e.kind == ElementKind.image
          ? e
          : e.copyWith(strokeWidth: width),
    );
    notifyListeners();
  }

  set filled(bool filled) {
    _filled = filled;
    _restyle((e) => e.canFill ? e.copyWith(filled: filled) : e);
    notifyListeners();
  }

  set dash(BoardDash dash) {
    _dash = dash;
    _restyle(
      (e) => e.kind == ElementKind.text || e.kind == ElementKind.image ? e : e.copyWith(dash: dash),
    );
    notifyListeners();
  }

  /// Selected elements that still exist.
  List<BoardElement> get selected => [for (final id in _selection) ?session.board[id]];

  bool get canPaste => _clipboard.isNotEmpty;

  void select(Iterable<String> ids) {
    _selection = Set.unmodifiable(ids);
    notifyListeners();
  }

  void selectAll() {
    _tool = BoardTool.select;
    select(session.board.elements.map((e) => e.id));
  }

  /// Puts the image file [bytes] on the board, in the middle of [viewport],
  /// and selects it. Throws a [FormatException] when they are not an image.
  Future<void> insertImage(Uint8List bytes, Size viewport) async {
    final image = await prepareImage(bytes);
    final visible = visibleRect(viewport);
    final fit = math.min(
      1.0,
      0.6 * math.min(visible.width / image.size.width, visible.height / image.size.height),
    );
    final size = image.size * fit;
    final e = BoardElement(
      id: randomId(),
      kind: ElementKind.image,
      z: session.board.topZ + 1,
      x: visible.center.dx - size.width / 2,
      y: visible.center.dy - size.height / 2,
      width: size.width,
      height: size.height,
      color: 0xFF000000,
      src: image.src,
    );
    session.apply(put: [e]);
    if (session.board[e.id] == null) return;
    _tool = BoardTool.select;
    select([e.id]);
  }

  void deleteSelection() {
    session.apply(delete: _selection);
    select(const []);
  }

  void copySelection() {
    final elements = selected;
    if (elements.isEmpty) return;
    _clipboard = List.unmodifiable(elements..sort(compareElements));
    notifyListeners();
  }

  void cutSelection() {
    copySelection();
    deleteSelection();
  }

  /// Puts a copy of what was copied on top of the board, centred on [at],
  /// and selects it.
  void paste(Offset at) {
    if (_clipboard.isEmpty || session.readOnly) return;
    final bounds = _clipboard.map((e) => e.bounds).reduce((a, b) => a.expandToInclude(b));
    final shift = at - bounds.center;
    var z = session.board.topZ;
    final copies = [
      for (final e in _clipboard)
        e.copyWith(id: randomId(), z: ++z, x: e.x + shift.dx, y: e.y + shift.dy),
    ];
    session.apply(put: copies);
    _tool = BoardTool.select;
    select([for (final e in copies) e.id]);
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

  void follow(String? peerId) {
    if (peerId == _following) return;
    _following = peerId;
    notifyListeners();
  }

  void _peersChanged() {
    final id = _following;
    if (id == null || session.status != BoardStatus.online) return;
    if (session.peers.any((peer) => peer.id == id)) return;
    _following = null;
    notifyListeners();
  }

  Offset toWorld(Offset screen) => (screen - _offset) / _scale;

  Offset toScreen(Offset world) => world * _scale + _offset;

  Rect visibleRect(Size viewport) =>
      Rect.fromPoints(toWorld(Offset.zero), toWorld(viewport.bottomRight(Offset.zero)));

  void panBy(Offset delta) {
    if (delta == Offset.zero) return;
    _offset += delta;
    _following = null;
    notifyListeners();
  }

  /// Brings [area] into [viewport], [padding] inside its edges: the view moves
  /// as little as it can, and zooms out only if [area] would not fit.
  void reveal(Rect area, Size viewport, {double padding = 48}) {
    if (viewport.isEmpty) return;
    final inset = math.min(padding, viewport.shortestSide / 4);
    final room = (Offset.zero & viewport).deflate(inset);
    final fits = math.min(
      room.width / math.max(area.width, 1),
      room.height / math.max(area.height, 1),
    );
    final scale = math.max(math.min(_scale, fits), minScale);
    final Offset offset;
    if (scale != _scale) {
      offset = room.center - area.center * scale;
    } else {
      final screen = Rect.fromPoints(toScreen(area.topLeft), toScreen(area.bottomRight));
      offset =
          _offset +
          Offset(
            _shift(screen.left, screen.right, room.left, room.right),
            _shift(screen.top, screen.bottom, room.top, room.bottom),
          );
    }
    if (scale == _scale && offset == _offset) return;
    _scale = scale;
    _offset = offset;
    notifyListeners();
  }

  /// How far to move [start]–[end] to lie within [min]–[max], centred when
  /// it is longer.
  static double _shift(double start, double end, double min, double max) {
    if (end - start > max - min) return (min + max - start - end) / 2;
    if (start < min) return min - start;
    if (end > max) return max - end;
    return 0;
  }

  /// Zooms by [factor] around the middle of [viewport].
  void zoomBy(double factor, Size viewport) => zoomAt(viewport.center(Offset.zero), factor);

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
