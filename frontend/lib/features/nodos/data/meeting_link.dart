import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../../core/network/api_client.dart';
import 'calendar_repository.dart';

/// Enlace directo a una reunión (IRL-WKS-US-06).
///
/// Solo contiene el ID de la reunión: abrirlo exige sesión y el servidor
/// vuelve a comprobar membresía, baneo y estado al resolverlo y al entrar a
/// la llamada. Nunca incluye tokens de acceso.
class MeetingLink {
  MeetingLink._();

  /// URL del cliente web. Se puede fijar con `--dart-define=APP_WEB_URL=...`;
  /// si no, en web se usa el propio origen y en escritorio el host del API con
  /// el puerto 3000 que sirve `start_web_release.sh`.
  static String get webBase {
    const configured = String.fromEnvironment('APP_WEB_URL');
    if (configured.isNotEmpty) return _trim(configured);
    if (kIsWeb) return _trim(Uri.base.origin + Uri.base.path);
    final api = Uri.parse(ApiClient.baseUrl);
    return _trim(api.replace(port: 3000, path: '').toString());
  }

  static String _trim(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  static final _pattern = RegExp(
    r'/reunion/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?![0-9a-f-])',
    caseSensitive: false,
  );

  static String forMeeting(String reunionId) => '$webBase/#/reunion/$reunionId';

  /// ID de la primera reunión enlazada en un texto, o null.
  static String? find(String text) =>
      _pattern.firstMatch(text)?.group(1)?.toLowerCase();

  /// Mensaje que se publica al compartir en el canal del nodo.
  static String announcement(CalendarMeeting meeting) {
    final start = meeting.reunion.fechaInicio.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Reunión «${meeting.reunion.titulo}» · '
        '${start.day}/${start.month}/${start.year} ${two(start.hour)}:${two(start.minute)}\n'
        '${forMeeting(meeting.reunion.id)}';
  }
}

/// Resultado de abrir un enlace de reunión.
sealed class MeetingLookup {
  const MeetingLookup();
}

class MeetingFound extends MeetingLookup {
  const MeetingFound(this.meeting);
  final CalendarMeeting meeting;
}

/// La reunión no existe o el usuario no tiene acceso: el servidor no distingue
/// ambos casos para no revelar si existe.
class MeetingUnavailable extends MeetingLookup {
  const MeetingUnavailable(this.message);
  final String message;
}

class MeetingLinkRepository {
  MeetingLinkRepository({Dio? client}) : _client = client ?? ApiClient.instance;
  final Dio _client;

  Future<MeetingLookup> resolve(String reunionId) async {
    try {
      final response = await _client.get('/reuniones/$reunionId');
      final data = response.data as Map<String, dynamic>;
      return MeetingFound(
        CalendarMeeting.fromJson(
          Map<String, dynamic>.from(data['reunion'] as Map),
        ),
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final message = (e.response?.data is Map)
          ? (e.response!.data as Map)['message'] as String?
          : null;
      if (status == 404 || status == 403) {
        return MeetingUnavailable(
          message ?? 'La reunión no existe o no tienes acceso a ella.',
        );
      }
      return const MeetingUnavailable(
        'No se pudo abrir la reunión. Revisa tu conexión e inténtalo de nuevo.',
      );
    }
  }
}
