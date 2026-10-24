import 'package:flutter/material.dart';

/// Ephemeral, account-scoped data. Never overwrite the user's custom status.
class LivePresence {
  static final values = ValueNotifier<Map<String, String>>({});
  static String? selfId;
  static String label(String? value) => switch (value) {
    'in_call' => 'En llamada',
    'available' => 'Disponible',
    'busy' => 'Ocupado',
    'offline' => 'Desconectado',
    _ => 'Sin sincronizar',
  };
  static Color color(String? value) => switch (value) {
    'in_call' => Colors.redAccent,
    'available' => Colors.green,
    'busy' => Colors.amber,
    _ => Colors.grey,
  };
  static void clear() {
    selfId = null;
    values.value = {};
  }
}

class LivePresenceLabel extends StatelessWidget {
  const LivePresenceLabel({super.key, required this.userId});
  final String userId;
  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Map<String, String>>(
        valueListenable: LivePresence.values,
        builder: (_, states, _) => Text(
          LivePresence.label(states[userId]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: LivePresence.color(states[userId]),
            fontSize: 12,
          ),
        ),
      );
}
