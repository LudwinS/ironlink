import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';

/// Una conexión a la sala: entrada, salida y motivo (IRL-SEC-US-01).
class AttendanceSession {
  const AttendanceSession({
    required this.userId,
    required this.name,
    required this.joinedAt,
    required this.seconds,
    this.leftAt,
    this.exit,
  });
  final String userId, name;
  final DateTime joinedAt;
  final DateTime? leftAt;
  final String? exit;
  final int seconds;

  bool get open => leftAt == null;

  factory AttendanceSession.fromJson(Map<String, dynamic> json) =>
      AttendanceSession(
        userId: json['user_id'] as String,
        name: json['nombre'] as String,
        joinedAt: DateTime.parse(json['joined_at'] as String),
        leftAt: json['left_at'] == null
            ? null
            : DateTime.parse(json['left_at'] as String),
        exit: json['salida'] as String?,
        seconds: (json['segundos'] as num).toInt(),
      );

  /// Texto del motivo de salida guardado por el servidor.
  static String exitLabel(String? code) => switch (code) {
    null => 'Sigue conectado',
    'salio' => 'Salió',
    'conexion_perdida' => 'Conexión perdida',
    'expulsado' => 'Expulsado',
    'reunion_finalizada' => 'Reunión finalizada',
    'reemplazada' => 'Conexión reemplazada',
    'sin_autorizacion' => 'Perdió el acceso',
    'limite_sesion' => 'Límite de sesión',
    'servidor_reiniciado' => 'Servidor reiniciado',
    _ => code,
  };
}

/// Resumen por persona: tiempo total sin contar dos veces (IRL-SEC-US-02).
class AttendanceParticipant {
  const AttendanceParticipant({
    required this.userId,
    required this.name,
    required this.email,
    required this.sessions,
    required this.firstJoin,
    required this.connectedNow,
    required this.seconds,
    this.lastLeave,
    this.percent,
  });
  final String userId, name, email;
  final int sessions, seconds;
  final DateTime firstJoin;
  final DateTime? lastLeave;
  final bool connectedNow;
  final double? percent;

  factory AttendanceParticipant.fromJson(Map<String, dynamic> json) =>
      AttendanceParticipant(
        userId: json['user_id'] as String,
        name: json['nombre'] as String,
        email: json['correo'] as String,
        sessions: (json['sesiones'] as num).toInt(),
        firstJoin: DateTime.parse(json['primera_entrada'] as String),
        lastLeave: json['ultima_salida'] == null
            ? null
            : DateTime.parse(json['ultima_salida'] as String),
        connectedNow: json['conectado_ahora'] == true,
        seconds: (json['segundos_conectado'] as num).toInt(),
        percent: (json['porcentaje'] as num?)?.toDouble(),
      );
}

class AttendanceReport {
  const AttendanceReport({
    required this.title,
    required this.state,
    required this.participants,
    required this.sessions,
    this.start,
    this.end,
    this.durationSeconds,
  });
  final String title, state;
  final DateTime? start, end;
  final int? durationSeconds;
  final List<AttendanceParticipant> participants;
  final List<AttendanceSession> sessions;

  factory AttendanceReport.fromJson(Map<String, dynamic> json) =>
      AttendanceReport(
        title: json['titulo'] as String,
        state: json['estado'] as String,
        start: json['inicio'] == null
            ? null
            : DateTime.parse(json['inicio'] as String),
        end: json['fin'] == null ? null : DateTime.parse(json['fin'] as String),
        durationSeconds: (json['duracion_segundos'] as num?)?.toInt(),
        participants: [
          for (final p in json['participantes'] as List)
            AttendanceParticipant.fromJson(Map<String, dynamic>.from(p as Map)),
        ],
        sessions: [
          for (final s in json['sesiones'] as List)
            AttendanceSession.fromJson(Map<String, dynamic>.from(s as Map)),
        ],
      );

  List<AttendanceSession> sessionsOf(String userId) =>
      sessions.where((s) => s.userId == userId).toList();
}

/// Error con el mensaje del servidor, listo para mostrar.
class AttendanceException implements Exception {
  const AttendanceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AttendanceRepository {
  AttendanceRepository({Dio? client}) : _client = client ?? ApiClient.instance;
  final Dio _client;

  String _path(String nodeId, String reunionId) =>
      '/nodos/$nodeId/reuniones/$reunionId/asistencia';

  Future<AttendanceReport> fetch(String nodeId, String reunionId) async {
    try {
      final response = await _client.get(_path(nodeId, reunionId));
      final data = response.data as Map<String, dynamic>;
      return AttendanceReport.fromJson(
        Map<String, dynamic>.from(data['asistencia'] as Map),
      );
    } on DioException catch (e) {
      throw AttendanceException(_message(e));
    }
  }

  /// CSV generado por el servidor (UTF-8 con BOM, fórmulas neutralizadas).
  Future<Uint8List> csv(String nodeId, String reunionId) async {
    try {
      final response = await _client.get<List<int>>(
        '${_path(nodeId, reunionId)}.csv',
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data ?? const []);
    } on DioException catch (e) {
      throw AttendanceException(_message(e));
    }
  }

  static String _message(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    return 'No se pudo cargar la asistencia. Revisa tu conexión.';
  }
}
