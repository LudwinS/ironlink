import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/meeting_link.dart';
import '../../data/notifications_repository.dart';
import 'meeting_link_widgets.dart';

/// Campana con el número de notificaciones sin leer.
class NotificationsBell extends StatelessWidget {
  const NotificationsBell({
    super.key,
    required this.unread,
    required this.onPressed,
  });
  final int unread;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = unread == 0
        ? 'Notificaciones'
        : 'Notificaciones, $unread sin leer';
    return IconButton(
      tooltip: label,
      onPressed: onPressed,
      icon: Badge(
        isLabelVisible: unread > 0,
        backgroundColor: AppColors.accent,
        textColor: AppColors.onAccent,
        label: Text(unread > 99 ? '99+' : '$unread'),
        child: Icon(
          unread > 0
              ? Icons.notifications_active_outlined
              : Icons.notifications_none_rounded,
          semanticLabel: label,
        ),
      ),
    );
  }
}

/// Panel con las notificaciones del día agrupadas por nodo (IRL-NTF-US-03).
Future<void> showNotificationsPanel(
  BuildContext context, {
  NotificationsRepository? repository,
  MeetingLinkRepository? meetings,
}) => showDialog<void>(
  context: context,
  builder: (_) => NotificationsPanel(
    repository: repository ?? NotificationsRepository(),
    meetings: meetings,
  ),
);

class NotificationsPanel extends StatefulWidget {
  const NotificationsPanel({
    super.key,
    required this.repository,
    this.meetings,
  });
  final NotificationsRepository repository;
  final MeetingLinkRepository? meetings;

  @override
  State<NotificationsPanel> createState() => _NotificationsPanelState();
}

class _NotificationsPanelState extends State<NotificationsPanel> {
  List<AppNotification>? _items;
  String? _error;
  bool _unreadOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await widget.repository.today();
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _markAll() async {
    final previous = _items;
    setState(() => _items = [for (final n in previous!) n.markedRead()]);
    try {
      await widget.repository.markAllRead();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items = previous;
        _error = e.toString();
      });
    }
  }

  Future<void> _open(AppNotification item) async {
    if (item.unread) {
      setState(() {
        _items = [
          for (final n in _items!) n.id == item.id ? n.markedRead() : n,
        ];
      });
      // Si falla se reintenta la próxima vez; abrir la reunión no depende de ello.
      widget.repository.markRead([item.id]).ignore();
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(item.kindLabel),
        content: MeetingLinkCard(
          reunionId: item.meetingId,
          repository: widget.meetings,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final unread = items?.where((n) => n.unread).length ?? 0;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 12, 0),
      title: Row(
        children: [
          const Expanded(child: Text('Notificaciones de hoy')),
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterChip(
                  label: Text(
                    unread == 0 ? 'No leídas' : 'No leídas ($unread)',
                  ),
                  selected: _unreadOnly,
                  onSelected: (v) => setState(() => _unreadOnly = v),
                ),
                if (unread > 0)
                  TextButton.icon(
                    onPressed: _markAll,
                    icon: const Icon(Icons.done_all_rounded, size: 18),
                    label: const Text('Marcar todas como leídas'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: AppColors.errorText),
                ),
              ),
            if (items == null && _error == null)
              const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (items != null)
              Flexible(child: _grouped(items)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }

  Widget _grouped(List<AppNotification> all) {
    final shown = _unreadOnly ? all.where((n) => n.unread).toList() : all;
    if (shown.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          _unreadOnly
              ? 'No tienes notificaciones sin leer.'
              : 'Hoy no tienes notificaciones.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textMuted),
        ),
      );
    }
    // Grupos por nodo en el orden de su aviso más reciente; dentro de cada
    // grupo, de más reciente a más antiguo (el servidor ya los ordena así).
    final groups = <String, List<AppNotification>>{};
    for (final n in shown) {
      groups.putIfAbsent(n.nodeId, () => []).add(n);
    }
    return ListView(
      shrinkWrap: true,
      children: [
        for (final group in groups.values) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
            child: Semantics(
              header: true,
              child: Text(
                group.first.nodeName,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          for (final n in group)
            _NotificationTile(item: n, onTap: () => _open(n)),
        ],
      ],
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.item, required this.onTap});
  final AppNotification item;
  final VoidCallback onTap;

  static String ago(DateTime t) {
    final d = DateTime.now().difference(t.toLocal());
    if (d.inMinutes < 1) return 'ahora';
    if (d.inMinutes < 60) return 'hace ${d.inMinutes} min';
    return 'hace ${d.inHours} h';
  }

  @override
  Widget build(BuildContext context) {
    final icon = switch (item.type) {
      'reunion_iniciada' => Icons.videocam_outlined,
      'invitacion' => Icons.event_available_outlined,
      _ => Icons.alarm_rounded,
    };
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      onTap: onTap,
      leading: Icon(
        icon,
        color: item.unread ? AppColors.accentText : AppColors.textMuted,
      ),
      title: Text(
        item.message,
        style: TextStyle(
          color: AppColors.text,
          fontWeight: item.unread ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      subtitle: Text(
        '${item.kindLabel} · ${ago(item.createdAt)}',
        style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
      ),
      trailing: item.unread
          ? Semantics(
              label: 'Sin leer',
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
            )
          : null,
    );
  }
}
