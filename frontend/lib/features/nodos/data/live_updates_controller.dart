import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../../core/network/api_client.dart';
import '../../../core/presence/live_presence.dart';
import 'reuniones_repository.dart';

class LiveMeeting {
  const LiveMeeting({
    required this.id,
    required this.nodeId,
    required this.title,
    required this.creatorId,
    required this.creatorName,
    required this.startedAt,
  });
  final String id, nodeId, title, creatorId, creatorName;
  final DateTime startedAt;
  Reunion toReunion() => Reunion(
    id: id,
    nodoId: nodeId,
    titulo: title,
    fechaInicio: startedAt,
    creadoPor: creatorId,
    creadorNombre: creatorName,
    createdAt: startedAt,
    rtcEstado: 'active',
  );
  static LiveMeeting parse(Map<String, dynamic> data) => LiveMeeting(
    id: data['id'] as String,
    nodeId: data['node_id'] as String,
    title: data['title'] as String,
    creatorId: data['creator_id'] as String,
    creatorName: data['creator_name'] as String,
    startedAt: DateTime.parse(data['started_at'] as String),
  );
}

class LiveUpdatesController extends ChangeNotifier {
  LiveUpdatesController({
    Future<String> Function()? ticket,
    WebSocketChannel Function(Uri)? connect,
  }) : _ticket = ticket ?? _issueTicket,
       _connect = connect ?? WebSocketChannel.connect;
  final Future<String> Function() _ticket;
  final WebSocketChannel Function(Uri) _connect;
  static Future<String> _issueTicket() async {
    final response = await ApiClient.instance.post('/live/ticket');
    return (response.data as Map<String, dynamic>)['ticket'] as String;
  }

  List<LiveMeeting> meetings = [];
  final Set<String> _dismissed = {};
  List<LiveMeeting> get pending =>
      meetings.where((m) => !_dismissed.contains(m.id)).toList();
  bool connected = false,
      truncated = false,
      _closed = false,
      _connecting = false;
  String? userId;

  /// IRL-NTF-US-03: no leídas de las últimas 24 h, según el servidor.
  int unreadNotifications = 0;
  String? _latestNotification;

  /// Solicitudes de amistad pendientes recibidas (0 en servidores anteriores).
  int pendingFriendRequests = 0;

  /// Mensajes de amistad sin leer (0 en servidores anteriores).
  int unreadFriendMessages = 0;

  /// Amistades aceptadas y solicitudes enviadas pendientes: cambian cuando
  /// la otra persona acepta o rechaza (0 en servidores anteriores).
  int acceptedFriends = 0;
  int sentFriendRequests = 0;
  bool _notificationsKnown = false;
  final _arrivals = StreamController<void>.broadcast();

  /// Emite cuando llega una notificación nueva (no en la primera instantánea,
  /// para no anunciar avisos que ya existían al abrir la app).
  Stream<void> get notificationArrivals => _arrivals.stream;
  Timer? _retry;
  Timer? _watchdog;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  int _attempt = 0, _epoch = 0;

  bool applySnapshot(dynamic data) {
    if (_closed || data is! Map || data['type'] != 'live_snapshot') {
      return false;
    }
    try {
      final id = data['user_id'] as String;
      if (id.isEmpty || (userId != null && userId != id)) return false;
      final rawPresence = data['presence'] as Map;
      final rawMeetings = data['meetings'] as List;
      if (rawPresence.length > 501 || rawMeetings.length > 50) return false;
      final states = <String, String>{};
      for (final entry in rawPresence.entries) {
        if (entry.key is! String ||
            !{
              'in_call',
              'available',
              'busy',
              'offline',
            }.contains(entry.value)) {
          return false;
        }
        states[entry.key as String] = entry.value as String;
      }
      final next = rawMeetings
          .map((m) => LiveMeeting.parse(Map<String, dynamic>.from(m as Map)))
          .toList();
      if (next.any(
            (m) => m.id.isEmpty || m.nodeId.isEmpty || m.title.isEmpty,
          ) ||
          next.map((m) => m.id).toSet().length != next.length ||
          !states.containsKey(id)) {
        return false;
      }
      userId = id;
      LivePresence.selfId = id;
      LivePresence.values.value = Map.unmodifiable(states);
      meetings = next;
      _dismissed.removeWhere((id) => !next.any((m) => m.id == id));
      _applyNotifications(data['notifications']);
      final friends = data['friends'];
      final pending = friends is Map ? friends['pending'] : null;
      pendingFriendRequests = pending is int && pending >= 0 ? pending : 0;
      final unread = friends is Map ? friends['unread_messages'] : null;
      unreadFriendMessages = unread is int && unread >= 0 ? unread : 0;
      final accepted = friends is Map ? friends['accepted'] : null;
      acceptedFriends = accepted is int && accepted >= 0 ? accepted : 0;
      final sent = friends is Map ? friends['sent'] : null;
      sentFriendRequests = sent is int && sent >= 0 ? sent : 0;
      connected = true;
      truncated = data['truncated'] == true;
      _attempt = 0;
      _received();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _applyNotifications(dynamic raw) {
    if (raw is! Map) return; // Servidores anteriores no envían el resumen.
    final unread = raw['unread'];
    final latest = raw['latest'];
    if (unread is! int || unread < 0 || (latest != null && latest is! String)) {
      return;
    }
    if (_notificationsKnown &&
        latest != null &&
        latest != _latestNotification &&
        !_arrivals.isClosed) {
      _arrivals.add(null);
    }
    unreadNotifications = unread;
    _latestNotification = latest as String?;
    _notificationsKnown = true;
  }

  void dismiss(String id) {
    if (_closed || !meetings.any((m) => m.id == id)) return;
    _dismissed.add(id);
    notifyListeners();
  }

  bool receive(dynamic data) {
    if (_closed) return false;
    if (data is Map && data['type'] == 'live_heartbeat') {
      if (!connected || data['user_id'] != userId) return false;
      _received();
      return true;
    }
    return applySnapshot(data);
  }

  void _received() {
    _watchdog?.cancel();
    final epoch = _epoch;
    _watchdog = Timer(const Duration(seconds: 20), () => _lost(epoch));
  }

  Future<void> start() async {
    if (_closed || _connecting || _channel != null) return;
    _retry?.cancel();
    _connecting = true;
    final epoch = ++_epoch;
    try {
      final ticket = await _ticket();
      if (_closed || epoch != _epoch) return;
      final api = Uri.parse(ApiClient.baseUrl);
      final channel = _connect(
        api.replace(
          scheme: api.scheme == 'https' ? 'wss' : 'ws',
          path: '/live/ws',
          queryParameters: {'ticket': ticket},
        ),
      );
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 10));
      if (_closed || epoch != _epoch) {
        await channel.sink.close();
        return;
      }
      _received();
      _subscription = channel.stream.listen(
        (raw) {
          if (_closed || epoch != _epoch) return;
          try {
            if (raw is! String || !receive(jsonDecode(raw))) _lost(epoch);
          } catch (_) {
            _lost(epoch);
          }
        },
        onError: (Object _) => _lost(epoch),
        onDone: () => _lost(epoch),
      );
    } catch (_) {
      _lost(epoch);
    } finally {
      _connecting = false;
    }
  }

  void _lost(int epoch) {
    if (_closed || epoch != _epoch) return;
    _epoch++;
    _watchdog?.cancel();
    connected = false;
    meetings = []; // Stale invitations must not remain actionable.
    LivePresence.values.value = {};
    final channel = _channel;
    _channel = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    if (channel != null) unawaited(channel.sink.close());
    _retry?.cancel();
    _retry = Timer(
      Duration(seconds: min(30, 1 << min(_attempt++, 5))),
      () => unawaited(start()),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _arrivals.close();
    _epoch++;
    _retry?.cancel();
    unawaited(_subscription?.cancel());
    _watchdog?.cancel();
    if (_channel != null) unawaited(_channel!.sink.close());
    LivePresence.clear();
    super.dispose();
  }
}
