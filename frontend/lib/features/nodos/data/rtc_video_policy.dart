import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Presupuesto por conexión para la malla de hasta tres participantes.
/// La cámara se abre una sola vez, pero cada destinatario tiene su codificador.
class RtcVideoPolicy {
  static bool get mobile =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  static Map<String, dynamic> constraints({String? deviceId}) => {
    'facingMode': 'user',
    'width': 640,
    'height': 480,
    // Darwin interpreta un frameRate ausente como 0, no como un valor default.
    'frameRate': mobile ? 15 : 24,
    'deviceId': ?deviceId,
  };

  /// Conserva transactionId, SSRC, codecs y el número de encodings negociados.
  /// No inventar encodings: WebRTC rechaza cambiar su estructura con setParameters.
  static bool constrain(RTCRtpParameters parameters) {
    final encodings = parameters.encodings;
    if (encodings == null || encodings.isEmpty) return false;
    final bitrate = mobile ? 500000 : 750000;
    final fps = mobile ? 15 : 24;
    for (final encoding in encodings) {
      if (encoding.maxBitrate == null || encoding.maxBitrate! > bitrate) {
        encoding.maxBitrate = bitrate;
      }
      if (encoding.maxFramerate == null || encoding.maxFramerate! > fps) {
        encoding.maxFramerate = fps;
      }
    }
    return true;
  }

  /// Se ejecuta después de negociar, cuando los encodings ya existen.
  static Future<void> apply(RTCPeerConnection connection) async {
    final senders = await connection.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind != 'video') continue;
      final parameters = sender.parameters;
      if (!constrain(parameters)) continue;
      if (!await sender.setParameters(parameters)) {
        debugPrint('IronLink RTC: la plataforma rechazó el límite de video.');
      }
    }
  }
}
