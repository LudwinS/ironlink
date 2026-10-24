import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';
import 'reuniones_repository.dart';

class CalendarMeeting {
  const CalendarMeeting({
    required this.reunion,
    required this.nodeName,
    required this.canModerate,
    required this.canJoin,
  });
  final Reunion reunion;
  final String nodeName;
  final bool canModerate, canJoin;
  factory CalendarMeeting.fromJson(Map<String, dynamic> json) =>
      CalendarMeeting(
        reunion: Reunion.fromJson(json),
        nodeName: json['nodo_nombre'] as String,
        canModerate: json['can_moderate'] == true,
        canJoin: json['can_join'] == true,
      );
}

class CalendarResult {
  const CalendarResult(this.meetings, {this.truncated = false});
  final List<CalendarMeeting> meetings;
  final bool truncated;
}

class CalendarRepository {
  CalendarRepository({Dio? client}) : _client = client ?? ApiClient.instance;
  final Dio _client;
  // Local midnight boundaries preserve the user's month across UTC offsets.
  Future<CalendarResult> fetchMonth(DateTime month, {String? nodeId}) async {
    final from = DateTime(month.year, month.month);
    final to = DateTime(month.year, month.month + 1);
    final response = await _client.get(
      '/calendar/meetings',
      queryParameters: {
        'from': from.toUtc().toIso8601String(),
        'to': to.toUtc().toIso8601String(),
        'node_id': ?nodeId,
      },
    );
    final data = response.data as Map<String, dynamic>;
    return CalendarResult(
      (data['reuniones'] as List)
          .map(
            (row) =>
                CalendarMeeting.fromJson(Map<String, dynamic>.from(row as Map)),
          )
          .toList(),
      truncated: data['truncated'] == true,
    );
  }
}
