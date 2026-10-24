import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/whiteboard_controller.dart';
import '../../../../core/notify/iron_notice.dart';
import '../../../../core/notify/iron_notify.dart';

/// Fondo fijo del lienzo: igual en todos los temas y en la imagen exportada.
const whiteboardBackground = Color(0xFF1D1F2C);

/// Pizarra compartida del canal actual de la llamada (IRL-RTC-US-08).
class WhiteboardPage extends StatefulWidget {
  const WhiteboardPage({
    super.key,
    required this.controller,
    required this.title,
    this.saveFile,
  });
  final WhiteboardController controller;
  final String title;
  final Future<String?> Function(String name, Uint8List bytes)? saveFile;

  @override
  State<WhiteboardPage> createState() => _WhiteboardPageState();
}

enum _Tool { pen, eraser }

class _WhiteboardPageState extends State<WhiteboardPage> {
  WhiteboardController get board => widget.controller;
  String _color = whiteboardColors.first;
  double _width = 4;
  _Tool _tool = _Tool.pen;
  List<Offset> _current = [];

  @override
  void initState() {
    super.initState();
    board.load();
    board.addListener(_showErrors);
  }

  @override
  void dispose() {
    board.removeListener(_showErrors);
    super.dispose();
  }

  String? _lastError;
  void _showErrors() {
    final error = board.error;
    if (error == null || error == _lastError || !mounted) return;
    _lastError = error;
    IronNotify.show(IronNotice(kind: NoticeKind.error, title: error));
  }

  Offset _normalize(Offset local, Size size) => Offset(
    (local.dx / size.width).clamp(0.0, 1.0),
    (local.dy / size.height).clamp(0.0, 1.0),
  );

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Limpiar la pizarra?'),
        content: const Text(
          'Se borran todos los trazos para todas las personas de esta sala.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Limpiar'),
          ),
        ],
      ),
    );
    if (confirmed == true) await board.clear();
  }

  Future<void> _export() async {
    const size = Size(1600, 900);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    WhiteboardPainter(board.strokes, const []).paint(canvas, size);
    final image = await recorder.endRecording().toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null || !mounted) return;
    final bytes = data.buffer.asUint8List();
    final save =
        widget.saveFile ??
        (String name, Uint8List bytes) => FilePicker.saveFile(
          dialogTitle: 'Guardar pizarra',
          fileName: name,
          type: FileType.custom,
          allowedExtensions: const ['png'],
          bytes: bytes,
        );
    final now = DateTime.now();
    final name =
        'pizarra-${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}.png';
    try {
      final path = await save(name, bytes);
      if (!mounted) return;
      if (path != null || kIsWeb) {
        IronNotify.show(
          IronNotice(
            kind: NoticeKind.success,
            title: path == null
                ? 'Descarga iniciada.'
                : 'Pizarra guardada en $path',
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        IronNotify.show(
          IronNotice(
            kind: NoticeKind.error,
            title: 'No se pudo guardar la imagen.',
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: board,
      builder: (context, _) => Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            IconButton(
              tooltip: 'Exportar como imagen',
              onPressed: board.strokes.isEmpty ? null : _export,
              icon: const Icon(Icons.image_outlined),
            ),
          ],
        ),
        body: Column(
          children: [
            _toolbar(),
            if (!board.canDraw && !board.loading)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Solo quien modera puede dibujar en esta pizarra.',
                  style: TextStyle(color: AppColors.textMuted),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: board.loading
                        ? const Center(child: CircularProgressIndicator())
                        : _canvas(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _canvas() => LayoutBuilder(
    builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      return Semantics(
        label:
            'Pizarra con ${board.strokes.length} ${board.strokes.length == 1 ? 'trazo' : 'trazos'}',
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: MouseRegion(
            cursor: !board.canDraw
                ? SystemMouseCursors.basic
                : _tool == _Tool.pen
                ? SystemMouseCursors.precise
                : SystemMouseCursors.click,
            child: GestureDetector(
              onTapUp: !board.canDraw || _tool != _Tool.eraser
                  ? null
                  : (d) {
                      final target = board.hit(
                        _normalize(d.localPosition, size),
                        size,
                      );
                      if (target != null && board.canDelete(target)) {
                        board.deleteStroke(target);
                      }
                    },
              onPanStart: !board.canDraw || _tool != _Tool.pen
                  ? null
                  : (d) => setState(
                      () => _current = [_normalize(d.localPosition, size)],
                    ),
              onPanUpdate: !board.canDraw || _tool != _Tool.pen
                  ? null
                  : (d) {
                      final point = _normalize(d.localPosition, size);
                      // Puntos casi iguales no aportan y gastan el límite.
                      if (_current.isNotEmpty &&
                          (_current.last - point).distance * size.width < 1.5) {
                        return;
                      }
                      if (_current.length < 1990) {
                        setState(() => _current = [..._current, point]);
                      }
                    },
              onPanEnd: !board.canDraw || _tool != _Tool.pen
                  ? null
                  : (_) {
                      final points = _current;
                      setState(() => _current = []);
                      board.addStroke(points, _color, _width);
                    },
              child: CustomPaint(
                size: size,
                painter: WhiteboardPainter(board.strokes, [
                  if (_current.isNotEmpty)
                    WhiteboardStroke(
                      id: 'drawing',
                      userId: '',
                      points: _current,
                      color: _color,
                      width: _width,
                      pending: true,
                    ),
                ]),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _toolbar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (board.canDraw) ...[
          SegmentedButton<_Tool>(
            segments: const [
              ButtonSegment(
                value: _Tool.pen,
                icon: Icon(Icons.edit_outlined),
                label: Text('Lápiz'),
              ),
              ButtonSegment(
                value: _Tool.eraser,
                icon: Icon(Icons.auto_fix_normal_outlined),
                label: Text('Borrar trazo'),
              ),
            ],
            selected: {_tool},
            onSelectionChanged: (v) => setState(() => _tool = v.first),
          ),
          for (final color in whiteboardColors)
            Semantics(
              button: true,
              selected: color == _color,
              label: 'Color ${whiteboardColors.indexOf(color) + 1}',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => setState(() {
                  _color = color;
                  _tool = _Tool.pen;
                }),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: parseHexColor(color),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: color == _color
                          ? AppColors.accentText
                          : AppColors.line,
                      width: color == _color ? 3 : 1,
                    ),
                  ),
                ),
              ),
            ),
          DropdownButton<double>(
            value: _width,
            onChanged: (v) => setState(() => _width = v ?? _width),
            items: const [
              DropdownMenuItem(value: 2, child: Text('Fino')),
              DropdownMenuItem(value: 4, child: Text('Medio')),
              DropdownMenuItem(value: 10, child: Text('Grueso')),
            ],
          ),
          IconButton(
            tooltip: 'Deshacer mi último trazo',
            onPressed: board.canUndo ? board.undo : null,
            icon: const Icon(Icons.undo_rounded),
          ),
        ],
        if (board.canModerate) ...[
          FilterChip(
            label: const Text('Todos pueden dibujar'),
            selected: board.everyone,
            onSelected: board.setEveryone,
          ),
          TextButton.icon(
            onPressed: board.strokes.isEmpty ? null : _clear,
            icon: const Icon(Icons.layers_clear_outlined, size: 18),
            label: const Text('Limpiar'),
          ),
        ],
      ],
    ),
  );
}

class WhiteboardPainter extends CustomPainter {
  WhiteboardPainter(this.strokes, this.extra);
  final List<WhiteboardStroke> strokes, extra;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = whiteboardBackground);
    // El grosor se define para un lienzo de 1000 px de ancho.
    final scale = size.width / 1000;
    for (final stroke in [...strokes, ...extra]) {
      final paint = Paint()
        ..color = parseHexColor(
          stroke.color,
        ).withValues(alpha: stroke.pending ? .75 : 1)
        ..strokeWidth = stroke.width * scale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final points = [
        for (final p in stroke.points)
          Offset(p.dx * size.width, p.dy * size.height),
      ];
      if (points.length == 1) {
        canvas.drawCircle(
          points.first,
          paint.strokeWidth / 2,
          paint..style = PaintingStyle.fill,
        );
        continue;
      }
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final p in points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(WhiteboardPainter old) =>
      old.strokes != strokes ||
      old.extra.length != extra.length ||
      (extra.isNotEmpty &&
          old.extra.first.points.length != extra.first.points.length);
}
