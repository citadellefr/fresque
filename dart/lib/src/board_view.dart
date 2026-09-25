import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'board.dart';
import 'controller.dart';
import 'element.dart';
import 'geometry.dart';
import 'render.dart';
import 'session.dart';

/// The board of [controller]'s session, drawn and edited with its tool.
///
/// Mouse, touch and stylus: one finger or the pen uses the tool, two fingers
/// pan and zoom, the wheel pans (zooms with Ctrl), the middle button or Space
/// pans. Once a stylus has been seen, fingers only pan, and its eraser end
/// erases.
class BoardView extends StatefulWidget {
  const BoardView({required this.controller, this.accentColor, this.gridColor, super.key});

  final BoardController controller;

  /// Selection and cursors of the others; the theme's primary colour if null.
  final Color? accentColor;

  /// Dots every 24 units; the theme's outline colour if null.
  final Color? gridColor;

  @override
  State<BoardView> createState() => _BoardViewState();
}

class _Interaction extends ChangeNotifier {
  BoardElement? draft;
  Set<String> lifted = const {};
  Offset shift = Offset.zero;
  Set<String> erasing = const {};
  Rect? marquee;
  String? editing;

  final hidden = ValueNotifier<Set<String>>(const {});

  void changed() {
    final next = {...lifted, ...erasing, ?editing};
    if (!_sameSet(next, hidden.value)) hidden.value = next;
    notifyListeners();
  }

  @override
  void dispose() {
    hidden.dispose();
    super.dispose();
  }
}

bool _sameSet(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

class _TextEditing {
  _TextEditing(this.element, {required this.isNew})
    : text = TextEditingController(text: element.text);

  final BoardElement element;
  final bool isNew;
  final TextEditingController text;
  final focus = FocusNode();

  void dispose() {
    text.dispose();
    focus.dispose();
  }
}

class _BoardViewState extends State<BoardView> {
  final _scene = Scene();
  final _interaction = _Interaction();
  final _focus = FocusNode();
  final _touches = <int, Offset>{};
  final _labels = <String, TextPainter>{};
  _Gesture? _gesture;
  int? _gesturePointer;
  var _pinching = false;
  var _stylus = false;
  var _space = false;
  var _panZoomScale = 1.0;
  var _fitted = false;
  var _size = Size.zero;
  _TextEditing? _editing;
  String? _lastTapId;
  DateTime _lastTapAt = DateTime(0);

  BoardController get controller => widget.controller;

  BoardSession get session => controller.session;

  Board get board => session.board;

  double get tolerance => 6 / controller.scale;

  @override
  void initState() {
    super.initState();
    session.addListener(_fitOnce);
    board.addListener(_boardChanged);
  }

  @override
  void didUpdateWidget(BoardView old) {
    super.didUpdateWidget(old);
    if (old.controller.session != session) {
      old.controller.session.removeListener(_fitOnce);
      old.controller.session.board.removeListener(_boardChanged);
      session.addListener(_fitOnce);
      board.addListener(_boardChanged);
      _fitted = false;
    }
  }

  @override
  void dispose() {
    session.removeListener(_fitOnce);
    board.removeListener(_boardChanged);
    _editing?.dispose();
    _scene.dispose();
    _interaction.dispose();
    _focus.dispose();
    for (final label in _labels.values) {
      label.dispose();
    }
    super.dispose();
  }

  /// Frames the board once, when it first arrives.
  void _fitOnce() {
    if (_fitted || session.status != BoardStatus.online || _size.isEmpty) return;
    _fitted = true;
    controller.fit(_size);
  }

  void _boardChanged() {
    final selection = controller.selection;
    if (selection.isNotEmpty && selection.any((id) => board[id] == null)) {
      controller.select(selection.where((id) => board[id] != null));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = widget.accentColor ?? theme.colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        if (!_fitted) {
          // not while laying out: fitting notifies the controller's listeners
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fitOnce();
          });
        }
        return Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _key,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ListenableBuilder(
                  listenable: controller,
                  builder: (context, child) => MouseRegion(
                    cursor: _cursor(),
                    onExit: (_) => session.moveCursor(null),
                    child: child,
                  ),
                  child: Listener(
                    onPointerDown: _down,
                    onPointerMove: _move,
                    onPointerHover: (e) => session.moveCursor(controller.toWorld(e.localPosition)),
                    onPointerUp: _up,
                    onPointerCancel: (e) => _up(e, cancelled: true),
                    onPointerSignal: _signal,
                    onPointerPanZoomStart: (_) => _panZoomScale = 1,
                    onPointerPanZoomUpdate: _panZoom,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        RepaintBoundary(
                          child: CustomPaint(
                            painter: _ScenePainter(
                              scene: _scene,
                              board: board,
                              controller: controller,
                              hidden: _interaction.hidden,
                              grid: widget.gridColor ?? theme.colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                        RepaintBoundary(
                          child: CustomPaint(
                            painter: _OverlayPainter(
                              session: session,
                              controller: controller,
                              interaction: _interaction,
                              accent: accent,
                              labels: _labels,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_editing case final editing?)
                  ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) => _textField(editing),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  MouseCursor _cursor() {
    if (_space) return SystemMouseCursors.grab;
    return switch (controller.tool) {
      BoardTool.select => SystemMouseCursors.basic,
      BoardTool.hand => SystemMouseCursors.grab,
      BoardTool.text => SystemMouseCursors.text,
      _ => session.readOnly ? SystemMouseCursors.basic : SystemMouseCursors.precise,
    };
  }

  Widget _textField(_TextEditing editing) {
    final e = editing.element;
    final position = controller.toScreen(Offset(e.x, e.y));
    return Positioned(
      left: position.dx,
      top: position.dy,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: 24,
          maxWidth: math.max(24, _size.width - position.dx),
        ),
        child: IntrinsicWidth(
          child: MediaQuery.withNoTextScaling(
            child: TextField(
              controller: editing.text,
              focusNode: editing.focus,
              maxLines: null,
              style: textStyle(e.color, e.fontSize * controller.scale),
              cursorColor: Color(e.color),
              decoration: const InputDecoration.collapsed(hintText: ''),
              onTapOutside: (_) => _commitText(),
            ),
          ),
        ),
      ),
    );
  }

  void _openText(BoardElement element, {required bool isNew}) {
    _commitText();
    final editing = _TextEditing(element, isNew: isNew);
    setState(() => _editing = editing);
    // autofocus would not take the focus from the board
    editing.focus.requestFocus();
    _interaction
      ..editing = element.id
      ..changed();
  }

  void _commitText() {
    final editing = _editing;
    if (editing == null) return;
    setState(() => _editing = null);
    _interaction
      ..editing = null
      ..changed();
    final e = editing.element;
    final text = editing.text.text.trimRight();
    editing.dispose();
    if (text.isEmpty) {
      if (!editing.isNew) session.apply(delete: [e.id]);
    } else if (text != e.text) {
      final measured = e.copyWith(text: text);
      final painter = textPainter(measured);
      session.apply(
        put: [
          measured.copyWith(
            width: painter.width,
            height: painter.height,
            z: editing.isNew ? board.topZ + 1 : e.z,
          ),
        ],
      );
      painter.dispose();
    }
    _focus.requestFocus();
  }

  void _down(PointerDownEvent e) {
    if (_editing != null) {
      _commitText();
      return;
    }
    _focus.requestFocus();
    if (e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus) {
      _stylus = true;
    }
    if (e.kind == PointerDeviceKind.touch) {
      _touches[e.pointer] = e.localPosition;
      if (_touches.length == 2 && !_pinching) {
        _gesture?.cancel();
        _gesture = null;
        _gesturePointer = null;
        _pinching = true;
      }
      if (_pinching) return;
    }
    if (_gesture != null) return;
    _gesturePointer = e.pointer;
    _gesture = _begin(e);
  }

  _Gesture _begin(PointerDownEvent e) {
    final world = controller.toWorld(e.localPosition);
    final panning =
        _space ||
        controller.tool == BoardTool.hand ||
        e.kind == PointerDeviceKind.mouse &&
            e.buttons & (kMiddleMouseButton | kSecondaryMouseButton) != 0 ||
        e.kind == PointerDeviceKind.touch && _stylus;
    if (panning) return _Pan(controller);
    if (controller.tool == BoardTool.select) return _select(world);
    if (session.readOnly) return _Pan(controller);
    if (e.kind == PointerDeviceKind.invertedStylus) return _Eraser(this, world);
    return switch (controller.tool) {
      BoardTool.pen => _Stroke(this, world, highlighter: false),
      BoardTool.highlighter => _Stroke(this, world, highlighter: true),
      BoardTool.line => _Shape(this, world, ElementKind.line),
      BoardTool.arrow => _Shape(this, world, ElementKind.arrow),
      BoardTool.rectangle => _Shape(this, world, ElementKind.rectangle),
      BoardTool.ellipse => _Shape(this, world, ElementKind.ellipse),
      BoardTool.eraser => _Eraser(this, world),
      BoardTool.text => _Tap(() => _textAt(world)),
      BoardTool.select || BoardTool.hand => _Pan(controller),
    };
  }

  _Gesture _select(Offset world) {
    final hit = hitTop(board.elements, world, tolerance);
    final additive = HardwareKeyboard.instance.isShiftPressed;
    if (hit == null) {
      if (!additive) controller.select(const []);
      return _Marquee(this, world, additive: additive);
    }
    final now = DateTime.now();
    final again =
        hit.id == _lastTapId && now.difference(_lastTapAt) < const Duration(milliseconds: 400);
    _lastTapId = hit.id;
    _lastTapAt = now;
    if (again && hit.kind == ElementKind.text && !session.readOnly) {
      return _Tap(() => _openText(hit, isNew: false));
    }
    final selection = controller.selection;
    if (!selection.contains(hit.id)) {
      controller.select(additive ? {...selection, hit.id} : {hit.id});
    } else if (additive) {
      controller.select(selection.where((id) => id != hit.id));
      return _Tap(() {});
    }
    return session.readOnly ? _Tap(() {}) : _Move(this, world);
  }

  void _textAt(Offset world) {
    final hit = hitTop(board.elements, world, tolerance);
    if (hit != null && hit.kind == ElementKind.text) {
      _openText(hit, isNew: false);
      return;
    }
    final fontSize = 12 + controller.strokeWidth * 4;
    _openText(
      BoardElement(
        id: randomId(),
        kind: ElementKind.text,
        z: board.topZ + 1,
        x: world.dx,
        y: world.dy - fontSize * 0.625,
        color: controller.color,
        fontSize: fontSize,
      ),
      isNew: true,
    );
  }

  void _move(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.touch && _touches.containsKey(e.pointer)) {
      if (_pinching) {
        _pinch(e);
        return;
      }
      _touches[e.pointer] = e.localPosition;
    }
    if (e.pointer != _gesturePointer) return;
    final world = controller.toWorld(e.localPosition);
    session.moveCursor(world);
    _gesture?.move(world, e);
  }

  void _pinch(PointerMoveEvent e) {
    final before = _touches.values.take(2).toList();
    _touches[e.pointer] = e.localPosition;
    final after = _touches.values.take(2).toList();
    if (before.length < 2 || after.length < 2) return;
    final focus = (after[0] + after[1]) / 2;
    controller.panBy(focus - (before[0] + before[1]) / 2);
    final distance = (before[0] - before[1]).distance;
    if (distance > 0) controller.zoomAt(focus, (after[0] - after[1]).distance / distance);
  }

  void _up(PointerEvent e, {bool cancelled = false}) {
    _touches.remove(e.pointer);
    if (_pinching) {
      if (_touches.isEmpty) _pinching = false;
      return;
    }
    if (e.pointer != _gesturePointer) return;
    final gesture = _gesture;
    _gesture = null;
    _gesturePointer = null;
    if (cancelled) {
      gesture?.cancel();
    } else {
      gesture?.end();
    }
  }

  void _signal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      controller.zoomAt(e.localPosition, math.exp(-e.scrollDelta.dy / 300));
    } else if (keyboard.isShiftPressed && e.scrollDelta.dx == 0) {
      controller.panBy(Offset(-e.scrollDelta.dy, 0));
    } else {
      controller.panBy(-e.scrollDelta);
    }
  }

  void _panZoom(PointerPanZoomUpdateEvent e) {
    controller.panBy(e.localPanDelta);
    if (e.scale != _panZoomScale && _panZoomScale > 0) {
      controller.zoomAt(e.localPosition, e.scale / _panZoomScale);
      _panZoomScale = e.scale;
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (_editing != null) {
      if (event is KeyDownEvent && key == LogicalKeyboardKey.escape) {
        _commitText();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.space) {
      final held = event is! KeyUpEvent;
      if (held != _space) setState(() => _space = held);
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (command) {
      if (key == LogicalKeyboardKey.keyZ) {
        keyboard.isShiftPressed ? session.redo() : session.undo();
      } else if (key == LogicalKeyboardKey.keyY) {
        session.redo();
      } else if (key == LogicalKeyboardKey.keyA) {
        controller.selectAll();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
      controller.deleteSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _gesture?.cancel();
      _gesture = null;
      _gesturePointer = null;
      controller.select(const []);
      return KeyEventResult.handled;
    }
    final tool = _shortcuts[key];
    if (tool == null || event is KeyRepeatEvent) return KeyEventResult.ignored;
    controller.tool = tool;
    return KeyEventResult.handled;
  }

  static final _shortcuts = {
    LogicalKeyboardKey.keyV: BoardTool.select,
    LogicalKeyboardKey.keyH: BoardTool.hand,
    LogicalKeyboardKey.keyP: BoardTool.pen,
    LogicalKeyboardKey.keyM: BoardTool.highlighter,
    LogicalKeyboardKey.keyL: BoardTool.line,
    LogicalKeyboardKey.keyA: BoardTool.arrow,
    LogicalKeyboardKey.keyR: BoardTool.rectangle,
    LogicalKeyboardKey.keyO: BoardTool.ellipse,
    LogicalKeyboardKey.keyT: BoardTool.text,
    LogicalKeyboardKey.keyE: BoardTool.eraser,
  };
}

abstract class _Gesture {
  void move(Offset world, PointerMoveEvent event);
  void end();
  void cancel();
}

class _Pan implements _Gesture {
  _Pan(this.controller);

  final BoardController controller;

  @override
  void move(Offset world, PointerMoveEvent event) => controller.panBy(event.localDelta);

  @override
  void end() {}

  @override
  void cancel() {}
}

class _Tap implements _Gesture {
  _Tap(this.onTap);

  final VoidCallback onTap;
  var _travel = 0.0;

  @override
  void move(Offset world, PointerMoveEvent event) => _travel += event.localDelta.distance;

  @override
  void end() {
    if (_travel < 8) onTap();
  }

  @override
  void cancel() {}
}

class _Stroke implements _Gesture {
  _Stroke(this.view, this.origin, {required this.highlighter}) {
    _points[0] = 0;
    _points[1] = 0;
    _last = origin;
    _show();
  }

  final _BoardViewState view;
  final Offset origin;
  final bool highlighter;
  final id = randomId();
  var _points = Float32List(512);
  var _length = 2;
  late Offset _last;

  @override
  void move(Offset world, PointerMoveEvent event) {
    if ((world - _last).distance * view.controller.scale < 1.5) return;
    _last = world;
    if (_length + 2 > _points.length) {
      _points = Float32List(_points.length * 2)..setAll(0, _points);
    }
    _points[_length++] = world.dx - origin.dx;
    _points[_length++] = world.dy - origin.dy;
    _show();
  }

  BoardElement _element(Float32List points, int z) {
    final controller = view.controller;
    return BoardElement(
      id: id,
      kind: ElementKind.stroke,
      z: z,
      x: origin.dx,
      y: origin.dy,
      points: points,
      color: highlighter ? controller.color & 0x00FFFFFF | 0x66000000 : controller.color,
      strokeWidth: highlighter ? controller.strokeWidth * 4 : controller.strokeWidth,
    );
  }

  void _show() {
    final draft = _element(Float32List.sublistView(_points, 0, _length), 0);
    view._interaction
      ..draft = draft
      ..changed();
    view.session.showDraft(draft);
  }

  @override
  void end() {
    final points = simplify(
      Float32List.sublistView(_points, 0, _length),
      0.4 / view.controller.scale,
    );
    view.session.apply(put: [_element(points, view.board.topZ + 1)]);
    cancel();
  }

  @override
  void cancel() {
    view._interaction
      ..draft = null
      ..changed();
    view.session.showDraft(null);
  }
}

class _Shape implements _Gesture {
  _Shape(this.view, this.start, this.kind);

  final _BoardViewState view;
  final Offset start;
  final ElementKind kind;
  final id = randomId();
  BoardElement? _draft;

  @override
  void move(Offset world, PointerMoveEvent event) {
    final draft = _draft = _element(world, HardwareKeyboard.instance.isShiftPressed);
    view._interaction
      ..draft = draft
      ..changed();
    view.session.showDraft(draft);
  }

  BoardElement _element(Offset end, bool constrained) {
    final controller = view.controller;
    var delta = end - start;
    if (kind == ElementKind.line || kind == ElementKind.arrow) {
      if (constrained) {
        const step = math.pi / 12;
        delta = Offset.fromDirection((delta.direction / step).round() * step, delta.distance);
      }
      return BoardElement(
        id: id,
        kind: kind,
        z: 0,
        x: start.dx,
        y: start.dy,
        points: Float32List.fromList([0, 0, delta.dx, delta.dy]),
        color: controller.color,
        strokeWidth: controller.strokeWidth,
      );
    }
    if (constrained) {
      final side = math.max(delta.dx.abs(), delta.dy.abs());
      delta = Offset(side * (delta.dx < 0 ? -1 : 1), side * (delta.dy < 0 ? -1 : 1));
    }
    final rect = Rect.fromPoints(start, start + delta);
    return BoardElement(
      id: id,
      kind: kind,
      z: 0,
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height,
      color: controller.color,
      strokeWidth: controller.strokeWidth,
      filled: controller.filled,
    );
  }

  @override
  void end() {
    final draft = _draft;
    if (draft != null && draft.bounds.longestSide * view.controller.scale > 4) {
      view.session.apply(put: [draft.copyWith(z: view.board.topZ + 1)]);
    }
    cancel();
  }

  @override
  void cancel() {
    view._interaction
      ..draft = null
      ..changed();
    view.session.showDraft(null);
  }
}

class _Eraser implements _Gesture {
  _Eraser(this.view, Offset start) : _last = start {
    _sweep(start);
  }

  final _BoardViewState view;
  final _ids = <String>{};
  Offset _last;

  @override
  void move(Offset world, PointerMoveEvent event) => _sweep(world);

  void _sweep(Offset to) {
    final tolerance = view.tolerance;
    final steps = math.max(1, ((to - _last).distance / tolerance).ceil());
    final before = _ids.length;
    final swept = Rect.fromPoints(_last, to).inflate(tolerance);
    final near = [
      for (final e in view.board.elements)
        if (e.bounds.overlaps(swept) && !_ids.contains(e.id)) e,
    ];
    for (var i = 1; i <= steps && near.isNotEmpty; i++) {
      final p = Offset.lerp(_last, to, i / steps)!;
      for (final e in near) {
        if (!_ids.contains(e.id) && hits(e, p, tolerance)) _ids.add(e.id);
      }
    }
    _last = to;
    if (_ids.length != before) {
      view._interaction
        ..erasing = {..._ids}
        ..changed();
    }
  }

  @override
  void end() {
    view.session.apply(delete: _ids);
    cancel();
  }

  @override
  void cancel() {
    view._interaction
      ..erasing = const {}
      ..changed();
  }
}

class _Move implements _Gesture {
  _Move(this.view, this.start);

  final _BoardViewState view;
  final Offset start;
  var _shift = Offset.zero;

  @override
  void move(Offset world, PointerMoveEvent event) {
    _shift = world - start;
    view._interaction
      ..lifted = view.controller.selection
      ..shift = _shift
      ..changed();
  }

  @override
  void end() {
    if (_shift != Offset.zero) {
      view.session.apply(put: [for (final e in view.controller.selected) e.translated(_shift)]);
    }
    cancel();
  }

  @override
  void cancel() {
    view._interaction
      ..lifted = const {}
      ..shift = Offset.zero
      ..changed();
  }
}

class _Marquee implements _Gesture {
  _Marquee(this.view, this.start, {required this.additive});

  final _BoardViewState view;
  final Offset start;
  final bool additive;

  @override
  void move(Offset world, PointerMoveEvent event) {
    view._interaction
      ..marquee = Rect.fromPoints(start, world)
      ..changed();
  }

  @override
  void end() {
    final rect = view._interaction.marquee;
    if (rect != null) {
      final inside = [
        for (final e in view.board.elements)
          if (rect.contains(e.bounds.topLeft) && rect.contains(e.bounds.bottomRight)) e.id,
      ];
      view.controller.select(additive ? {...view.controller.selection, ...inside} : inside);
    }
    cancel();
  }

  @override
  void cancel() {
    view._interaction
      ..marquee = null
      ..changed();
  }
}

class _ScenePainter extends CustomPainter {
  _ScenePainter({
    required this.scene,
    required this.board,
    required this.controller,
    required this.hidden,
    required this.grid,
  }) : super(repaint: Listenable.merge([board, controller, hidden]));

  static const _spacing = 24.0;

  final Scene scene;
  final Board board;
  final BoardController controller;
  final ValueListenable<Set<String>> hidden;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    scene.sync(board, hidden.value);
    _grid(canvas, size);
    canvas
      ..save()
      ..translate(controller.offset.dx, controller.offset.dy)
      ..scale(controller.scale);
    scene.paint(canvas);
    canvas.restore();
  }

  void _grid(Canvas canvas, Size size) {
    var step = _spacing * controller.scale;
    while (step < 16) {
      step *= 2;
    }
    final left = controller.offset.dx % step, top = controller.offset.dy % step;
    final columns = math.max(0, ((size.width - left) / step).ceil());
    final rows = math.max(0, ((size.height - top) / step).ceil());
    final points = Float32List(2 * columns * rows);
    var i = 0;
    for (var c = 0; c < columns; c++) {
      for (var r = 0; r < rows; r++) {
        points[i++] = left + c * step;
        points[i++] = top + r * step;
      }
    }
    canvas.drawRawPoints(
      PointMode.points,
      points,
      Paint()
        ..color = grid
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ScenePainter old) => old.grid != grid || old.board != board;
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.session,
    required this.controller,
    required this.interaction,
    required this.accent,
    required this.labels,
  }) : super(repaint: Listenable.merge([session.board, session.presence, controller, interaction]));

  final BoardSession session;
  final BoardController controller;
  final _Interaction interaction;
  final Color accent;
  final Map<String, TextPainter> labels;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = controller.scale;
    final board = session.board;
    canvas
      ..save()
      ..translate(controller.offset.dx, controller.offset.dy)
      ..scale(scale);

    for (final id in interaction.erasing) {
      final e = board[id];
      if (e != null) paintElement(canvas, e, opacity: 0.25);
    }
    for (final id in interaction.lifted) {
      final e = board[id];
      if (e != null) paintElement(canvas, e.translated(interaction.shift));
    }
    for (final peer in session.peers) {
      final draft = peer.draft;
      if (draft != null) paintElement(canvas, draft);
    }
    final draft = interaction.draft;
    if (draft != null) paintElement(canvas, draft);

    final line = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / scale;
    final shift = interaction.lifted.isEmpty ? Offset.zero : interaction.shift;
    for (final e in controller.selected) {
      canvas.drawRect(e.bounds.shift(shift).inflate(4 / scale), line);
    }
    final marquee = interaction.marquee;
    if (marquee != null) {
      canvas
        ..drawRect(marquee, Paint()..color = accent.withValues(alpha: 0.08))
        ..drawRect(marquee, line);
    }
    canvas.restore();

    for (final peer in session.peers) {
      final cursor = peer.cursor;
      if (cursor != null) _cursor(canvas, controller.toScreen(cursor), peer.name);
    }
  }

  void _cursor(Canvas canvas, Offset at, String name) {
    final arrow = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 16)
      ..lineTo(4.5, 12.5)
      ..lineTo(11, 12.5)
      ..close();
    canvas
      ..save()
      ..translate(at.dx, at.dy)
      ..drawPath(arrow, Paint()..color = accent)
      ..drawPath(
        arrow,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    if (name.isNotEmpty) {
      final label = labels[name] ??= TextPainter(
        text: TextSpan(
          text: name,
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 160);
      final box = Rect.fromLTWH(10, 18, label.width + 12, label.height + 6);
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(6)),
        Paint()..color = accent,
      );
      label.paint(canvas, box.topLeft + const Offset(6, 3));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OverlayPainter old) => old.accent != accent || old.session != session;
}
