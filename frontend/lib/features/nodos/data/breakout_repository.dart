import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';

/// Destino de un cambio de sala: una sala de trabajo o la principal.
class BreakoutTarget {
  const BreakoutTarget(this.id, this.name);
  static const main = BreakoutTarget(null, 'Sala principal');
  final String? id;
  final String name;
  bool get isMain => id == null;

  static BreakoutTarget parse(dynamic raw) {
    if (raw is Map && raw['id'] is String && raw['nombre'] is String) {
      return BreakoutTarget(raw['id'] as String, raw['nombre'] as String);
    }
    return main;
  }

  @override
  bool operator ==(Object other) => other is BreakoutTarget && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class BreakoutPerson {
  const BreakoutPerson(this.userId, this.name, {this.salaId});
  final String userId, name;

  /// Canal actual (solo en la lista de conectados); `null` = principal.
  final String? salaId;

  factory BreakoutPerson.fromJson(Map<String, dynamic> json) => BreakoutPerson(
    json['user_id'] as String,
    (json['nombre'] as String?) ?? '',
    salaId: json['sala_id'] as String?,
  );
}

class BreakoutRoom {
  const BreakoutRoom(this.id, this.name, this.members);
  final String id, name;
  final List<BreakoutPerson> members;

  factory BreakoutRoom.fromJson(Map<String, dynamic> json) =>
      BreakoutRoom(json['id'] as String, json['nombre'] as String, [
        for (final m in json['miembros'] as List)
          BreakoutPerson.fromJson(Map<String, dynamic>.from(m as Map)),
      ]);
}

class BreakoutState {
  const BreakoutState({
    required this.rooms,
    required this.mine,
    required this.canModerate,
    required this.capacity,
    required this.connected,
  });
  final List<BreakoutRoom> rooms;
  final BreakoutTarget mine;
  final bool canModerate;
  final int capacity;
  final List<BreakoutPerson> connected;

  bool get open => rooms.isNotEmpty;

  factory BreakoutState.fromJson(Map<String, dynamic> json) => BreakoutState(
    rooms: [
      for (final r in json['salas'] as List)
        BreakoutRoom.fromJson(Map<String, dynamic>.from(r as Map)),
    ],
    mine: BreakoutTarget.parse(json['mi_sala']),
    canModerate: json['puede_moderar'] == true,
    capacity: (json['capacidad_por_sala'] as num?)?.toInt() ?? 3,
    connected: [
      for (final c in (json['conectados'] as List?) ?? const [])
        BreakoutPerson.fromJson(Map<String, dynamic>.from(c as Map)),
    ],
  );
}

/// Sala a crear: nombre y personas asignadas.
class BreakoutDraft {
  BreakoutDraft(this.name, [List<String>? members]) : members = members ?? [];
  String name;
  final List<String> members;
  Map<String, dynamic> toJson() => {'nombre': name, 'miembros': members};
}

class BreakoutException implements Exception {
  const BreakoutException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BreakoutRepository {
  BreakoutRepository({Dio? client}) : _client = client ?? ApiClient.instance;
  final Dio _client;

  String _path(String nodeId, String reunionId) =>
      '/nodos/$nodeId/reuniones/$reunionId/salas';

  Future<BreakoutState> fetch(String nodeId, String reunionId) =>
      _call(() => _client.get(_path(nodeId, reunionId)));

  Future<BreakoutState> open(
    String nodeId,
    String reunionId,
    List<BreakoutDraft> rooms,
  ) => _call(
    () => _client.put(
      _path(nodeId, reunionId),
      data: {
        'salas': [for (final r in rooms) r.toJson()],
      },
    ),
  );

  Future<BreakoutState> close(String nodeId, String reunionId) =>
      _call(() => _client.delete(_path(nodeId, reunionId)));

  Future<BreakoutState> _call(Future<Response<dynamic>> Function() send) async {
    try {
      final response = await send();
      return BreakoutState.fromJson(
        Map<String, dynamic>.from(response.data as Map),
      );
    } on DioException catch (e) {
      final data = e.response?.data;
      throw BreakoutException(
        data is Map && data['message'] is String
            ? data['message'] as String
            : 'No se pudieron actualizar las salas. Revisa tu conexión.',
      );
    }
  }

  /// Reparte a las personas en [count] salas por turnos, sin superar la
  /// capacidad. Devuelve las salas y quienes no cupieron.
  static (List<BreakoutDraft>, List<String>) distribute(
    List<String> people,
    int count,
    int capacity,
  ) {
    final rooms = [for (var i = 1; i <= count; i++) BreakoutDraft('Sala $i')];
    final left = <String>[];
    for (var i = 0; i < people.length; i++) {
      final room = rooms[i % count];
      if (room.members.length < capacity) {
        room.members.add(people[i]);
      } else {
        left.add(people[i]);
      }
    }
    return (rooms, left);
  }
}
