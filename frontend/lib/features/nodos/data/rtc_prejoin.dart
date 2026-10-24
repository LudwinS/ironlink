import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'rtc_audio_devices.dart';
import 'rtc_video_policy.dart';

/// Acceso a los dispositivos locales. Se inyecta para poder probar la vista
/// previa sin cámara ni micrófono reales.
class RtcMediaAccess {
  const RtcMediaAccess();

  Future<MediaStream> getUserMedia(Map<String, dynamic> constraints) =>
      navigator.mediaDevices.getUserMedia(constraints);

  Future<List<MediaDeviceInfo>> enumerateDevices() =>
      navigator.mediaDevices.enumerateDevices();

  Future<void> selectAudioInput(String id) => Helper.selectAudioInput(id);

  Future<void> selectAudioOutput(String id) => Helper.selectAudioOutput(id);

  /// El cambio de ruta de audio solo está disponible en escritorio.
  bool get canRouteAudio =>
      !kIsWeb &&
      {
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }.contains(defaultTargetPlatform);

  /// Renderizador ya inicializado para la vista previa, o `null` si la
  /// plataforma no puede mostrar video.
  Future<RTCVideoRenderer?> createRenderer() async {
    final renderer = RTCVideoRenderer();
    try {
      await renderer.initialize();
      return renderer;
    } catch (_) {
      try {
        await renderer.dispose();
      } catch (_) {}
      return null;
    }
  }
}

/// Restricciones de video comunes a la vista previa y a la llamada.
Map<String, dynamic> rtcVideoConstraints({String? deviceId}) =>
    RtcVideoPolicy.constraints(deviceId: deviceId);

/// Estado de la sala de espera («lobby») previa a una llamada: abre la cámara
/// y el micrófono una sola vez, deja elegir con qué entrar y entrega el mismo
/// stream a la llamada para no volver a pedir los dispositivos.
class RtcPrejoin extends ChangeNotifier {
  RtcPrejoin({
    this.media = const RtcMediaAccess(),
    bool cameraEnabled = true,
    bool microphoneEnabled = true,
  }) : _cameraWanted = cameraEnabled,
       _microphoneWanted = microphoneEnabled {
    audioDevices = RtcAudioDevices(
      enumerate: media.enumerateDevices,
      selectInput: media.selectAudioInput,
      selectOutput: media.selectAudioOutput,
    );
  }

  final RtcMediaAccess media;
  late final RtcAudioDevices audioDevices;

  MediaStream? _stream;
  bool loading = true;
  bool busy = false;
  bool _cameraWanted, _microphoneWanted;
  bool _closed = false;
  List<MediaDeviceInfo> cameras = [];
  String? cameraId;

  MediaStream? get stream => _stream;
  bool get cameraAvailable => _stream?.getVideoTracks().isNotEmpty ?? false;
  bool get microphoneAvailable => _stream?.getAudioTracks().isNotEmpty ?? false;

  /// Estado con el que se entrará a la llamada.
  bool get cameraEnabled => _cameraWanted && cameraAvailable;
  bool get microphoneEnabled => _microphoneWanted && microphoneAvailable;

  bool get canSelectAudio =>
      !_closed && microphoneAvailable && media.canRouteAudio;
  bool get canSelectCamera =>
      !_closed && cameraAvailable && !busy && cameras.length > 1;

  /// Aviso para la persona cuando falta algún dispositivo.
  String? get notice {
    if (loading) return null;
    if (!cameraAvailable && !microphoneAvailable) {
      return 'No se pudo acceder a la cámara ni al micrófono. Revisa los permisos de IronLink en la configuración del sistema.';
    }
    if (!cameraAvailable) {
      return 'No hay cámara disponible o IronLink no tiene permiso para usarla. Puedes entrar con la cámara apagada.';
    }
    if (!microphoneAvailable) {
      return 'No hay micrófono disponible o IronLink no tiene permiso para usarlo. Entrarás silenciado.';
    }
    return null;
  }

  Future<void> start() async {
    await _open();
    if (_closed) return;
    loading = false;
    notifyListeners();
    await _refreshDevices();
  }

  /// Intenta audio y video; si la cámara o el micrófono fallan, se queda con
  /// lo que sí esté disponible.
  Future<void> _open() async {
    final video = rtcVideoConstraints(deviceId: cameraId);
    for (final constraints in [
      {'audio': true, 'video': video},
      {'audio': true},
      {'video': video},
    ]) {
      try {
        final opened = await media.getUserMedia(constraints);
        if (_closed) {
          await _release(opened);
          return;
        }
        _stream = opened;
        _applyEnabled();
        return;
      } catch (_) {
        if (_closed) return;
      }
    }
  }

  Future<void> _refreshDevices() async {
    try {
      final found = await media.enumerateDevices();
      if (_closed) return;
      final ids = <String>{};
      cameras = found
          .where(
            (d) =>
                d.kind == 'videoinput' &&
                d.deviceId.isNotEmpty &&
                ids.add(d.deviceId),
          )
          .toList();
      if (cameraId == null) {
        try {
          cameraId = _stream
              ?.getVideoTracks()
              .firstOrNull
              ?.getSettings()['deviceId']
              ?.toString();
        } catch (_) {}
      }
      if (!cameras.any((d) => d.deviceId == cameraId)) cameraId = null;
      notifyListeners();
    } catch (_) {
      // La vista previa sigue siendo útil aunque no se puedan listar.
    }
    if (canSelectAudio) await audioDevices.refresh();
  }

  void _applyEnabled() {
    for (final track in _stream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = _cameraWanted;
    }
    for (final track in _stream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = _microphoneWanted;
    }
  }

  void toggleCamera() {
    if (_closed || !cameraAvailable) return;
    _cameraWanted = !_cameraWanted;
    _applyEnabled();
    notifyListeners();
  }

  void toggleMicrophone() {
    if (_closed || !microphoneAvailable) return;
    _microphoneWanted = !_microphoneWanted;
    _applyEnabled();
    notifyListeners();
  }

  /// Cambia de cámara: libera la anterior antes de abrir la nueva (en macOS
  /// abrir dos veces el mismo dispositivo puede fallar).
  Future<void> selectCamera(String id) async {
    if (!canSelectCamera || id == cameraId) return;
    busy = true;
    notifyListeners();
    final previous = _stream;
    _stream = null;
    if (previous != null) await _release(previous);
    cameraId = id;
    await _open();
    busy = false;
    if (!_closed) notifyListeners();
  }

  /// Entrega el stream a la llamada; desde aquí lo libera la llamada.
  MediaStream? takeStream() {
    final taken = _stream;
    _stream = null;
    _closed = true;
    audioDevices.close();
    return taken;
  }

  Future<void> close() async {
    _closed = true;
    audioDevices.close();
    final previous = _stream;
    _stream = null;
    if (previous != null) await _release(previous);
  }

  @override
  void dispose() {
    audioDevices.dispose();
    super.dispose();
  }

  static Future<void> _release(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      try {
        await track.stop();
      } catch (_) {}
    }
    try {
      await stream.dispose();
    } catch (_) {}
  }
}
