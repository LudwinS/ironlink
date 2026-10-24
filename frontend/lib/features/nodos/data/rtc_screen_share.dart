import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Serializes capture/track replacement with joining peers. The camera and its
/// enabled state remain owned by the call, never by the display stream.
class RtcScreenShare {
  RtcScreenShare({
    required this.cameraTrack,
    required this.replaceTrack,
    required this.onChanged,
    required this.onRestoreFailure,
  });

  final MediaStreamTrack? Function() cameraTrack;
  final Future<void> Function(MediaStreamTrack? track) replaceTrack;
  final void Function() onChanged;
  final void Function() onRestoreFailure;
  Future<void> _pending = Future<void>.value();
  MediaStream? _stream;
  bool _closed = false;

  MediaStream? get stream => _stream;
  bool get active => _stream != null;
  MediaStreamTrack? get videoTrack =>
      active ? _stream!.getVideoTracks().first : cameraTrack();

  Future<T> serialized<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> start(
    Future<MediaStream> Function() capture, {
    bool Function()? canPublish,
  }) => serialized(() async {
    if (_closed || active || canPublish?.call() == false) return;
    final candidate = await capture();
    if (_closed || canPublish?.call() == false) {
      await _release(candidate);
      return;
    }
    final tracks = candidate.getVideoTracks();
    if (tracks.length != 1) {
      await _release(candidate);
      throw StateError('Expected one display video track');
    }
    var ended = false;
    tracks.first.onEnded = () {
      ended = true;
      unawaited(stop());
    };
    try {
      await replaceTrack(tracks.first);
      if (_closed || ended || canPublish?.call() == false) {
        throw StateError('Capture ended during replacement');
      }
      _stream = candidate;
      onChanged();
    } catch (_) {
      if (identical(_stream, candidate)) _stream = null;
      if (!_closed) {
        try {
          await replaceTrack(cameraTrack());
        } catch (_) {
          onRestoreFailure();
        }
      }
      await _release(candidate);
      rethrow;
    }
  });

  Future<void> stop() => serialized(() async {
    final previous = _stream;
    if (previous == null) return;
    _stream = null;
    try {
      if (!_closed) await replaceTrack(cameraTrack());
    } catch (_) {
      // A failed restore must close the call, not leave a hidden display sender.
      onRestoreFailure();
    } finally {
      await _release(previous);
      if (!_closed) onChanged();
    }
  });

  Future<void> close() {
    _closed = true; // Also revokes captures that are still awaiting permission.
    return stop();
  }

  static Future<void> _release(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      track.onEnded = null;
      try {
        await track.stop();
      } catch (_) {}
    }
    try {
      await stream.dispose();
    } catch (_) {}
  }
}
