import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';

class Reunion {
  final String id;
  final String nodoId;
  final String titulo;
  final String? descripcion;
  final DateTime fechaInicio;
  final DateTime? fechaFin;
  final String? enlaceReunion;
  final String creadoPor;
  final String creadorNombre;
  final DateTime createdAt;
  final String rtcEstado;

  /// Serie de reuniones repetidas a la que pertenece, si la hay.
  final String? serieId;

  /// `daily`, `weekdays`, `weekly`, `biweekly` o `monthly`.
  final String? repeticion;

  /// Creada con «Reunirse ahora» en lugar de programarse.
  final bool espontanea;

  /// Solo la ven quien la creó y sus invitados (llamada directa).
  final bool privada;

  /// `pendiente`, `aceptada`, `tentativa` o `rechazada`; null si no hay invitación.
  final String? miRespuesta;
  final int invitados, aceptados;

  /// Evento de todo el día (de medianoche a medianoche, hora local).
  final bool todoElDia;

  /// Sala, dirección o lugar (opcional).
  final String? ubicacion;

  /// Personas invitadas, sin quien organiza.
  final List<String> asistentes;

  const Reunion({
    required this.id,
    required this.nodoId,
    required this.titulo,
    this.descripcion,
    required this.fechaInicio,
    this.fechaFin,
    this.enlaceReunion,
    required this.creadoPor,
    required this.creadorNombre,
    required this.createdAt,
    this.rtcEstado = 'scheduled',
    this.serieId,
    this.repeticion,
    this.espontanea = false,
    this.privada = false,
    this.miRespuesta,
    this.invitados = 0,
    this.aceptados = 0,
    this.todoElDia = false,
    this.ubicacion,
    this.asistentes = const [],
  });

  bool get repite => repeticion != null && repeticion != 'none';

  Reunion copyWith({String? miRespuesta, String? rtcEstado}) => Reunion(
    id: id,
    nodoId: nodoId,
    titulo: titulo,
    descripcion: descripcion,
    fechaInicio: fechaInicio,
    fechaFin: fechaFin,
    enlaceReunion: enlaceReunion,
    creadoPor: creadoPor,
    creadorNombre: creadorNombre,
    createdAt: createdAt,
    rtcEstado: rtcEstado ?? this.rtcEstado,
    serieId: serieId,
    repeticion: repeticion,
    espontanea: espontanea,
    privada: privada,
    miRespuesta: miRespuesta ?? this.miRespuesta,
    invitados: invitados,
    aceptados: aceptados,
    todoElDia: todoElDia,
    ubicacion: ubicacion,
    asistentes: asistentes,
  );

  factory Reunion.fromJson(Map<String, dynamic> json) {
    return Reunion(
      id: json['id'] as String? ?? '',
      nodoId: json['nodo_id'] as String? ?? '',
      titulo: json['titulo'] as String? ?? '',
      descripcion: json['descripcion'] as String?,
      fechaInicio: json['fecha_inicio'] != null
          ? DateTime.tryParse(json['fecha_inicio'].toString()) ?? DateTime.now()
          : DateTime.now(),
      fechaFin: json['fecha_fin'] != null
          ? DateTime.tryParse(json['fecha_fin'].toString())
          : null,
      enlaceReunion: json['enlace_reunion'] as String?,
      creadoPor: json['creado_por'] as String? ?? '',
      creadorNombre: json['creador_nombre'] as String? ?? 'Usuario',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
      rtcEstado: json['rtc_estado'] as String? ?? 'scheduled',
      serieId: json['serie_id'] as String?,
      repeticion: json['repeticion'] as String?,
      espontanea: json['espontanea'] == true,
      privada: json['privada'] == true,
      miRespuesta: json['mi_respuesta'] as String?,
      invitados: (json['invitados'] as num?)?.toInt() ?? 0,
      aceptados: (json['aceptados'] as num?)?.toInt() ?? 0,
      todoElDia: json['todo_el_dia'] == true,
      ubicacion: json['ubicacion'] as String?,
      asistentes: [
        for (final id in (json['asistentes'] as List?) ?? const []) '$id',
      ],
    );
  }
}

/// Intervalo ocupado de una persona (sin datos de la reunión).
class BusyInterval {
  const BusyInterval(this.start, this.end);
  final DateTime start, end;

  bool overlaps(DateTime from, DateTime to) =>
      start.isBefore(to) && end.isAfter(from);
}

/// Alcance de una edición en una serie.
enum EditScope {
  una('Solo esta'),
  siguientes('Esta y las siguientes'),
  serie('Toda la serie');

  const EditScope(this.label);
  final String label;
}

class ReunionesRepository {
  ReunionesRepository({Dio? client}) : _client = client ?? ApiClient.instance;
  final Dio _client;

  Future<List<Reunion>> fetchReuniones(String nodoId) async {
    try {
      final response = await _client.get('/nodos/$nodoId/reuniones');
      final data = response.data as Map<String, dynamic>;
      final list = (data['reuniones'] as List<dynamic>?) ?? [];
      return list
          .map((e) => Reunion.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] ?? 'Error al cargar reuniones';
      throw Exception(msg);
    }
  }

  String _message(DioException e, String fallback) {
    final data = e.response?.data;
    return data is Map && data['message'] is String
        ? data['message'] as String
        : fallback;
  }

  /// Programa una reunión de IronLink (sin enlace externo). Con [frecuencia]
  /// distinta de `none` crea [ocurrencias] reuniones en serie. Sin
  /// [invitados] se invita a todo el nodo. Devuelve la primera y cuántas
  /// se crearon.
  Future<(Reunion, int)> createReunion({
    required String nodoId,
    required String titulo,
    String? descripcion,
    required DateTime fechaInicio,
    DateTime? fechaFin,
    String frecuencia = 'none',
    int ocurrencias = 1,
    List<String>? invitados,
    bool todoElDia = false,
    String? ubicacion,
  }) async {
    try {
      final response = await _client.post(
        '/nodos/$nodoId/reuniones',
        data: {
          'titulo': titulo,
          if (descripcion != null && descripcion.isNotEmpty)
            'descripcion': descripcion,
          if (ubicacion != null && ubicacion.isNotEmpty) 'ubicacion': ubicacion,
          if (todoElDia) 'todo_el_dia': true,
          'fecha_inicio': fechaInicio.toUtc().toIso8601String(),
          if (fechaFin != null) 'fecha_fin': fechaFin.toUtc().toIso8601String(),
          if (frecuencia != 'none')
            'repeticion': {
              'frecuencia': frecuencia,
              'ocurrencias': ocurrencias,
            },
          'invitados': ?invitados,
          'zona_minutos': fechaInicio.timeZoneOffset.inMinutes,
        },
      );
      final data = response.data as Map<String, dynamic>;
      if (data['reunion'] != null) {
        return (
          Reunion.fromJson(data['reunion'] as Map<String, dynamic>),
          (data['ocurrencias'] as num?)?.toInt() ?? 1,
        );
      }
      throw Exception(data['message'] ?? 'Error al programar reunión');
    } on DioException catch (e) {
      throw Exception(_message(e, 'Error al programar reunión'));
    }
  }

  /// Edita una reunión. En una serie, [alcance] decide si el cambio es solo
  /// para esta, para esta y las siguientes o para toda la serie (el cambio
  /// de hora se aplica como desplazamiento a las reuniones programadas).
  /// [invitados] es la lista completa (sin quien organiza); null no la cambia.
  /// Una [descripcion] o [ubicacion] vacía se borra.
  Future<Reunion> updateReunion({
    required String nodoId,
    required String reunionId,
    String? titulo,
    String? descripcion,
    String? ubicacion,
    DateTime? fechaInicio,
    DateTime? fechaFin,
    bool? todoElDia,
    List<String>? invitados,
    EditScope alcance = EditScope.una,
  }) async {
    try {
      final response = await _client.put(
        '/nodos/$nodoId/reuniones/$reunionId',
        data: {
          'titulo': ?titulo,
          'descripcion': ?descripcion,
          'ubicacion': ?ubicacion,
          if (fechaInicio != null)
            'fecha_inicio': fechaInicio.toUtc().toIso8601String(),
          if (fechaFin != null) 'fecha_fin': fechaFin.toUtc().toIso8601String(),
          'todo_el_dia': ?todoElDia,
          'invitados': ?invitados,
          'alcance': alcance.name,
          'zona_minutos':
              (fechaInicio ?? DateTime.now()).timeZoneOffset.inMinutes,
        },
      );
      final data = response.data as Map<String, dynamic>;
      if (data['reunion'] != null) {
        return Reunion.fromJson(data['reunion'] as Map<String, dynamic>);
      }
      throw Exception(data['message'] ?? 'No se pudo guardar la reunión.');
    } on DioException catch (e) {
      throw Exception(_message(e, 'No se pudo guardar la reunión.'));
    }
  }

  /// Intervalos ocupados de [usuarios] (integrantes del nodo) entre [desde]
  /// y [hasta], sin títulos. [excluir] es la reunión que se está editando.
  Future<Map<String, List<BusyInterval>>> fetchAvailability({
    required String nodoId,
    required DateTime desde,
    required DateTime hasta,
    required List<String> usuarios,
    String? excluir,
  }) async {
    try {
      final response = await _client.get(
        '/nodos/$nodoId/disponibilidad',
        queryParameters: {
          'desde': desde.toUtc().toIso8601String(),
          'hasta': hasta.toUtc().toIso8601String(),
          'usuarios': usuarios.join(','),
          'excluir': ?excluir,
        },
      );
      final data = response.data as Map<String, dynamic>;
      return {
        for (final row in (data['usuarios'] as List?) ?? const [])
          '${row['user_id']}': [
            for (final busy in (row['ocupado'] as List?) ?? const [])
              BusyInterval(
                DateTime.parse('${busy['inicio']}').toLocal(),
                DateTime.parse('${busy['fin']}').toLocal(),
              ),
          ],
      };
    } on DioException catch (e) {
      throw Exception(_message(e, 'No se pudo consultar la disponibilidad.'));
    }
  }

  /// «Reunirse ahora»: crea una reunión ya iniciada. Con [privada] solo la
  /// ven quien llama y sus [invitados] (llamada directa).
  Future<Reunion> meetNow({
    required String nodoId,
    String? titulo,
    List<String> invitados = const [],
    bool privada = false,
  }) async {
    try {
      final response = await _client.post(
        '/nodos/$nodoId/reuniones/ahora',
        data: {'titulo': ?titulo, 'invitados': invitados, 'privada': privada},
      );
      return Reunion.fromJson(
        (response.data as Map<String, dynamic>)['reunion']
            as Map<String, dynamic>,
      );
    } on DioException catch (e) {
      throw Exception(_message(e, 'No se pudo iniciar la reunión.'));
    }
  }

  /// Respuesta a una invitación: `aceptada`, `tentativa` o `rechazada`.
  Future<void> respond({
    required String nodoId,
    required String reunionId,
    required String respuesta,
    bool serie = false,
  }) async {
    try {
      await _client.put(
        '/nodos/$nodoId/reuniones/$reunionId/respuesta',
        data: {'respuesta': respuesta, 'serie': serie},
      );
    } on DioException catch (e) {
      throw Exception(_message(e, 'No se pudo registrar tu respuesta.'));
    }
  }

  /// Con [serie] también cancela las demás reuniones programadas de la serie.
  Future<void> deleteReunion({
    required String nodoId,
    required String reunionId,
    bool serie = false,
  }) async {
    try {
      await _client.delete(
        '/nodos/$nodoId/reuniones/$reunionId',
        queryParameters: {if (serie) 'serie': true},
      );
    } on DioException catch (e) {
      throw Exception(_message(e, 'Error al cancelar reunión'));
    }
  }

  Future<void> startMeeting({
    required String nodoId,
    required String reunionId,
  }) async {
    await _client.post('/nodos/$nodoId/reuniones/$reunionId/start');
  }

  Future<void> endMeeting({
    required String nodoId,
    required String reunionId,
  }) async {
    await _client.post('/nodos/$nodoId/reuniones/$reunionId/end');
  }

  /// Pase de un solo uso para la sala principal o, con [salaId], para una
  /// sala de trabajo asignada (IRL-RTC-US-07).
  Future<String> issueRtcTicket({
    required String nodoId,
    required String reunionId,
    String? salaId,
  }) async {
    final response = await _client.post(
      '/nodos/$nodoId/reuniones/$reunionId/rtc-ticket',
      queryParameters: {'sala_id': ?salaId},
    );
    return (response.data as Map<String, dynamic>)['ticket'] as String;
  }

  Future<void> moderate({
    required String nodoId,
    required String reunionId,
    required String action,
    String? target,
    bool? allowed,
  }) async {
    await _client.post(
      '/nodos/$nodoId/reuniones/$reunionId/moderation',
      data: {'action': action, 'target': ?target, 'allowed': ?allowed},
    );
  }
}

final reunionesRepositoryProvider = Provider<ReunionesRepository>((ref) {
  return ReunionesRepository();
});
