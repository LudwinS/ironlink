import 'package:flutter/material.dart';
import '../../data/rtc_audio_devices.dart';

class RtcAudioDevicesDialog extends StatelessWidget {
  const RtcAudioDevicesDialog({super.key, required this.devices});
  final RtcAudioDevices devices;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: devices,
    builder: (context, _) => AlertDialog(
      title: const Text('Dispositivos de audio'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Cambiar el dispositivo no activa el micrófono ni modifica la cámara. La ruta de audio se aplica a IronLink en este equipo.',
              ),
              const SizedBox(height: 16),
              for (final kind in ['audioinput', 'audiooutput']) ...[
                Text(
                  kind == 'audioinput' ? 'Micrófono' : 'Altavoces o audífonos',
                ),
                DropdownButton<String>(
                  isExpanded: true,
                  value: kind == 'audioinput'
                      ? devices.inputId
                      : devices.outputId,
                  hint: Text(
                    devices.ofKind(kind).isEmpty
                        ? 'Sin dispositivos disponibles'
                        : 'Dispositivo actual del sistema',
                  ),
                  items: [
                    for (final device in devices.ofKind(kind))
                      DropdownMenuItem(
                        value: device.deviceId,
                        child: Text(
                          device.label.isEmpty
                              ? 'Dispositivo de audio'
                              : device.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: devices.busy
                      ? null
                      : (id) {
                          if (id != null) devices.select(kind, id);
                        },
                ),
              ],
              if (devices.busy) const LinearProgressIndicator(),
              if (devices.error != null)
                Text(
                  devices.error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: devices.busy ? null : devices.refresh,
          child: const Text('Actualizar lista'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ],
    ),
  );
}
