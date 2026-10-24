import '../../../core/network/api_client.dart';

class DirectMessage {
  const DirectMessage({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.content,
    required this.kind,
    required this.createdAt,
    this.reunionId,
    this.readAt,
  });

  final String id;
  final String senderId;
  final String recipientId;
  final String content;
  final String kind;
  final String? reunionId;
  final DateTime createdAt;
  final DateTime? readAt;

  factory DirectMessage.fromJson(Map<String, dynamic> json) => DirectMessage(
    id: json['id'] as String,
    senderId: json['sender_id'] as String,
    recipientId: json['recipient_id'] as String,
    content: json['content'] as String,
    kind: json['kind'] as String,
    reunionId: json['reunion_id'] as String?,
    createdAt: DateTime.parse(json['created_at'] as String),
    readAt: json['read_at'] == null
        ? null
        : DateTime.tryParse(json['read_at'] as String),
  );
}

class DirectMessagesRepository {
  Future<List<DirectMessage>> inbox(String nodoId) async {
    final response = await ApiClient.instance.get(
      '/nodos/$nodoId/direct-messages',
    );
    final data = response.data as Map<String, dynamic>;
    return (data['messages'] as List<dynamic>)
        .map((e) => DirectMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<DirectMessage>> history(String nodoId, String peerId) async {
    final response = await ApiClient.instance.get(
      '/nodos/$nodoId/direct-messages/$peerId',
    );
    final data = response.data as Map<String, dynamic>;
    return (data['messages'] as List<dynamic>)
        .map((e) => DirectMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<DirectMessage> sendText(
    String nodoId,
    String peerId,
    String text,
  ) async {
    final response = await ApiClient.instance.post(
      '/nodos/$nodoId/direct-messages/$peerId',
      data: {'content': text},
    );
    return DirectMessage.fromJson(
      (response.data as Map<String, dynamic>)['message']
          as Map<String, dynamic>,
    );
  }

  Future<DirectMessage> invite(
    String nodoId,
    String peerId,
    String reunionId,
  ) async {
    final response = await ApiClient.instance.post(
      '/nodos/$nodoId/direct-messages/$peerId',
      data: {'reunion_id': reunionId},
    );
    return DirectMessage.fromJson(
      (response.data as Map<String, dynamic>)['message']
          as Map<String, dynamic>,
    );
  }

  // Chat de amistad: no depende de compartir un nodo.

  /// Bandeja de chats de amistad: último mensaje y no leídos por amigo.
  Future<List<FriendConversation>> friendConversations() async {
    final response = await ApiClient.instance.get('/amigos/conversaciones');
    final data = response.data as Map<String, dynamic>;
    return [
      for (final raw in (data['conversaciones'] as List<dynamic>? ?? const []))
        FriendConversation.fromJson(Map<String, dynamic>.from(raw as Map)),
    ];
  }

  /// Conversación con un amigo (vacía si aún no se escribieron). Marca como
  /// leído hasta el último mensaje devuelto.
  Future<List<DirectMessage>> friendHistory(String peerId) async {
    final response = await ApiClient.instance.get('/amigos/$peerId/mensajes');
    final data = response.data as Map<String, dynamic>;
    return (data['messages'] as List<dynamic>)
        .map((e) => DirectMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<DirectMessage> friendSend(String peerId, String text) async {
    final response = await ApiClient.instance.post(
      '/amigos/$peerId/mensajes',
      data: {'content': text},
    );
    return DirectMessage.fromJson(
      (response.data as Map<String, dynamic>)['message']
          as Map<String, dynamic>,
    );
  }
}

/// Resumen de `GET /amigos/conversaciones`.
class FriendConversation {
  const FriendConversation({
    required this.userId,
    required this.name,
    required this.latest,
    this.avatarUrl,
    this.avatarColor,
    this.unread = 0,
  });
  final String userId, name;
  final String? avatarUrl, avatarColor;
  final DirectMessage latest;
  final int unread;

  factory FriendConversation.fromJson(Map<String, dynamic> json) =>
      FriendConversation(
        userId: json['user_id'] as String,
        name: json['nombre'] as String? ?? '',
        avatarUrl: json['avatar_url'] as String?,
        avatarColor: json['avatar_color'] as String?,
        unread: (json['no_leidos'] as num?)?.toInt() ?? 0,
        latest: DirectMessage.fromJson(
          Map<String, dynamic>.from(json['ultimo'] as Map),
        ),
      );
}
