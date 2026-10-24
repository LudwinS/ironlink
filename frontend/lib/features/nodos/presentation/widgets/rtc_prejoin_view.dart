import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../../core/theme/app_colors.dart';
import '../../data/rtc_prejoin.dart';

/// Sala de espera antes de entrar a una llamada, al estilo del «lobby» de
/// Teams: vista previa de la cámara, interruptores de cámara y micrófono,
/// elección de dispositivos y los botones «Unirse ahora» y «Cancelar».
class RtcPrejoinView extends StatefulWidget {
  const RtcPrejoinView({
    super.key,
    required this.prejoin,
    required this.title,
    required this.userName,
    required this.onJoin,
    required this.onCancel,
  });

  final RtcPrejoin prejoin;
  final String title;
  final String? userName;
  final VoidCallback onJoin;
  final VoidCallback onCancel;

  @override
  State<RtcPrejoinView> createState() => _RtcPrejoinViewState();
}

class _RtcPrejoinViewState extends State<RtcPrejoinView> {
  RTCVideoRenderer? _renderer;
  bool _rendererRequested = false;
  bool _disposed = false;

  RtcPrejoin get prejoin => widget.prejoin;

  @override
  void initState() {
    super.initState();
    prejoin.addListener(_syncRenderer);
    _syncRenderer();
  }

  /// Crea el renderizador solo cuando hay cámara y le asigna el stream actual.
  void _syncRenderer() {
    if (_disposed) return;
    final stream = prejoin.stream;
    if (stream != null && prejoin.cameraAvailable && !_rendererRequested) {
      _rendererRequested = true;
      unawaited(
        prejoin.media.createRenderer().then((renderer) {
          if (renderer == null) return;
          if (_disposed) {
            unawaited(renderer.dispose());
            return;
          }
          setState(() => _renderer = renderer);
          _syncRenderer();
        }),
      );
    }
    final renderer = _renderer;
    if (renderer != null && !identical(renderer.srcObject, stream)) {
      renderer.srcObject = stream;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    prejoin.removeListener(_syncRenderer);
    final renderer = _renderer;
    if (renderer != null) {
      // El stream no se detiene aquí: o lo usa la llamada o lo libera el lobby.
      renderer.srcObject = null;
      unawaited(renderer.dispose());
    }
    super.dispose();
  }

  String get _initials {
    final words = (widget.userName ?? '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    return words.take(2).map((w) => w.characters.first.toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: prejoin,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          final preview = _preview();
          final panel = _panel();
          return SingleChildScrollView(
            padding: EdgeInsets.all(wide ? 32 : 16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      key: const Key('prejoin-title'),
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: AppColors.text,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Elige cómo quieres entrar a la reunión.',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 20),
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: preview),
                          const SizedBox(width: 24),
                          SizedBox(width: 340, child: panel),
                        ],
                      )
                    else ...[
                      preview,
                      const SizedBox(height: 16),
                      panel,
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _preview() {
    final renderer = _renderer;
    final showVideo =
        renderer != null &&
        prejoin.cameraEnabled &&
        renderer.srcObject != null &&
        !prejoin.busy;
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showVideo)
              RTCVideoView(
                renderer,
                mirror: true,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              )
            else
              _placeholder(),
            Positioned(
              left: 12,
              bottom: 12,
              right: 12,
              child: Align(
                alignment: Alignment.centerLeft,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!prejoin.microphoneEnabled)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.mic_off,
                              color: Colors.redAccent,
                              size: 17,
                            ),
                          ),
                        Flexible(
                          child: Text(
                            '${widget.userName ?? 'Tú'} (Tú)',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    final String message;
    if (prejoin.loading || prejoin.busy) {
      message = 'Preparando la cámara…';
    } else if (!prejoin.cameraAvailable) {
      message = 'Cámara no disponible';
    } else {
      message = 'La cámara está apagada';
    }
    final initials = _initials;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (prejoin.loading || prejoin.busy)
              CircularProgressIndicator(color: AppColors.accent)
            else
              CircleAvatar(
                radius: 40,
                backgroundColor: AppColors.accentTint,
                foregroundColor: AppColors.accentText,
                child: initials.isEmpty
                    ? const Icon(Icons.person, size: 40)
                    : Text(
                        initials,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panel() {
    final notice = prejoin.notice;
    final ready = !prejoin.loading && !prejoin.busy;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toggle(
            key: const Key('prejoin-camera'),
            icon: prejoin.cameraEnabled ? Icons.videocam : Icons.videocam_off,
            label: 'Cámara',
            detail: !prejoin.cameraAvailable && !prejoin.loading
                ? 'No disponible'
                : prejoin.cameraEnabled
                ? 'Encendida'
                : 'Apagada',
            value: prejoin.cameraEnabled,
            onChanged: ready && prejoin.cameraAvailable
                ? (_) => prejoin.toggleCamera()
                : null,
          ),
          _toggle(
            key: const Key('prejoin-microphone'),
            icon: prejoin.microphoneEnabled ? Icons.mic : Icons.mic_off,
            label: 'Micrófono',
            detail: !prejoin.microphoneAvailable && !prejoin.loading
                ? 'No disponible'
                : prejoin.microphoneEnabled
                ? 'Activado'
                : 'Silenciado',
            value: prejoin.microphoneEnabled,
            onChanged: ready && prejoin.microphoneAvailable
                ? (_) => prejoin.toggleMicrophone()
                : null,
          ),
          if (prejoin.cameras.length > 1 && prejoin.cameraAvailable)
            _dropdown(
              label: 'Cámara',
              value: prejoin.cameraId,
              items: {
                for (final camera in prejoin.cameras)
                  camera.deviceId: camera.label.isEmpty
                      ? 'Cámara'
                      : camera.label,
              },
              hint: 'Cámara actual del sistema',
              onChanged: prejoin.canSelectCamera
                  ? (id) => unawaited(prejoin.selectCamera(id))
                  : null,
            ),
          if (prejoin.canSelectAudio)
            AnimatedBuilder(
              animation: prejoin.audioDevices,
              builder: (context, _) {
                final audio = prejoin.audioDevices;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final kind in ['audioinput', 'audiooutput'])
                      _dropdown(
                        label: kind == 'audioinput'
                            ? 'Micrófono'
                            : 'Altavoces o audífonos',
                        value: kind == 'audioinput'
                            ? audio.inputId
                            : audio.outputId,
                        items: {
                          for (final device in audio.ofKind(kind))
                            device.deviceId: device.label.isEmpty
                                ? 'Dispositivo de audio'
                                : device.label,
                        },
                        hint: audio.ofKind(kind).isEmpty
                            ? 'Sin dispositivos disponibles'
                            : 'Dispositivo actual del sistema',
                        onChanged: audio.busy
                            ? null
                            : (id) => unawaited(audio.select(kind, id)),
                      ),
                    if (audio.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          audio.error!,
                          style: TextStyle(color: AppColors.errorText),
                        ),
                      ),
                  ],
                );
              },
            ),
          if (notice != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Container(
                key: const Key('prejoin-notice'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.line),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, color: AppColors.warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        notice,
                        style: TextStyle(color: AppColors.text),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('prejoin-join'),
            onPressed: ready ? widget.onJoin : null,
            icon: const Icon(Icons.login),
            label: const Text('Unirse ahora'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('prejoin-cancel'),
            onPressed: widget.onCancel,
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
  }

  Widget _toggle({
    required Key key,
    required IconData icon,
    required String label,
    required String detail,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, color: value ? AppColors.accent : AppColors.textMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(color: AppColors.text)),
                  Text(
                    detail,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                  ),
                ],
              ),
            ),
            Switch(key: key, value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }

  Widget _dropdown({
    required String label,
    required String? value,
    required Map<String, String> items,
    required String hint,
    required ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: AppColors.textMuted)),
          DropdownButton<String>(
            isExpanded: true,
            value: items.containsKey(value) ? value : null,
            hint: Text(hint, overflow: TextOverflow.ellipsis),
            items: [
              for (final entry in items.entries)
                DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: onChanged == null
                ? null
                : (id) {
                    if (id != null) onChanged(id);
                  },
          ),
        ],
      ),
    );
  }
}
