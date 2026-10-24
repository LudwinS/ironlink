import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Native audio routing does not replace media tracks or modify mute/camera.
class RtcAudioDevices extends ChangeNotifier {
  RtcAudioDevices({
    required this.enumerate,
    required this.selectInput,
    required this.selectOutput,
  });
  final Future<List<MediaDeviceInfo>> Function() enumerate;
  final Future<void> Function(String) selectInput, selectOutput;
  List<MediaDeviceInfo> devices = [];
  String? inputId, outputId, error;
  bool busy = false, _closed = false;
  List<MediaDeviceInfo> ofKind(String kind) =>
      devices.where((d) => d.kind == kind).toList();

  Future<void> refresh() async {
    if (_closed || busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final found = await enumerate();
      if (_closed) return;
      final keys = <String>{};
      devices = found
          .where(
            (d) =>
                {'audioinput', 'audiooutput'}.contains(d.kind) &&
                d.deviceId.isNotEmpty &&
                keys.add('${d.kind}:${d.deviceId}'),
          )
          .toList();
      if (!ofKind('audioinput').any((d) => d.deviceId == inputId)) {
        inputId = null;
      }
      if (!ofKind('audiooutput').any((d) => d.deviceId == outputId)) {
        outputId = null;
      }
    } catch (_) {
      if (!_closed) error = 'No se pudieron listar los dispositivos de audio.';
    } finally {
      busy = false;
      if (!_closed) notifyListeners();
    }
  }

  Future<void> select(String kind, String id) async {
    if (_closed || busy || !ofKind(kind).any((d) => d.deviceId == id)) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await (kind == 'audioinput' ? selectInput(id) : selectOutput(id));
      if (_closed) return;
      if (kind == 'audioinput') {
        inputId = id;
      } else {
        outputId = id;
      }
    } catch (_) {
      if (!_closed) {
        error =
            'No se pudo cambiar el dispositivo. Puede haberse desconectado; actualiza la lista.';
      }
    } finally {
      busy = false;
      if (!_closed) notifyListeners();
    }
  }

  void close() {
    _closed = true;
  }
}
