import 'package:flutter/material.dart';
import '../../data/live_updates_controller.dart';
import '../../../../core/presence/live_presence.dart';

class LiveUpdatesBanner extends StatelessWidget {
  const LiveUpdatesBanner({
    super.key,
    required this.live,
    required this.onJoin,
  });
  final LiveUpdatesController live;
  final void Function(LiveMeeting) onJoin;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: live,
    builder: (context, _) {
      final pending = live.pending;
      final ownState = LivePresence.values.value[live.userId];
      if (live.connected && pending.isEmpty && !live.truncated) {
        return const SizedBox.shrink();
      }
      final actions = <Widget>[
        if (live.connected && pending.isNotEmpty) ...[
          TextButton(
            onPressed: ownState == 'in_call'
                ? null
                : () => onJoin(pending.first),
            child: const Text('Unirse ahora'),
          ),
          if (pending.length > 1)
            PopupMenuButton<LiveMeeting>(
              tooltip: 'Más reuniones activas',
              onSelected: onJoin,
              enabled: ownState != 'in_call',
              itemBuilder: (_) => [
                for (final m in pending)
                  PopupMenuItem(value: m, child: Text(m.title)),
              ],
            ),
        ],
      ];
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: LayoutBuilder(
            builder: (context, size) {
              final narrow = size.maxWidth < 600;
              final header = Row(
                children: [
                  Icon(
                    live.connected
                        ? Icons.video_call_outlined
                        : Icons.sync_problem,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      live.connected
                          ? (pending.isEmpty
                                ? 'Vista en vivo limitada: algunos miembros no están incluidos.'
                                : '${pending.first.title} comenzó${pending.length > 1 ? ' · ${pending.length} reuniones activas' : ''}')
                          : 'Avisos y presencia sin conexión. Reintentando…',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!narrow) ...actions,
                  if (live.connected && pending.isNotEmpty)
                    IconButton(
                      tooltip: 'Descartar aviso',
                      onPressed: () => live.dismiss(pending.first.id),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                ],
              );
              return narrow
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        header,
                        if (actions.isNotEmpty) Wrap(children: actions),
                      ],
                    )
                  : header;
            },
          ),
        ),
      );
    },
  );
}
