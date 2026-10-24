import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';

/// Relación con otra persona desde el punto de vista de quien consulta.
enum Friendship {
  none,
  sent,
  received,
  friends;

  static Friendship parse(Object? raw) => switch (raw) {
    'enviada' => Friendship.sent,
    'recibida' => Friendship.received,
    'amigos' => Friendship.friends,
    _ => Friendship.none,
  };
}

/// Quién puede enviarte solicitudes de amistad (`/amigos/privacidad`).
enum RequestPrivacy {
  everyone('todos', 'Todos', 'Cualquier persona con una cuenta activa.'),
  sharedNodes(
    'nodos',
    'Quienes comparten un nodo contigo',
    'Solo integrantes de alguno de tus nodos.',
  ),
  nobody('nadie', 'Nadie', 'Nadie puede enviarte solicitudes nuevas.');

  const RequestPrivacy(this.wire, this.label, this.description);
  final String wire, label, description;

  static RequestPrivacy parse(Object? raw) =>
      values.where((v) => v.wire == raw).firstOrNull ?? everyone;
}

/// Resultado de `GET /usuarios/buscar`. Nunca incluye correo ni teléfono.
class PersonResult {
  const PersonResult({
    required this.id,
    required this.name,
    required this.friendship,
    this.avatarUrl,
    this.avatarColor,
    this.requestId,
    this.sharesNode = false,
    this.blocked = false,
  });
  final String id, name;
  final String? avatarUrl, avatarColor, requestId;
  final Friendship friendship;
  final bool sharesNode;

  /// La tienes bloqueada: solo admite desbloquear.
  final bool blocked;

  factory PersonResult.fromJson(Map<String, dynamic> json) => PersonResult(
    id: json['id'] as String,
    name: json['nombre'] as String? ?? '',
    avatarUrl: json['avatar_url'] as String?,
    avatarColor: json['avatar_color'] as String?,
    friendship: Friendship.parse(json['amistad']),
    requestId: json['solicitud_id'] as String?,
    sharesNode: json['comparte_nodo'] == true,
    blocked: json['bloqueado'] == true,
  );

  PersonResult copyWith({
    Friendship? friendship,
    String? requestId,
    bool? blocked,
  }) => PersonResult(
    id: id,
    name: name,
    avatarUrl: avatarUrl,
    avatarColor: avatarColor,
    friendship: friendship ?? this.friendship,
    requestId: requestId ?? this.requestId,
    sharesNode: sharesNode,
    blocked: blocked ?? this.blocked,
  );
}

/// Persona bloqueada (`GET /bloqueados`).
class BlockedUser {
  const BlockedUser({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.avatarColor,
  });
  final String id, name;
  final String? avatarUrl, avatarColor;

  factory BlockedUser.fromJson(Map<String, dynamic> json) => BlockedUser(
    id: json['id'] as String,
    name: json['nombre'] as String? ?? '',
    avatarUrl: json['avatar_url'] as String?,
    avatarColor: json['avatar_color'] as String?,
  );
}

class SharedNode {
  const SharedNode(this.id, this.name);
  final String id, name;
}

class Friend {
  const Friend({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.avatarColor,
    this.statusText,
    this.sharedNodes = const [],
  });
  final String id, name;
  final String? avatarUrl, avatarColor, statusText;

  /// Nodos activos en común (informativo: el chat de amistad no los necesita).
  final List<SharedNode> sharedNodes;

  factory Friend.fromJson(Map<String, dynamic> json) => Friend(
    id: json['id'] as String,
    name: json['nombre'] as String? ?? '',
    avatarUrl: json['avatar_url'] as String?,
    avatarColor: json['avatar_color'] as String?,
    statusText: json['status_text'] as String?,
    sharedNodes: [
      for (final raw in (json['nodos_comunes'] as List? ?? const []))
        SharedNode(
          (raw as Map)['id'] as String,
          raw['nombre'] as String? ?? '',
        ),
    ],
  );
}

class FriendRequest {
  const FriendRequest({
    required this.id,
    required this.userId,
    required this.name,
    required this.createdAt,
    required this.outgoing,
    this.avatarUrl,
    this.avatarColor,
    this.sharesNode = false,
  });
  final String id, userId, name;
  final String? avatarUrl, avatarColor;
  final DateTime createdAt;
  final bool outgoing, sharesNode;

  factory FriendRequest.fromJson(
    Map<String, dynamic> json, {
    required bool outgoing,
  }) => FriendRequest(
    id: json['id'] as String,
    userId: json['user_id'] as String,
    name: json['nombre'] as String? ?? '',
    avatarUrl: json['avatar_url'] as String?,
    avatarColor: json['avatar_color'] as String?,
    sharesNode: json['comparte_nodo'] == true,
    createdAt: DateTime.parse(json['created_at'] as String),
    outgoing: outgoing,
  );
}

class FriendRequests {
  const FriendRequests({this.received = const [], this.sent = const []});
  final List<FriendRequest> received, sent;
  bool get isEmpty => received.isEmpty && sent.isEmpty;
}

/// Error de la API con el mensaje en español que envía el servidor.
class FriendsException implements Exception {
  const FriendsException(this.message);
  final String message;
  @override
  String toString() => message;
}

class FriendsRepository {
  FriendsRepository({Dio? client}) : _client = client ?? ApiClient.instance;
  final Dio _client;

  /// Mínimo de caracteres que el servidor acepta en una búsqueda.
  static const minQuery = 2;

  /// Con «@» el servidor busca solo el correo completo y exacto.
  static bool isEmailQuery(String query) => query.contains('@');

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on DioException catch (error) {
      final data = error.response?.data;
      final message = data is Map && data['message'] is String
          ? data['message'] as String
          : 'No se pudo conectar con el servidor. Inténtalo de nuevo.';
      throw FriendsException(message);
    }
  }

  Future<List<PersonResult>> search(String query) => _guard(() async {
    final response = await _client.get(
      '/usuarios/buscar',
      queryParameters: {'q': query.trim()},
    );
    final list = (response.data as Map)['usuarios'] as List? ?? const [];
    return [
      for (final raw in list)
        PersonResult.fromJson(Map<String, dynamic>.from(raw as Map)),
    ];
  });

  Future<List<Friend>> friends() => _guard(() async {
    final response = await _client.get('/amigos');
    final list = (response.data as Map)['amigos'] as List? ?? const [];
    return [
      for (final raw in list)
        Friend.fromJson(Map<String, dynamic>.from(raw as Map)),
    ];
  });

  Future<FriendRequests> requests() => _guard(() async {
    final response = await _client.get('/amigos/solicitudes');
    final data = response.data as Map;
    List<FriendRequest> parse(Object? raw, bool outgoing) => [
      for (final item in (raw as List? ?? const []))
        FriendRequest.fromJson(
          Map<String, dynamic>.from(item as Map),
          outgoing: outgoing,
        ),
    ];
    return FriendRequests(
      received: parse(data['recibidas'], false),
      sent: parse(data['enviadas'], true),
    );
  });

  /// Envía una solicitud. Si la otra persona ya había enviado una, el
  /// servidor la acepta y devuelve [Friendship.friends].
  Future<({Friendship status, String? requestId})> send(String userId) =>
      _guard(() async {
        final response = await _client.post(
          '/amigos/solicitudes',
          data: {'user_id': userId},
        );
        final data = response.data as Map;
        return (
          status: data['estado'] == 'aceptada'
              ? Friendship.friends
              : Friendship.sent,
          requestId: data['solicitud_id'] as String?,
        );
      });

  Future<void> accept(String requestId) =>
      _guard(() => _client.post('/amigos/solicitudes/$requestId/aceptar'));

  Future<void> reject(String requestId) =>
      _guard(() => _client.post('/amigos/solicitudes/$requestId/rechazar'));

  Future<void> cancel(String requestId) =>
      _guard(() => _client.delete('/amigos/solicitudes/$requestId'));

  Future<void> remove(String userId) =>
      _guard(() => _client.delete('/amigos/$userId'));

  Future<List<BlockedUser>> blocked() => _guard(() async {
    final response = await _client.get('/bloqueados');
    final list = (response.data as Map)['bloqueados'] as List? ?? const [];
    return [
      for (final raw in list)
        BlockedUser.fromJson(Map<String, dynamic>.from(raw as Map)),
    ];
  });

  /// Bloquear también elimina la amistad y las solicitudes entre ambos.
  Future<void> block(String userId) =>
      _guard(() => _client.put('/bloqueados/$userId'));

  Future<void> unblock(String userId) =>
      _guard(() => _client.delete('/bloqueados/$userId'));

  Future<RequestPrivacy> privacy() => _guard(() async {
    final response = await _client.get('/amigos/privacidad');
    return RequestPrivacy.parse((response.data as Map)['solicitudes_de']);
  });

  Future<RequestPrivacy> setPrivacy(RequestPrivacy value) => _guard(() async {
    final response = await _client.put(
      '/amigos/privacidad',
      data: {'solicitudes_de': value.wire},
    );
    return RequestPrivacy.parse((response.data as Map)['solicitudes_de']);
  });
}
