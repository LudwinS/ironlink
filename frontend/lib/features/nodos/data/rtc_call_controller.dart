import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/network/api_client.dart';
import 'reuniones_repository.dart';
import 'rtc_participation.dart';
import 'breakout_repository.dart';
import 'rtc_screen_share.dart';
import 'rtc_audio_devices.dart';
import 'rtc_permissions.dart';
import 'rtc_video_policy.dart';

/// Lectura de nivel RMS de audio remoto; conserva la muestra anterior para
/// plataformas que solo informan energía acumulada.
class RtcAudioMeter {
  double? _previousEnergy;
  double? _previousDuration;

  double sample(List<StatsReport> reports) {
    var maximum = 0.0;
    for (final report in reports) {
      if (report.type != 'inbound-rtp') continue;
      final values = report.values;
      if (values['kind'] != 'audio' && values['mediaType'] != 'audio') continue;
      final raw = values['audioLevel'];
      if (raw is num) maximum = max(maximum, raw.toDouble());
      final energy = values['totalAudioEnergy'];
      final duration = values['totalSamplesDuration'];
      if (energy is num && duration is num) {
        final e = energy.toDouble();
        final d = duration.toDouble();
        if (_previousEnergy != null &&
            _previousDuration != null &&
            d > _previousDuration!) {
          final rms = sqrt(
            max(0, (e - _previousEnergy!) / (d - _previousDuration!)),
          );
          maximum = max(maximum, rms);
        }
        _previousEnergy = e;
        _previousDuration = d;
      }
    }
    return maximum;
  }
}

class RtcRemotePeer {
  RtcRemotePeer(this.userId, this.renderer, this.connection);

  final String userId;
  final RTCVideoRenderer renderer;
  final RTCPeerConnection connection;
  RtcPermissions permissions = const RtcPermissions();
  RTCRtpSender? videoSender;
  final List<RTCIceCandidate> pendingIce = [];
  final RtcParticipation participation = RtcParticipation();
  bool remoteDescriptionSet = false;

  /// Estado de la conexión P2P. Los medios siguen fluyendo aunque se caiga
  /// la señalización del servidor, así que no se cierra por eso.
  RTCPeerConnectionState? connectionState;
  bool get mediaConnected =>
      connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
  bool cameraEnabled = true;
  bool speaking = false;
  DateTime? lastVoice;
  final RtcAudioMeter audioMeter = RtcAudioMeter();
  bool get visible =>
      renderer.srcObject != null &&
      permissions.cameraAllowed &&
      (cameraEnabled || participation.screenSharing);
}

/// Sala WebRTC mesh P2P para un máximo de tres dispositivos.
class RtcCallController extends ChangeNotifier {
  RtcCallController(
    this.nodoId,
    this.reunionId,
    this.repository, {
    this.salaId,
    this.microphoneEnabled = true,
    this.cameraEnabled = true,
  }) {
    participation.microphoneEnabled = microphoneEnabled;
    audioDevices = RtcAudioDevices(
      enumerate: () => navigator.mediaDevices.enumerateDevices(),
      selectInput: (id) async {
        if (_closed) return;
        await Helper.selectAudioInput(id);
        // Reapply the current privacy state, including a moderator mute.
        for (final track
            in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
          track.enabled = microphoneEnabled;
        }
      },
      selectOutput: Helper.selectAudioOutput,
    );
    screenShare = RtcScreenShare(
      cameraTrack: () => _localStream?.getVideoTracks().firstOrNull,
      replaceTrack: (track) async {
        for (final peer in List<RtcRemotePeer>.of(_peers.values)) {
          if (_closed) throw StateError('Call closed');
          if (!identical(_peers[peer.userId], peer)) continue;
          await peer.videoSender?.replaceTrack(track);
        }
      },
      onChanged: () {
        if (_closed) return;
        localRenderer.srcObject = screenShare.stream ?? _localStream;
        for (final user in _peers.keys) {
          _send(user, 'screen_state', {'enabled': screenShare.active});
        }
        notifyListeners();
      },
      onRestoreFailure: () => _fail(
        'No se pudo restaurar la cámara. Vuelve a entrar a la llamada.',
      ),
    );
  }

  final String nodoId;
  final String reunionId;

  /// Sala de trabajo de esta conexión (IRL-RTC-US-07); `null` = principal.
  final String? salaId;

  /// Último cambio de sala que pidió el moderador y aún no se aplica.
  BreakoutTarget? pendingBreakout;

  /// IRL-RTC-US-08: eventos de la pizarra de este canal.
  final _whiteboard = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get whiteboardEvents => _whiteboard.stream;

  /// Trazos nuevos desde que se miró la pizarra por última vez.
  int whiteboardActivity = 0;
  void markWhiteboardSeen() {
    if (whiteboardActivity == 0) return;
    whiteboardActivity = 0;
    notifyListeners();
  }

  final ReunionesRepository repository;
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final Map<String, RtcRemotePeer> _peers = {};
  final Map<String, RtcPermissions> _peerPermissions = {};
  final RtcParticipation participation = RtcParticipation();
  late final RtcScreenShare screenShare;
  late final RtcAudioDevices audioDevices;
  RtcPermissions permissions = const RtcPermissions();
  bool _canModerate = false;
  bool moderationBusy = false;
  String? moderationError;
  bool get canModerate =>
      !_closed && _canModerate && _capabilities.contains('moderation');
  bool get canSelectAudioDevices =>
      !_closed &&
      _localStream != null &&
      !kIsWeb &&
      {
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }.contains(defaultTargetPlatform);
  bool screenBusy = false;
  String? screenError;
  bool get screenSharing => screenShare.active;
  bool get canShareScreen =>
      !_closed &&
      _ownUser != null &&
      _capabilities.contains('screen_state') &&
      permissions.cameraAllowed &&
      (kIsWeb ||
          {
            TargetPlatform.macOS,
            TargetPlatform.windows,
            TargetPlatform.linux,
          }.contains(defaultTargetPlatform));
  final Map<String, Timer> _reactionTimers = {};
  Set<String> _capabilities = {};

  MediaStream? _localStream;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Future<void> _events = Future<void>.value();
  Timer? _audioTimer;
  bool _pollingAudio = false;
  String? _ownUser;
  bool _closed = false;
  bool _renderersReady = false;

  /// Estado elegido en la sala de espera; luego lo cambian los botones y la
  /// moderación del servidor.
  bool microphoneEnabled;
  bool cameraEnabled;

  /// `false` cuando el stream local no trae pista de cámara o de micrófono
  /// (sin permiso o sin dispositivo); antes de abrir los medios se asume que sí.
  bool get hasCamera =>
      _localStream == null || _localStream!.getVideoTracks().isNotEmpty;
  bool get hasMicrophone =>
      _localStream == null || _localStream!.getAudioTracks().isNotEmpty;
  bool localSpeaking = false;
  DateTime? _lastLocalVoice;
  bool get renderersReady => _renderersReady;
  String? get ownUserId => _ownUser;
  List<RtcRemotePeer> get peers => List.unmodifiable(_peers.values);
  String status = 'Solicitando cámara y micrófono…';
  String? error;

  void _update(String value) {
    if (_closed) return;
    status = value;
    notifyListeners();
  }

  /// Entra a la sala. [media] es el stream ya abierto en la sala de espera
  /// (la llamada pasa a ser su dueña); sin él se piden los dispositivos aquí.
  Future<void> join({MediaStream? media}) async {
    if (media != null) {
      if (_closed) {
        await _releaseStream(media);
        return;
      }
      // Desde aquí `close()` libera el stream recibido.
      _localStream = media;
      _applyInitialMedia(media);
    }
    try {
      await localRenderer.initialize();
      if (_closed) {
        await localRenderer.dispose();
        return;
      }
      _renderersReady = true;
      if (_localStream == null) {
        final opened = await _openMedia();
        if (_closed) {
          await _releaseStream(opened);
          return;
        }
        _localStream = opened;
        _applyInitialMedia(opened);
      }
      localRenderer.srcObject = _localStream;
      _update('Conectando a la sala…');
      await _connectSignaling();
      if (_closed) return;
      _audioTimer = Timer.periodic(const Duration(milliseconds: 350), (_) {
        unawaited(_refreshAudioLevels());
      });
    } catch (_) {
      _fail('No se pudo iniciar la llamada. Revisa permisos y conexión.');
      await close();
    }
  }

  /// Pide cámara y micrófono; si la cámara falla (sin permiso o sin
  /// dispositivo) se entra solo con audio y la cámara apagada.
  Future<MediaStream> _openMedia() async {
    final video = RtcVideoPolicy.constraints();
    try {
      return await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': video,
      });
    } catch (_) {
      if (_closed) rethrow;
      return navigator.mediaDevices.getUserMedia({'audio': true});
    }
  }

  /// Aplica a las pistas el estado inicial elegido; lo que no existe queda
  /// apagado.
  void _applyInitialMedia(MediaStream media) {
    if (media.getVideoTracks().isEmpty) cameraEnabled = false;
    if (media.getAudioTracks().isEmpty) microphoneEnabled = false;
    participation.microphoneEnabled = microphoneEnabled;
    for (final track in media.getVideoTracks()) {
      track.enabled = cameraEnabled;
    }
    for (final track in media.getAudioTracks()) {
      track.enabled = microphoneEnabled;
    }
  }

  /// Aplica el estado inicial a un stream de prueba, sin plataforma.
  @visibleForTesting
  void applyInitialMediaForTest(MediaStream media) {
    _localStream = media;
    _applyInitialMedia(media);
  }

  static Future<void> _releaseStream(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (_) {}
    }
    try {
      await stream.dispose();
    } catch (_) {}
  }

  /// Pide un pase de un solo uso y abre la señalización de la sala. Se usa
  /// al entrar y en cada reconexión; los medios locales no se tocan.
  Future<void> _connectSignaling() async {
    final ticket = await repository.issueRtcTicket(
      nodoId: nodoId,
      reunionId: reunionId,
      salaId: salaId,
    );
    if (_closed) return;
    final api = Uri.parse(ApiClient.baseUrl);
    final uri = api.replace(
      scheme: api.scheme == 'https' ? 'wss' : 'ws',
      path: '/rtc/ws',
      queryParameters: {'ticket': ticket},
    );
    final channel = WebSocketChannel.connect(uri);
    await channel.ready;
    if (_closed) {
      await channel.sink.close();
      return;
    }
    _channel = channel;
    _subscription = channel.stream.listen(
      (raw) {
        _events = _events.then((_) => _handle(raw)).catchError((Object _) {
          _fail('Falló la negociación de la llamada.');
        });
      },
      onError: (Object _) => _signalingLost(channel),
      onDone: () => _signalingLost(channel),
    );
  }

  // Reconexión automática de la señalización. El servidor renueva la conexión
  // cada 15 minutos (`session_renew`), y puede reiniciarse o caerse. En mesh
  // P2P el audio y el video viajan directo entre participantes, así que una
  // caída del servidor NO debe cortar la llamada: se conservan las conexiones
  // con los demás y se sigue reintentando mientras haya medios activos. Solo
  // se abandona si no queda nadie conectado tras varios intentos, si la
  // reunión terminó o si la persona entró desde otro dispositivo.
  static const _maxReconnectsWithoutMedia = 3;
  static const _maxBackoffSeconds = 10;
  int _reconnects = 0;
  bool _reconnecting = false;
  bool _renewRequested = false;
  bool _replaced = false;

  /// La llamada sigue aunque la señalización esté caída.
  bool get signalingOffline => _reconnecting;
  bool get _mediaAlive => _peers.values.any((p) => p.mediaConnected);

  void _signalingLost(WebSocketChannel channel) {
    if (_closed || _reconnecting || !identical(channel, _channel)) return;
    // Sin canal no se envía nada (enviar a un socket cerrado lanza error).
    _channel = null;
    if (_replaced) {
      _fail('Entraste a esta llamada desde otra ventana o dispositivo.');
      return;
    }
    unawaited(_reconnect());
  }

  Future<void> _reconnect() async {
    _reconnecting = true;
    final renew = _renewRequested;
    _renewRequested = false;
    while (!_closed) {
      if (!renew || _reconnects > 0) {
        if (_reconnects >= _maxReconnectsWithoutMedia && !_mediaAlive) {
          _reconnecting = false;
          _fail(
            'Se perdió la conexión de la sala. Vuelve a entrar para reconectar.',
          );
          return;
        }
        _update(
          _mediaAlive
              ? 'Sin conexión con el servidor. La llamada continúa; reconectando…'
              : 'Reconectando…',
        );
        final wait = min(1 << min(_reconnects, 4), _maxBackoffSeconds);
        await Future<void>.delayed(Duration(seconds: wait));
      }
      _reconnects++;
      if (_closed) break;
      try {
        await _subscription?.cancel();
      } catch (_) {}
      try {
        await _connectSignaling();
        _reconnecting = false;
        return;
      } on DioException catch (e) {
        // El servidor rechaza el pase: la reunión terminó o se perdió el acceso.
        if (e.response?.statusCode == 403 || e.response?.statusCode == 404) {
          _reconnecting = false;
          _fail('La reunión terminó o ya no tienes acceso a ella.');
          return;
        }
      } catch (_) {}
    }
    _reconnecting = false;
  }

  void _fail(String message) {
    if (_closed) return;
    error = message;
    status = 'Sin conexión';
    notifyListeners();
    unawaited(close());
  }

  /// Procesa un mensaje del servidor sin WebSocket, solo para pruebas.
  @visibleForTesting
  Future<void> handleForTest(String raw) => _handle(raw);

  /// Simula el cierre de la señalización, solo para pruebas.
  @visibleForTesting
  Future<void> signalingLostForTest() async {
    final channel = _channel;
    if (channel != null) {
      _signalingLost(channel);
    } else if (_replaced) {
      _fail('Entraste a esta llamada desde otra ventana o dispositivo.');
    } else {
      await _reconnect();
    }
  }

  Future<void> _handle(dynamic raw) async {
    if (_closed || raw is! String) return;
    final message = jsonDecode(raw) as Map<String, dynamic>;
    switch (message['type']) {
      case 'session_renew':
        _renewRequested = true;
      case 'replaced':
        _replaced = true;
      case 'room_state':
        _reconnects = 0;
        _ownUser = message['user_id'] as String;
        _capabilities = RtcParticipation.capabilities(message['capabilities']);
        _canModerate = message['can_moderate'] == true;
        final policies = message['peer_permissions'];
        if (policies is Map) {
          for (final entry in policies.entries) {
            final parsed = RtcPermissions.parse(entry.value);
            if (entry.key is String && parsed != null) {
              _peerPermissions[entry.key as String] = parsed;
            }
          }
        }
        if (message['permissions'] != null) {
          await _applyPermissions(message['permissions']);
          if (_closed) return;
        }
        final users = (message['peers'] as List<dynamic>).cast<String>();
        // Tras una reconexión se conservan las conexiones que siguen vivas;
        // las que murieron mientras el servidor no estaba se rehacen.
        for (final user in List<String>.of(_peers.keys)) {
          final peer = _peers[user]!;
          if (!peer.mediaConnected) {
            await _clearPeer(user);
          }
        }
        _update(
          users.isEmpty && _peers.isEmpty
              ? 'Esperando a otra persona…'
              : _mediaAlive
              ? 'En llamada'
              : 'Negociando llamada…',
        );
        for (final user in users) {
          final existing = _peers[user];
          if (existing != null && existing.mediaConnected) continue;
          final peer = await _preparePeer(user);
          if (peer != null) await _sendOffer(peer);
        }
      case 'whiteboard':
        if (!_whiteboard.isClosed) _whiteboard.add(message);
        if (message['op'] == 'stroke') {
          whiteboardActivity++;
          notifyListeners();
        }
      case 'breakout':
        final target = BreakoutTarget.parse(message['sala']);
        pendingBreakout = target.id == salaId ? null : target;
        notifyListeners();
      case 'peer_joined':
        final user = message['user_id'] as String;
        if (user != _ownUser) {
          // Quien vuelve tras una caída del servidor envía una oferta nueva;
          // si nuestra conexión con esa persona ya no sirve, se rehace.
          final existing = _peers[user];
          if (existing != null && !existing.mediaConnected) {
            await _clearPeer(user);
          }
          await _preparePeer(user);
          _update('Negociando llamada…');
        }
      case 'peer_left':
        await _clearPeer(message['user_id'] as String);
        _update(_peers.isEmpty ? 'Esperando a otra persona…' : 'En llamada');
      case 'signal':
        final data = message['data'] as Map<String, dynamic>;
        final sender = data['sender'] as String;
        if (sender == _ownUser) return;
        final peer = await _preparePeer(sender);
        if (peer == null) return;
        final signal = data['signal'] as Map<String, dynamic>;
        final payload = signal['payload'] as Map<String, dynamic>;
        switch (signal['type']) {
          case 'offer':
            await peer.connection.setRemoteDescription(
              RTCSessionDescription(payload['sdp'] as String, 'offer'),
            );
            peer.remoteDescriptionSet = true;
            await _flushIce(peer);
            final answer = await peer.connection.createAnswer();
            await peer.connection.setLocalDescription(answer);
            await _limitVideo(peer);
            _send(sender, 'answer', {'sdp': answer.sdp});
          case 'answer':
            await peer.connection.setRemoteDescription(
              RTCSessionDescription(payload['sdp'] as String, 'answer'),
            );
            peer.remoteDescriptionSet = true;
            await _flushIce(peer);
            await _limitVideo(peer);
          case 'ice_candidate':
            final ice = RTCIceCandidate(
              payload['candidate'] as String,
              payload['sdp_mid'] as String?,
              payload['sdp_m_line_index'] as int?,
            );
            if (peer.remoteDescriptionSet) {
              await peer.connection.addCandidate(ice);
            } else {
              peer.pendingIce.add(ice);
            }
          case 'camera_state':
            peer.cameraEnabled = payload['enabled'] == true;
            notifyListeners();
          case 'microphone_state':
          case 'screen_state':
          case 'hand_state':
          case 'reaction':
            if (peer.participation.apply(
              signal['type'] as String,
              payload,
              DateTime.now(),
            )) {
              if (!peer.participation.microphoneEnabled) {
                peer.lastVoice = null;
                peer.speaking = false;
              }
              if (signal['type'] == 'reaction') {
                _expireReaction(sender, peer.participation);
              }
              notifyListeners();
            }
        }
      case 'error':
        if (message['code'] == 'recipient_unavailable') {
          _update('Un participante dejó de estar disponible.');
        } else {
          _fail('La sala rechazó una operación: ${message['code']}');
        }
      case 'permissions':
        await _applyPermissions(message['data']);
      case 'participant_permissions':
        final user = message['user_id'];
        final policy = RtcPermissions.parse(message['data']);
        if (user is String && policy != null && user != _ownUser) {
          _peerPermissions[user] = policy;
          final peer = _peers[user];
          if (peer != null) _applyPeerPermissions(peer, policy);
          notifyListeners();
        }
      case 'removed':
        _fail('Un moderador te expulsó de esta reunión.');
    }
  }

  Future<RtcRemotePeer?> _preparePeer(String user) =>
      screenShare.serialized(() => _preparePeerLocked(user));

  Future<RtcRemotePeer?> _preparePeerLocked(String user) async {
    if (_closed) return null;
    if (_peers.containsKey(user)) return _peers[user];
    if (_peers.length >= 2) return null;
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    if (_closed) {
      await renderer.dispose();
      return null;
    }
    final stun = const String.fromEnvironment(
      'RTC_STUN_URL',
      defaultValue: 'stun:stun.l.google.com:19302',
    );
    RTCPeerConnection connection;
    try {
      connection = await createPeerConnection({
        'sdpSemantics': 'unified-plan',
        'iceServers': [
          {'urls': stun},
        ],
      });
    } catch (_) {
      await renderer.dispose();
      rethrow;
    }
    if (_closed) {
      await connection.close();
      await connection.dispose();
      await renderer.dispose();
      return null;
    }
    final peer = RtcRemotePeer(user, renderer, connection);
    _applyPeerPermissions(
      peer,
      _peerPermissions[user] ?? const RtcPermissions(),
    );
    _peers[user] = peer;
    connection.onIceCandidate = (candidate) {
      if (candidate.candidate?.isNotEmpty == true &&
          !_closed &&
          identical(_peers[user], peer)) {
        _send(user, 'ice_candidate', {
          'candidate': candidate.candidate,
          'sdp_mid': candidate.sdpMid,
          'sdp_m_line_index': candidate.sdpMLineIndex,
        });
      }
    };
    connection.onTrack = (event) {
      if (_closed || event.streams.isEmpty || !identical(_peers[user], peer)) {
        return;
      }
      renderer.srcObject = event.streams.first;
      peer.permissions.restrictReceivedTracks(event.streams.first.getTracks());
      _update('En llamada');
    };
    connection.onConnectionState = (state) {
      if (_closed || !identical(_peers[user], peer)) return;
      peer.connectionState = state;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        if (!_reconnecting) _update('En llamada');
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _update('Conexión interrumpida');
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(_recoverPeer(user, peer));
      }
    };
    final local = _localStream!;
    for (final track in local.getTracks()) {
      final outgoing = track.kind == 'video'
          ? screenShare.videoTrack ?? track
          : track;
      final sender = await connection.addTrack(outgoing, local);
      if (track.kind == 'video') peer.videoSender = sender;
    }
    // Sin cámara o micrófono propios se sigue recibiendo lo de los demás; el
    // emisor de video vacío permite compartir pantalla más tarde.
    if (local.getAudioTracks().isEmpty) {
      await connection.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
    }
    if (local.getVideoTracks().isEmpty) {
      final shared = screenShare.videoTrack;
      final transceiver = await connection.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendRecv,
          streams: [local],
        ),
      );
      peer.videoSender = transceiver.sender;
      if (shared != null) await transceiver.sender.replaceTrack(shared);
    }
    if (!cameraEnabled) _send(user, 'camera_state', {'enabled': false});
    _send(user, 'microphone_state', {'enabled': microphoneEnabled});
    _send(user, 'hand_state', {'raised': participation.handRaised});
    _send(user, 'screen_state', {'enabled': screenSharing});
    notifyListeners();
    return peer;
  }

  /// Una conexión P2P que falló se rehace. Para evitar ofertas cruzadas solo
  /// ofrece quien tiene el identificador menor; el otro espera esa oferta.
  /// Si la señalización está caída, se rehará al volver (`room_state`).
  Future<void> _recoverPeer(String user, RtcRemotePeer peer) async {
    if (_closed || !identical(_peers[user], peer)) return;
    _update('Conexión interrumpida');
    if (_channel == null || _ownUser == null) return;
    await _clearPeer(user);
    if (_ownUser!.compareTo(user) < 0) {
      final fresh = await _preparePeer(user);
      if (fresh != null) await _sendOffer(fresh);
    }
  }

  Future<void> _sendOffer(RtcRemotePeer peer) async {
    final offer = await peer.connection.createOffer();
    await peer.connection.setLocalDescription(offer);
    await _limitVideo(peer);
    _send(peer.userId, 'offer', {'sdp': offer.sdp});
  }

  Future<void> _limitVideo(RtcRemotePeer peer) async {
    if (_closed || !identical(_peers[peer.userId], peer)) return;
    try {
      await RtcVideoPolicy.apply(peer.connection);
    } catch (_) {
      // Algunas plataformas no permiten setParameters. La captura sigue
      // limitada; un fallo de optimización no debe cerrar toda la llamada.
      debugPrint('IronLink RTC: no se pudo aplicar el presupuesto de video.');
    }
  }

  void _send(String recipient, String type, Map<String, dynamic> payload) {
    if (_closed || _channel == null) return;
    if (RtcParticipation.signalTypes.contains(type) &&
        !_capabilities.contains(type)) {
      return;
    }
    try {
      _channel!.sink.add(
        jsonEncode({
          'version': 1,
          'event_id': _eventId(),
          'recipient': recipient,
          'signal': {'type': type, 'payload': payload},
        }),
      );
    } catch (_) {
      // Socket ya cerrado: la reconexión reenvía el estado al volver.
    }
  }

  String _eventId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _flushIce(RtcRemotePeer peer) async {
    for (final candidate in peer.pendingIce) {
      await peer.connection.addCandidate(candidate);
    }
    peer.pendingIce.clear();
  }

  Future<void> _clearPeer(String user) async {
    _peerPermissions.remove(user);
    _reactionTimers.remove(user)?.cancel();
    final peer = _peers.remove(user);
    if (peer == null) return;
    peer.renderer.srcObject = null;
    try {
      await peer.connection.close();
      await peer.connection.dispose();
    } finally {
      await peer.renderer.dispose();
    }
    if (!_closed) notifyListeners();
  }

  Future<void> _refreshAudioLevels() async {
    if (_closed || _pollingAudio) return;
    _pollingAudio = true;
    try {
      var changed = false;
      final now = DateTime.now();
      for (final peer in List<RtcRemotePeer>.of(_peers.values)) {
        try {
          final reports = await peer.connection.getStats();
          if (_closed || !identical(_peers[peer.userId], peer)) continue;
          final level = peer.audioMeter.sample(reports);
          if (microphoneEnabled && _localAudioLevel(reports) > 0.025) {
            _lastLocalVoice = now;
          }
          if (peer.participation.microphoneEnabled && level > 0.025) {
            peer.lastVoice = now;
          }
          final speaking =
              peer.participation.microphoneEnabled &&
              peer.lastVoice != null &&
              now.difference(peer.lastVoice!) <
                  const Duration(milliseconds: 650);
          if (speaking != peer.speaking) {
            peer.speaking = speaking;
            changed = true;
          }
        } catch (_) {
          // Una plataforma sin estadísticas no debe interrumpir la llamada.
        }
      }
      final ownSpeaking =
          microphoneEnabled &&
          _lastLocalVoice != null &&
          now.difference(_lastLocalVoice!) < const Duration(milliseconds: 650);
      if (ownSpeaking != localSpeaking) {
        localSpeaking = ownSpeaking;
        changed = true;
      }
      if (changed && !_closed) notifyListeners();
    } finally {
      _pollingAudio = false;
    }
  }

  static double _localAudioLevel(List<StatsReport> reports) {
    var maximum = 0.0;
    for (final report in reports) {
      if (report.type != 'media-source') continue;
      final values = report.values;
      if (values['kind'] != 'audio' && values['mediaType'] != 'audio') continue;
      final raw = values['audioLevel'];
      if (raw is num) maximum = max(maximum, raw.toDouble());
    }
    return maximum;
  }

  void toggleMicrophone() {
    if (_closed) return;
    if (!permissions.microphoneAllowed && !microphoneEnabled) return;
    if (!hasMicrophone && !microphoneEnabled) return;
    microphoneEnabled = !microphoneEnabled;
    if (!microphoneEnabled) {
      localSpeaking = false;
      _lastLocalVoice = null;
    }
    for (final track
        in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = microphoneEnabled;
    }
    participation.microphoneEnabled = microphoneEnabled;
    for (final user in _peers.keys) {
      _send(user, 'microphone_state', {'enabled': microphoneEnabled});
    }
    notifyListeners();
  }

  bool get canInteract =>
      !_closed &&
      _ownUser != null &&
      _capabilities.contains('hand_state') &&
      _capabilities.contains('reaction');

  void toggleHand() {
    if (!canInteract) return;
    participation.apply('hand_state', {
      'raised': !participation.handRaised,
    }, DateTime.now());
    for (final user in _peers.keys) {
      _send(user, 'hand_state', {'raised': participation.handRaised});
    }
    notifyListeners();
  }

  void sendReaction(String emoji) {
    if (!canInteract || !participation.react(emoji, DateTime.now())) return;
    for (final user in _peers.keys) {
      _send(user, 'reaction', {'emoji': emoji});
    }
    _expireReaction('@local', participation);
    notifyListeners();
  }

  void _expireReaction(String user, RtcParticipation state) {
    _reactionTimers.remove(user)?.cancel();
    _reactionTimers[user] = Timer(RtcParticipation.reactionLifetime, () {
      _reactionTimers.remove(user);
      if (_closed) return;
      state.clearReaction();
      notifyListeners();
    });
  }

  void toggleCamera() {
    if (_closed) return;
    if (!permissions.cameraAllowed && !cameraEnabled) return;
    if (!hasCamera && !cameraEnabled) return;
    cameraEnabled = !cameraEnabled;
    for (final track
        in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = cameraEnabled;
    }
    for (final user in _peers.keys) {
      _send(user, 'camera_state', {'enabled': cameraEnabled});
    }
    notifyListeners();
  }

  /// Only called after an explicit user action and, on desktop, source selection.
  Future<void> startScreenShare({String? sourceId}) async {
    if (!canShareScreen || screenBusy || screenSharing) return;
    if (!kIsWeb && sourceId == null) return;
    screenBusy = true;
    screenError = null;
    notifyListeners();
    try {
      await screenShare.start(
        () => navigator.mediaDevices.getDisplayMedia({
          'audio': false, // Keep the existing microphone and its mute state.
          'video': kIsWeb
              ? true
              : {
                  'deviceId': {'exact': sourceId},
                  'mandatory': {'frameRate': 15.0},
                },
        }),
        canPublish: () => !_closed && permissions.cameraAllowed,
      );
    } catch (_) {
      if (!_closed) {
        screenError =
            'No se pudo compartir. Revisa el permiso de grabación de pantalla o selecciona otra ventana.';
      }
    } finally {
      screenBusy = false;
      if (!_closed) notifyListeners();
    }
  }

  Future<void> stopScreenShare() async {
    if (_closed || screenBusy) return;
    screenBusy = true;
    notifyListeners();
    await screenShare.stop();
    screenBusy = false;
    if (!_closed) notifyListeners();
  }

  Future<void> _applyPermissions(dynamic data) async {
    final updated = RtcPermissions.parse(data);
    if (updated == null || updated.kicked) {
      _fail(
        updated?.kicked == true
            ? 'Un moderador te expulsó de esta reunión.'
            : 'La sala envió permisos inválidos.',
      );
      return;
    }
    permissions = updated;
    final restricted = updated.constrain(
      microphone: microphoneEnabled,
      camera: cameraEnabled,
    );
    if (!restricted.microphone && microphoneEnabled) toggleMicrophone();
    if (!updated.cameraAllowed) {
      if (!restricted.camera && cameraEnabled) toggleCamera();
      if (screenSharing) await screenShare.stop();
    }
    if (!_closed) notifyListeners();
  }

  void _applyPeerPermissions(RtcRemotePeer peer, RtcPermissions policy) {
    peer.permissions = policy;
    policy.restrictReceivedTracks(
      peer.renderer.srcObject?.getTracks() ?? <MediaStreamTrack>[],
    );
    if (!policy.microphoneAllowed) {
      peer.participation.microphoneEnabled = false;
      peer.speaking = false;
      peer.lastVoice = null;
    }
    if (!policy.cameraAllowed) peer.participation.screenSharing = false;
  }

  Future<void> moderate(String action, {String? target, bool? allowed}) async {
    if (!canModerate || moderationBusy) return;
    moderationBusy = true;
    moderationError = null;
    notifyListeners();
    try {
      await repository.moderate(
        nodoId: nodoId,
        reunionId: reunionId,
        action: action,
        target: target,
        allowed: allowed,
      );
    } catch (_) {
      if (!_closed) {
        moderationError =
            'No se pudo aplicar la acción. Revisa tu rol, la conexión y si el participante sigue en la sala. Otros moderadores están protegidos.';
      }
    } finally {
      moderationBusy = false;
      if (!_closed) notifyListeners();
    }
  }

  @override
  void dispose() {
    audioDevices.close();
    audioDevices.dispose();
    super.dispose();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    unawaited(_whiteboard.close());
    audioDevices.close();
    final screenClosed = screenShare.close();
    _audioTimer?.cancel();
    for (final timer in _reactionTimers.values) {
      timer.cancel();
    }
    _reactionTimers.clear();
    participation.apply('hand_state', {'raised': false}, DateTime.now());
    participation.clearReaction();
    final disposeLocalRenderer = _renderersReady;
    _renderersReady = false;
    notifyListeners();
    try {
      await _subscription?.cancel();
    } catch (_) {}
    try {
      await _channel?.sink.close();
    } catch (_) {}
    await screenClosed;
    for (final user in List<String>.of(_peers.keys)) {
      try {
        await _clearPeer(user);
      } catch (_) {}
    }
    final stream = _localStream;
    _localStream = null;
    if (stream != null) await _releaseStream(stream);
    if (disposeLocalRenderer) {
      try {
        await localRenderer.dispose();
      } catch (_) {}
    }
  }
}
