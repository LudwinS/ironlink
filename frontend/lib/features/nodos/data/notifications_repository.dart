import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';

/// Notificación persistente (IRL-NTF-US-01 recordatorios, IRL-NTF-US-03 panel).
class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.nodeId,
    required this.nodeName,
    required this.meetingId,
    required this.title,
    required this.scheduledFor,
    required this.createdAt,
    required this.meetingState,
    this.readAt,
  });
  final String id, type, nodeId, nodeName, meetingId, title, meetingState;
  final DateTime scheduledFor, createdAt;
  final DateTime? readAt;

  bool get unread => readAt == null;

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      AppNotification(
        id: json['id'] as String,
        type: json['tipo'] as String,
        nodeId: json['nodo_id'] as String,
        nodeName: json['nodo_nombre'] as String,
        meetingId: json['reunion_id'] as String,
        title: json['titulo'] as String,
        scheduledFor: DateTime.parse(json['programada_para'] as String),
        createdAt: DateTime.parse(json['created_at'] as String),
        readAt: json['read_at'] == null
            ? null
            : DateTime.parse(json['read_at'] as String),
        meetingState: json['reunion_estado'] as String,
      );

  AppNotification markedRead() => AppNotification(
    id: id,
    type: type,
    nodeId: nodeId,
    nodeName: nodeName,
    meetingId: meetingId,
    title: title,
    scheduledFor: scheduledFor,
    createdAt: createdAt,
    meetingState: meetingState,
    readAt: readAt ?? DateTime.now(),
  );

  /// Texto principal en la hora local del dispositivo.
  String get message {
    final t = scheduledFor.toLocal();
    final hour =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return switch (type) {
      'recordatorio_15' || 'recordatorio_5' => '«$title» empieza a las $hour',
      'reunion_iniciada' => '«$title» ya comenzó',
      'invitacion' => 'Te invitaron a «$title» · ${t.day}/${t.month} $hour',
      _ => title,
    };
  }

  String get kindLabel => switch (type) {
    'recordatorio_15' => 'Recordatorio · 15 min antes',
    'recordatorio_5' => 'Recordatorio · 5 min antes',
    'reunion_iniciada' => 'Reunión iniciada',
    'invitacion' => 'Invitación',
    _ => 'Aviso',
  };
}

class NotificationsRepository {
  NotificationsRepository({Dio? client})
    : _client = client ?? ApiClient.instance;
  final Dio _client;

  /// Notificaciones de hoy según la zona horaria del dispositivo.
  Future<List<AppNotification>> today({DateTime? now}) async {
    final local = now ?? DateTime.now();
    final midnight = DateTime(local.year, local.month, local.day);
    try {
      final response = await _client.get(
        '/notificaciones',
        queryParameters: {'desde': midnight.toUtc().toIso8601String()},
      );
      final data = response.data as Map<String, dynamic>;
      return [
        for (final row in data['notificaciones'] as List)
          AppNotification.fromJson(Map<String, dynamic>.from(row as Map)),
      ];
    } on DioException catch (e) {
      throw NotificationsException(_message(e, 'cargar'));
    }
  }

  Future<void> markRead(List<String> ids) => _mark({'ids': ids});

  Future<void> markAllRead() => _mark({'todas': true});

  Future<void> _mark(Map<String, dynamic> body) async {
    try {
      await _client.post('/notificaciones/leidas', data: body);
    } on DioException catch (e) {
      throw NotificationsException(_message(e, 'actualizar'));
    }
  }

  static String _message(DioException e, String action) {
    final data = e.response?.data;
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    return 'No se pudieron $action las notificaciones. Revisa tu conexión.';
  }
}

class NotificationsException implements Exception {
  const NotificationsException(this.message);
  final String message;
  @override
  String toString() => message;
}
