import 'dart:async';
import 'dart:ui';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../core/network/api_client.dart';

/// Colores que acepta el servidor (paleta Nocturne y de estado). El último es
/// el fondo del lienzo oscuro, así que no se ofrece para dibujar.
const whiteboardColors = [
  '#e9e9ed',
  '#9184d9',
  '#ef4444',
  '#10b981',
  '#fcd34d',
  '#38bdf8',
];

Color parseHexColor(String hex) =>
    Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));

/// Trazo con coordenadas normalizadas (0..1) sobre un lienzo 16:9.
class WhiteboardStroke {
  const WhiteboardStroke({
    required this.id,
    required this.userId,
    required this.points,
    required this.color,
    required this.width,
    this.pending = false,
  });
  final String id, userId, color;
  final List<Offset> points;
  final double width;

  /// Dibujado localmente y aún sin confirmar por el servidor.
  final bool pending;

  factory WhiteboardStroke.fromJson(Map<String, dynamic> json) {
    final data = Map<String, dynamic>.from(json['datos'] as Map);
    return WhiteboardStroke(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      points: [
        for (final p in data['puntos'] as List)
          Offset(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()),
      ],
      color: data['color'] as String,
      width: (data['grosor'] as num).toDouble(),
    );
  }
}

class WhiteboardException implements Exception {
  const WhiteboardException(this.message);
  final String message;
  @override
  String toString() => message;
}

class WhiteboardRepository {
  WhiteboardRepository({Dio? client}) : _client = client ?? ApiClient.instance;
  final Dio _client;

  String _base(String nodeId, String reunionId) =>
      '/nodos/$nodeId/reuniones/$reunionId/pizarra';

  Future<Map<String, dynamic>> load(
    String nodeId,
    String reunionId,
    String? salaId,
  ) => _call(
    () => _client.get(
      _base(nodeId, reunionId),
      queryParameters: {'sala_id': ?salaId},
    ),
  );

  Future<Map<String, dynamic>> add(
    String nodeId,
    String reunionId,
    String? salaId,
    List<Offset> points,
    String color,
    double width,
  ) => _call(
    () => _client.post(
      '${_base(nodeId, reunionId)}/trazos',
      data: {
        'sala_id': salaId,
        'puntos': [
          for (final p in points) [p.dx, p.dy],
        ],
        'color': color,
        'grosor': width,
      },
    ),
  );

  Future<void> delete(String nodeId, String reunionId, String strokeId) =>
      _call(
        () => _client.delete('${_base(nodeId, reunionId)}/trazos/$strokeId'),
      );

  Future<void> clear(String nodeId, String reunionId, String? salaId) => _call(
    () => _client.delete(
      _base(nodeId, reunionId),
      queryParameters: {'sala_id': ?salaId},
    ),
  );

  Future<void> setEveryone(
    String nodeId,
    String reunionId,
    String? salaId,
    bool everyone,
  ) => _call(
    () => _client.put(
      '${_base(nodeId, reunionId)}/permisos',
      data: {'sala_id': salaId, 'todos_dibujan': everyone},
    ),
  );

  Future<Map<String, dynamic>> _call(
    Future<Response<dynamic>> Function() send,
  ) async {
    try {
      final response = await send();
      final data = response.data;
      return data is Map ? Map<String, dynamic>.from(data) : const {};
    } on DioException catch (e) {
      final data = e.response?.data;
      throw WhiteboardException(
        data is Map && data['message'] is String
            ? data['message'] as String
            : 'No se pudo actualizar la pizarra. Revisa tu conexión.',
      );
    }
  }
}

/// Estado de la pizarra de un canal (IRL-RTC-US-08): carga inicial desde el
/// servidor y eventos en vivo del canal de la llamada.
class WhiteboardController extends ChangeNotifier {
  WhiteboardController({
    required this.nodeId,
    required this.reunionId,
    required this.salaId,
    required this.ownUserId,
    required Stream<Map<String, dynamic>> events,
    WhiteboardRepository? repository,
  }) : _repository = repository ?? WhiteboardRepository() {
    _events = events.listen(apply);
  }

  final String nodeId, reunionId;
  final String? salaId, ownUserId;
  final WhiteboardRepository _repository;
  late final StreamSubscription<Map<String, dynamic>> _events;

  List<WhiteboardStroke> strokes = [];
  bool loading = true, canDraw = false, canModerate = false, everyone = false;
  String? error;
  int _pendingSeq = 0;

  /// Última secuencia aplicada. El servidor puede descartar un evento si la
  /// cola de esta conexión se llena; un salto obliga a recargar el lienzo.
  int? _seq;
  final List<Map<String, dynamic>> _queued = [];

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final data = await _repository.load(nodeId, reunionId, salaId);
      _seq = (data['seq'] as num?)?.toInt();
      strokes = [
        for (final s in data['trazos'] as List)
          WhiteboardStroke.fromJson(Map<String, dynamic>.from(s as Map)),
      ];
      canDraw = data['puede_dibujar'] == true;
      canModerate = data['puede_moderar'] == true;
      everyone = data['todos_dibujan'] == true;
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    // Eventos recibidos durante la carga: solo los posteriores a ella.
    final queued = List.of(_queued);
    _queued.clear();
    for (final event in queued) {
      apply(event);
    }
    notifyListeners();
  }

  /// Evento `whiteboard` del servidor para este canal.
  void apply(Map<String, dynamic> event) {
    final seq = (event['seq'] as num?)?.toInt();
    if (seq != null) {
      if (loading) {
        _queued.add(event);
        return;
      }
      final last = _seq;
      if (last != null && seq <= last) return; // Ya incluido en la carga.
      if (last != null && seq > last + 1) {
        // Se perdió al menos un evento: el lienzo local ya no es fiable.
        unawaited(load());
        return;
      }
      _seq = seq;
    }
    switch (event['op']) {
      case 'stroke':
        final stroke = WhiteboardStroke.fromJson(
          Map<String, dynamic>.from(event['trazo'] as Map),
        );
        if (strokes.any((s) => s.id == stroke.id)) return;
        strokes = [...strokes, stroke];
      case 'delete':
        strokes = strokes.where((s) => s.id != event['id']).toList();
      case 'clear':
        strokes = [];
      case 'permissions':
        everyone = event['todos_dibujan'] == true;
        canDraw = canModerate || everyone;
      default:
        return;
    }
    notifyListeners();
  }

  /// Envía un trazo terminado; se ve al instante y se confirma después.
  Future<void> addStroke(
    List<Offset> points,
    String color,
    double width,
  ) async {
    if (!canDraw || points.isEmpty) return;
    final temp = WhiteboardStroke(
      id: 'local-${_pendingSeq++}',
      userId: ownUserId ?? '',
      points: points,
      color: color,
      width: width,
      pending: true,
    );
    strokes = [...strokes, temp];
    error = null;
    notifyListeners();
    try {
      final data = await _repository.add(
        nodeId,
        reunionId,
        salaId,
        points,
        color,
        width,
      );
      final saved = WhiteboardStroke.fromJson(
        Map<String, dynamic>.from(data['trazo'] as Map),
      );
      // El evento en vivo pudo llegar antes que la respuesta.
      final already = strokes.any((s) => s.id == saved.id);
      strokes = [
        for (final s in strokes)
          if (s.id != temp.id) s else if (!already) saved,
      ];
    } catch (e) {
      strokes = strokes.where((s) => s.id != temp.id).toList();
      error = e.toString();
    }
    notifyListeners();
  }

  bool canDelete(WhiteboardStroke stroke) =>
      !stroke.pending &&
      (canModerate || (canDraw && stroke.userId == ownUserId));

  Future<void> deleteStroke(WhiteboardStroke stroke) async {
    if (!canDelete(stroke)) return;
    final before = strokes;
    strokes = strokes.where((s) => s.id != stroke.id).toList();
    notifyListeners();
    try {
      await _repository.delete(nodeId, reunionId, stroke.id);
    } catch (e) {
      strokes = before;
      error = e.toString();
      notifyListeners();
    }
  }

  /// Deshace el último trazo propio confirmado.
  Future<void> undo() async {
    final mine = strokes.lastWhere(
      (s) => s.userId == ownUserId && !s.pending,
      orElse: () => const WhiteboardStroke(
        id: '',
        userId: '',
        points: [],
        color: '',
        width: 0,
      ),
    );
    if (mine.id.isNotEmpty) await deleteStroke(mine);
  }

  bool get canUndo =>
      canDraw && strokes.any((s) => s.userId == ownUserId && !s.pending);

  Future<void> clear() async {
    if (!canModerate) return;
    try {
      await _repository.clear(nodeId, reunionId, salaId);
      strokes = [];
    } catch (e) {
      error = e.toString();
    }
    notifyListeners();
  }

  Future<void> setEveryone(bool value) async {
    if (!canModerate) return;
    try {
      await _repository.setEveryone(nodeId, reunionId, salaId, value);
      everyone = value;
    } catch (e) {
      error = e.toString();
    }
    notifyListeners();
  }

  /// Trazo bajo un punto normalizado (para el borrador), el más reciente.
  WhiteboardStroke? hit(Offset at, Size canvas) {
    for (final stroke in strokes.reversed) {
      final tolerance = (stroke.width / 2 + 8);
      for (final p in stroke.points) {
        final dx = (p.dx - at.dx) * canvas.width;
        final dy = (p.dy - at.dy) * canvas.height;
        if (dx * dx + dy * dy <= tolerance * tolerance) return stroke;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _events.cancel();
    super.dispose();
  }
}
