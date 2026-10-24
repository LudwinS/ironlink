import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Modelo de datos: Nodo
// ─────────────────────────────────────────────────────────────────────────────

class Nodo {
  final String id;
  final String nombre;
  final String? descripcion;
  final String tokenAcceso;
  final String creadorId;
  final String estado; // 'active' o 'inactive'
  final int miembrosCount;
  final String? creadorNombre;
  final DateTime createdAt;
  final String? rol;

  const Nodo({
    required this.id,
    required this.nombre,
    this.descripcion,
    required this.tokenAcceso,
    required this.creadorId,
    required this.estado,
    required this.miembrosCount,
    this.creadorNombre,
    required this.createdAt,
    this.rol,
  });

  factory Nodo.fromJson(Map<String, dynamic> json) {
    return Nodo(
      id: json['id'] as String,
      nombre: json['nombre'] as String,
      descripcion: json['descripcion'] as String?,
      tokenAcceso: json['token_acceso'] as String? ?? '',
      creadorId: json['creador_id'] as String? ?? '',
      estado: json['estado'] as String? ?? 'active',
      miembrosCount: (json['miembros_count'] as num?)?.toInt() ?? 0,
      creadorNombre: json['creador_nombre'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
      rol: json['rol'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'nombre': nombre,
        'descripcion': descripcion,
        'token_acceso': tokenAcceso,
        'creador_id': creadorId,
        'estado': estado,
        'miembros_count': miembrosCount,
        'creador_nombre': creadorNombre,
        'created_at': createdAt.toIso8601String(),
        'rol': rol,
      };

  bool get isActive => estado == 'active';
}

// ─────────────────────────────────────────────────────────────────────────────
// Repositorio de Nodos
// ─────────────────────────────────────────────────────────────────────────────

class NodosRepository {
  final Dio _client = ApiClient.instance;

  /// Obtiene la lista de nodos del usuario autenticado.
  /// GET /nodos
  Future<List<Nodo>> fetchNodos() async {
    try {
      final response = await _client.get('/nodos');
      final data = response.data;

      if (data is List) {
        return data
            .map((e) => Nodo.fromJson(e as Map<String, dynamic>))
            .toList();
      }

      if (data is Map<String, dynamic> && data['nodos'] is List) {
        return (data['nodos'] as List)
            .map((e) => Nodo.fromJson(e as Map<String, dynamic>))
            .toList();
      }

      return [];
    } on DioException catch (e) {
      final msg = _extractErrorMessage(e, 'Error al obtener los nodos');
      throw Exception(msg);
    }
  }

  /// Crea un nuevo nodo.
  /// POST /nodos
  Future<Nodo> createNodo({
    required String nombre,
    String? descripcion,
  }) async {
    try {
      final response = await _client.post(
        '/nodos',
        data: {
          'nombre': nombre,
          if (descripcion != null && descripcion.isNotEmpty)
            'descripcion': descripcion,
        },
      );

      final data = response.data;
      if (data is Map<String, dynamic>) {
        // El backend puede devolver el nodo directamente o dentro de una clave
        if (data.containsKey('id')) {
          return Nodo.fromJson(data);
        }
        if (data['nodo'] is Map<String, dynamic>) {
          return Nodo.fromJson(data['nodo'] as Map<String, dynamic>);
        }
      }

      throw Exception('Respuesta inesperada del servidor al crear nodo');
    } on DioException catch (e) {
      final msg = _extractErrorMessage(e, 'Error al crear el nodo');
      throw Exception(msg);
    }
  }

  /// Se une a un nodo existente mediante token de acceso.
  /// POST /nodos/join/:token
  Future<Nodo> joinNodo(String token) async {
    try {
      final sanitizedToken = token.trim();
      final response = await _client.post('/nodos/join/$sanitizedToken');

      final data = response.data;
      if (data is Map<String, dynamic>) {
        if (data.containsKey('id')) {
          return Nodo.fromJson(data);
        }
        if (data['nodo'] is Map<String, dynamic>) {
          return Nodo.fromJson(data['nodo'] as Map<String, dynamic>);
        }
      }

      throw Exception('Respuesta inesperada del servidor al unirse al nodo');
    } on DioException catch (e) {
      final msg = _extractErrorMessage(e, 'Error al unirse al nodo');
      throw Exception(msg);
    }
  }

  /// Elimina un nodo por su ID.
  /// DELETE /nodos/:id
  Future<void> deleteNodo(String id) async {
    try {
      await _client.delete('/nodos/$id');
    } on DioException catch (e) {
      final msg = _extractErrorMessage(e, 'Error al eliminar el nodo');
      throw Exception(msg);
    }
  }

  /// Obtiene la lista de miembros de un nodo.
  /// GET /nodos/:id/miembros
  Future<List<NodoMiembro>> fetchMiembros(String nodoId) async {
    try {
      final response = await _client.get('/nodos/$nodoId/miembros');
      final data = response.data;
      if (data is Map<String, dynamic> && data['miembros'] is List) {
        return (data['miembros'] as List)
            .map((e) => NodoMiembro.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } on DioException catch (e) {
      final msg = _extractErrorMessage(e, 'Error al obtener los miembros');
      throw Exception(msg);
    }
  }

  /// Actualiza el rol de un miembro en el nodo.
  /// PUT /nodos/:id/miembros/:user_id/rol
  Future<void> updateMiembroRol({
    required String nodoId,
    required String userId,
    required String newRol,
  }) async {
    try {
      await _client.put(
        '/nodos/$nodoId/miembros/$userId/rol',
        data: {'rol': newRol},
      );
    } on DioException catch (e) {
      final msg = _extractErrorMessage(e, 'Error al actualizar el rol');
      throw Exception(msg);
    }
  }

  /// Sale de un nodo.
  /// POST /nodos/:id/leave
  Future<void> leaveNodo(String id) async {
    try {
      await _client.post('/nodos/$id/leave');
    } on DioException catch (e) {
      final msg = _extractErrorMessage(e, 'Error al salir del nodo');
      throw Exception(msg);
    }
  }

  /// Expulsa a un usuario de un nodo.
  /// DELETE /nodos/:id/miembros/:user_id
  Future<void> kickMiembro(String nodoId, String userId) async {
    try {
      await _client.delete('/nodos/$nodoId/miembros/$userId');
    } on DioException catch (e) {
      final msg = _extractErrorMessage(e, 'Error al expulsar al miembro');
      throw Exception(msg);
    }
  }

  /// Banea a un usuario de un nodo.
  /// POST /nodos/:id/miembros/:user_id/ban
  Future<void> banMiembro(String nodoId, String userId) async {
    try {
      await _client.post('/nodos/$nodoId/miembros/$userId/ban');
    } on DioException catch (e) {
      final msg = _extractErrorMessage(e, 'Error al banear al usuario');
      throw Exception(msg);
    }
  }

  /// Quita el baneo a un usuario.
  /// DELETE /nodos/:id/baneos/:user_id
  Future<void> unbanMiembro(String nodoId, String userId) async {
    try {
      await _client.delete('/nodos/$nodoId/baneos/$userId');
    } on DioException catch (e) {
      final msg = _extractErrorMessage(e, 'Error al remover el baneo');
      throw Exception(msg);
    }
  }

  /// Obtiene la lista de usuarios baneados de un nodo.
  /// GET /nodos/:id/baneos
  Future<List<NodoBaneo>> fetchBaneados(String nodoId) async {
    try {
      final response = await _client.get('/nodos/$nodoId/baneos');
      final data = response.data;
      if (data is Map<String, dynamic> && data['baneos'] is List) {
        return (data['baneos'] as List)
            .map((e) => NodoBaneo.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } on DioException catch (e) {
      final msg = _extractErrorMessage(e, 'Error al obtener la lista de baneos');
      throw Exception(msg);
    }
  }

  /// Obtiene los últimos 100 mensajes de un nodo o subgrupo o, con
  /// [despuesDe], solo los posteriores a ese mensaje (`incremental`).
  /// GET /nodos/:id/mensajes(?subgrupo_id=...&despues_de=...)
  Future<MensajesPage> fetchMensajes(
    String nodoId, {
    String? subgrupoId,
    String? despuesDe,
  }) async {
    try {
      final response = await _client.get(
        '/nodos/$nodoId/mensajes',
        queryParameters: {'subgrupo_id': ?subgrupoId, 'despues_de': ?despuesDe},
      );
      final data = response.data;
      if (data is Map<String, dynamic> && data['mensajes'] is List) {
        return MensajesPage(
          (data['mensajes'] as List)
              .map((e) => Mensaje.fromJson(e as Map<String, dynamic>))
              .toList(),
          incremental: data['incremental'] == true,
        );
      }
      return const MensajesPage([]);
    } on DioException catch (e) {
      final msg = _extractErrorMessage(e, 'Error al obtener los mensajes');
      throw Exception(msg);
    }
  }

  /// Envía un mensaje a un nodo o subgrupo.
  /// POST /nodos/:id/mensajes
  Future<Mensaje> sendMensaje(String nodoId, String contenido, {String? subgrupoId}) async {
    try {
      final body = <String, dynamic>{'contenido': contenido};
      if (subgrupoId != null) body['subgrupo_id'] = subgrupoId;
      final response = await _client.post(
        '/nodos/$nodoId/mensajes',
        data: body,
      );
      final data = response.data;
      if (data is Map<String, dynamic> && data['mensaje'] is Map<String, dynamic>) {
        return Mensaje.fromJson(data['mensaje'] as Map<String, dynamic>);
      }
      throw Exception('Respuesta inesperada del servidor al enviar mensaje');
    } on DioException catch (e) {
      final msg = _extractErrorMessage(e, 'Error al enviar el mensaje');
      throw Exception(msg);
    }
  }

  /// Obtiene el conteo de mensajes no leídos para un nodo (IRL-WKS-US-03)
  /// GET /nodos/:id/unread-count
  Future<int> getUnreadCount(String nodoId) async {
    try {
      final response = await _client.get('/nodos/$nodoId/unread-count');
      final data = response.data;
      if (data is Map<String, dynamic>) {
        return (data['unread_count'] as num?)?.toInt() ?? 0;
      }
      return 0;
    } on DioException catch (e) {
      // Antes devolvía 0 ante cualquier error y el badge desaparecía con una
      // caída de red; quien llama conserva el último valor conocido.
      throw Exception(_extractErrorMessage(e, 'Error al contar los no leídos'));
    }
  }

  /// Extrae un mensaje legible de una respuesta de error Dio.
  String _extractErrorMessage(DioException e, String fallback) {
    final responseData = e.response?.data;
    if (responseData is Map<String, dynamic>) {
      return responseData['message']?.toString() ?? fallback;
    }
    if (responseData is String && responseData.isNotEmpty) {
      return responseData;
    }
    return fallback;
  }
}

class NodoMiembro {
  final String userId;
  final String name;
  final String email;
  final String rol;
  final String? avatarColor;
  final String? statusText;
  final String? avatarUrl;

  const NodoMiembro({
    required this.userId,
    required this.name,
    required this.email,
    required this.rol,
    this.avatarColor,
    this.statusText,
    this.avatarUrl,
  });

  factory NodoMiembro.fromJson(Map<String, dynamic> json) {
    return NodoMiembro(
      userId: json['user_id'] as String? ?? json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      rol: json['rol'] as String? ?? 'MEMBER',
      avatarColor: json['avatar_color'] as String?,
      statusText: json['status_text'] as String?,
      avatarUrl: json['avatar_url'] as String?,
    );
  }
}

class NodoBaneo {
  final String userId;
  final String name;
  final String email;
  final String? creadoPorNombre;
  final DateTime createdAt;

  const NodoBaneo({
    required this.userId,
    required this.name,
    required this.email,
    this.creadoPorNombre,
    required this.createdAt,
  });

  factory NodoBaneo.fromJson(Map<String, dynamic> json) {
    return NodoBaneo(
      userId: json['user_id'] as String? ?? json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      creadoPorNombre: json['creado_por_nombre'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

/// Respuesta de `GET /mensajes`: lista completa o solo lo nuevo.
class MensajesPage {
  const MensajesPage(this.mensajes, {this.incremental = false});
  final List<Mensaje> mensajes;
  final bool incremental;
}

class Mensaje {
  final String id;
  final String nodoId;
  final String userId;
  final String userName;
  final String contenido;
  final DateTime createdAt;
  final String? subgrupoId;
  final String? avatarUrl;
  final String? avatarColor;
  final String? statusText;

  const Mensaje({
    required this.id,
    required this.nodoId,
    required this.userId,
    required this.userName,
    required this.contenido,
    required this.createdAt,
    this.subgrupoId,
    this.avatarUrl,
    this.avatarColor,
    this.statusText,
  });

  factory Mensaje.fromJson(Map<String, dynamic> json) {
    return Mensaje(
      id: json['id'] as String? ?? '',
      nodoId: json['nodo_id'] as String? ?? '',
      userId: json['user_id'] as String? ?? '',
      userName: json['user_name'] as String? ?? 'Usuario',
      contenido: json['contenido'] as String? ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
      subgrupoId: json['subgrupo_id'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      avatarColor: json['avatar_color'] as String?,
      statusText: json['status_text'] as String?,
    );
  }
}
