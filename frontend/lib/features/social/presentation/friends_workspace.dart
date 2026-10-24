import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/presence/live_presence.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/user_avatar.dart';
import '../data/friends_repository.dart';
import '../providers/friends_provider.dart';
import 'block_dialog.dart';
import 'people_search_section.dart';
import '../../../core/notify/iron_notice.dart';
import '../../../core/notify/iron_notify.dart';

const _onlineStates = {'available', 'busy', 'in_call'};

/// Vista de amigos al estilo de Discord: En línea, Todos, Pendientes y
/// Bloqueados, con el ajuste de quién puede enviarte solicitudes.
///
/// [onOpenChat] abre el chat de amistad, que no necesita un nodo en común.
class FriendsWorkspace extends ConsumerStatefulWidget {
  const FriendsWorkspace({
    super.key,
    required this.onOpenChat,
    this.active = true,
  });
  final void Function(Friend friend) onOpenChat;
  final bool active;

  @override
  ConsumerState<FriendsWorkspace> createState() => _FriendsWorkspaceState();
}

class _FriendsWorkspaceState extends ConsumerState<FriendsWorkspace> {
  /// No pide nada al servidor hasta que la vista se abre por primera vez.
  late bool _activated = widget.active;
  final Set<String> _busy = {};

  @override
  void didUpdateWidget(FriendsWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      if (_activated) refreshFriends(ref);
      _activated = true;
    }
  }

  Future<void> _run(String key, Future<void> Function() action) async {
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    try {
      await action();
      refreshFriends(ref);
    } catch (error) {
      if (!mounted) return;
      IronNotify.show(
        IronNotice(
          kind: NoticeKind.error,
          title: error is FriendsException
              ? error.message
              : 'No se pudo completar la acción.',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  FriendsRepository get _repo => ref.read(friendsRepositoryProvider);

  Future<void> _remove(Friend friend) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Eliminar a ${friend.name}'),
        content: const Text(
          '¿Seguro que quieres eliminar a esta persona de tus amigos? '
          'Podrás volver a enviarle una solicitud.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar amigo'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(friend.id, () => _repo.remove(friend.id));
    }
  }

  Future<void> _block(String userId, String name) async {
    if (!await confirmBlock(context, name) || !mounted) return;
    await _run(userId, () => _repo.block(userId));
  }

  Future<void> _addFriend() => showDialog<void>(
    context: context,
    builder: (_) => const AddFriendDialog(),
  );

  Future<void> _privacy() => showDialog<void>(
    context: context,
    builder: (_) => const RequestPrivacyDialog(),
  );

  void _profile(Friend friend) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (sheet) => FriendProfileSheet(
      friend: friend,
      onOpenChat: () {
        Navigator.pop(sheet);
        widget.onOpenChat(friend);
      },
      onRemove: () {
        Navigator.pop(sheet);
        _remove(friend);
      },
      onBlock: () {
        Navigator.pop(sheet);
        _block(friend.id, friend.name);
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_activated) return const SizedBox.shrink();
    final requests = ref.watch(friendRequestsProvider);
    final received = requests.valueOrNull?.received.length ?? 0;
    return DefaultTabController(
      length: 4,
      child: Material(
        color: AppColors.bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 4),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.people_alt_outlined, color: AppColors.accent),
                      const SizedBox(width: 10),
                      const Text(
                        'Amigos',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  // Wrap: a 390 px con texto al 130 % el botón baja de línea
                  // en vez de desbordar.
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Actualizar',
                        onPressed: () => refreshFriends(ref),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                      IconButton(
                        tooltip: 'Privacidad de solicitudes',
                        onPressed: _privacy,
                        icon: const Icon(Icons.shield_outlined),
                      ),
                      FilledButton.icon(
                        onPressed: _addFriend,
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: const Text('Agregar amigo'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Pestañas fijas: a 390 px y texto al 130 % las cuatro siguen
            // visibles (la etiqueta se reduce en vez de desbordar).
            TabBar(
              labelPadding: const EdgeInsets.symmetric(horizontal: 8),
              labelColor: AppColors.accent,
              unselectedLabelColor: AppColors.textMuted,
              indicatorColor: AppColors.accent,
              dividerColor: AppColors.line,
              tabs: [
                const Tab(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('En línea'),
                  ),
                ),
                const Tab(
                  child: FittedBox(fit: BoxFit.scaleDown, child: Text('Todos')),
                ),
                Tab(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Pendientes'),
                        if (received > 0) ...[
                          const SizedBox(width: 6),
                          Badge(
                            label: Text('$received'),
                            backgroundColor: AppColors.error,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const Tab(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('Bloqueados'),
                  ),
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _friendsTab(onlineOnly: true),
                  _friendsTab(onlineOnly: false),
                  _pendingTab(requests),
                  _blockedTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _error(String message) => _Empty(
    icon: Icons.cloud_off_rounded,
    title: 'No se pudo cargar',
    description: message,
    action: OutlinedButton(
      onPressed: () => refreshFriends(ref),
      child: const Text('Reintentar'),
    ),
  );

  Widget _friendsTab({required bool onlineOnly}) {
    final friends = ref.watch(friendsListProvider);
    return friends.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _error(
        error is FriendsException
            ? error.message
            : 'Comprueba tu conexión y vuelve a intentarlo.',
      ),
      data: (all) => ValueListenableBuilder<Map<String, String>>(
        valueListenable: LivePresence.values,
        builder: (context, states, _) {
          final rows = onlineOnly
              ? all.where((f) => _onlineStates.contains(states[f.id])).toList()
              : all;
          if (rows.isEmpty) {
            return _Empty(
              icon: Icons.people_outline_rounded,
              title: onlineOnly
                  ? 'Nadie en línea por ahora'
                  : 'Aún no tienes amigos',
              description: onlineOnly
                  ? 'Cuando tus amigos se conecten aparecerán aquí.'
                  : 'Busca a alguien por su nombre o por su correo completo '
                        'y envíale una solicitud.',
              action: onlineOnly
                  ? null
                  : OutlinedButton.icon(
                      onPressed: _addFriend,
                      icon: const Icon(Icons.person_add_alt_1_rounded),
                      label: const Text('Agregar amigo'),
                    ),
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              _SectionLabel(
                '${onlineOnly ? 'En línea' : 'Todos tus amigos'} — ${rows.length}',
              ),
              for (final friend in rows)
                _FriendTile(
                  friend: friend,
                  busy: _busy.contains(friend.id),
                  presence: states[friend.id],
                  onTap: () => _profile(friend),
                  onOpenChat: () => widget.onOpenChat(friend),
                  onRemove: () => _remove(friend),
                  onBlock: () => _block(friend.id, friend.name),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _pendingTab(AsyncValue<FriendRequests> requests) => requests.when(
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (error, _) => _error(
      error is FriendsException
          ? error.message
          : 'Comprueba tu conexión y vuelve a intentarlo.',
    ),
    data: (data) {
      if (data.isEmpty) {
        return const _Empty(
          icon: Icons.mark_email_read_outlined,
          title: 'No hay solicitudes pendientes',
          description:
              'Las solicitudes que recibas o envíes aparecerán aquí hasta que se respondan.',
        );
      }
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          if (data.received.isNotEmpty) ...[
            _SectionLabel('Recibidas — ${data.received.length}'),
            for (final r in data.received)
              _RequestTile(
                request: r,
                busy: _busy.contains(r.id),
                actions: [
                  _RoundAction(
                    tooltip: 'Aceptar solicitud de ${r.name}',
                    icon: Icons.check_rounded,
                    color: AppColors.success,
                    onPressed: () => _run(r.id, () => _repo.accept(r.id)),
                  ),
                  _RoundAction(
                    tooltip: 'Rechazar solicitud de ${r.name}',
                    icon: Icons.close_rounded,
                    color: AppColors.errorText,
                    onPressed: () => _run(r.id, () => _repo.reject(r.id)),
                  ),
                ],
              ),
          ],
          if (data.sent.isNotEmpty) ...[
            _SectionLabel('Enviadas — ${data.sent.length}'),
            for (final r in data.sent)
              _RequestTile(
                request: r,
                busy: _busy.contains(r.id),
                actions: [
                  _RoundAction(
                    tooltip: 'Cancelar solicitud a ${r.name}',
                    icon: Icons.close_rounded,
                    color: AppColors.errorText,
                    onPressed: () => _run(r.id, () => _repo.cancel(r.id)),
                  ),
                ],
              ),
          ],
        ],
      );
    },
  );
}

extension on _FriendsWorkspaceState {
  Widget _blockedTab() => ref
      .watch(blockedUsersProvider)
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _error(
          error is FriendsException
              ? error.message
              : 'Comprueba tu conexión y vuelve a intentarlo.',
        ),
        data: (blocked) => blocked.isEmpty
            ? const _Empty(
                icon: Icons.block_rounded,
                title: 'No has bloqueado a nadie',
                description:
                    'Las personas que bloquees no podrán encontrarte, '
                    'enviarte solicitudes ni escribirte.',
              )
            : ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                children: [
                  _SectionLabel('Bloqueados — ${blocked.length}'),
                  for (final user in blocked)
                    _Row(
                      leading: UserAvatar(
                        userId: user.id,
                        name: user.name,
                        avatarUrl: user.avatarUrl,
                        avatarColor: user.avatarColor,
                        size: 38,
                      ),
                      title: user.name,
                      subtitle: 'Bloqueada',
                      trailing: _busy.contains(user.id)
                          ? const Padding(
                              padding: EdgeInsets.all(10),
                              child: SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : TextButton(
                              onPressed: () =>
                                  _run(user.id, () => _repo.unblock(user.id)),
                              child: const Text('Desbloquear'),
                            ),
                    ),
                ],
              ),
      );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: AppColors.textMuted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: .6,
      ),
    ),
  );
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });
  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: AppColors.surface2,
        foregroundColor: color,
        minimumSize: const Size(40, 40),
      ),
      icon: Icon(icon, size: 20),
    ),
  );
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({
    required this.request,
    required this.actions,
    this.busy = false,
  });
  final FriendRequest request;
  final List<Widget> actions;
  final bool busy;
  @override
  Widget build(BuildContext context) => _Row(
    leading: UserAvatar(
      userId: request.userId,
      name: request.name,
      avatarUrl: request.avatarUrl,
      avatarColor: request.avatarColor,
      size: 38,
    ),
    title: request.name,
    subtitle: request.outgoing
        ? 'Solicitud de amistad enviada'
        : 'Solicitud de amistad recibida',
    trailing: busy
        ? const Padding(
            padding: EdgeInsets.all(10),
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : Row(mainAxisSize: MainAxisSize.min, children: actions),
  );
}

class _FriendTile extends StatelessWidget {
  const _FriendTile({
    required this.friend,
    required this.presence,
    required this.onTap,
    required this.onOpenChat,
    required this.onRemove,
    required this.onBlock,
    this.busy = false,
  });
  final Friend friend;
  final String? presence;
  final VoidCallback onTap, onRemove, onBlock, onOpenChat;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    // El chat de amistad no depende de compartir un nodo.
    final Widget chat = IconButton(
      tooltip: 'Enviar mensaje a ${friend.name}',
      onPressed: onOpenChat,
      icon: const Icon(Icons.chat_bubble_outline_rounded),
    );
    return _Row(
      onTap: onTap,
      leading: UserAvatar(
        userId: friend.id,
        name: friend.name,
        avatarUrl: friend.avatarUrl,
        avatarColor: friend.avatarColor,
        size: 38,
      ),
      title: friend.name,
      subtitle: LivePresence.label(presence),
      subtitleColor: LivePresence.color(presence),
      trailing: busy
          ? const Padding(
              padding: EdgeInsets.all(10),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                chat,
                PopupMenuButton<String>(
                  tooltip: 'Más opciones',
                  onSelected: (value) => switch (value) {
                    'perfil' => onTap(),
                    'bloquear' => onBlock(),
                    _ => onRemove(),
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'perfil',
                      child: Text('Ver perfil'),
                    ),
                    PopupMenuItem(
                      value: 'eliminar',
                      child: Text(
                        'Eliminar amigo',
                        style: TextStyle(color: AppColors.errorText),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'bloquear',
                      child: Text(
                        'Bloquear',
                        style: TextStyle(color: AppColors.errorText),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

/// Fila base con separación superior, como en la lista de Discord.
class _Row extends StatelessWidget {
  const _Row({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.subtitleColor,
    this.onTap,
  });
  final Widget leading, trailing;
  final String title, subtitle;
  final Color? subtitleColor;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: AppColors.line)),
    ),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: subtitleColor ?? AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });
  final IconData icon;
  final String title, description;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.textMuted),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, height: 1.5),
            ),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    ),
  );
}

/// Perfil de un amigo: presencia, chat de amistad, nodos en común y las
/// acciones de eliminar o bloquear.
class FriendProfileSheet extends StatelessWidget {
  const FriendProfileSheet({
    super.key,
    required this.friend,
    required this.onOpenChat,
    required this.onRemove,
    required this.onBlock,
  });
  final Friend friend;
  final VoidCallback onOpenChat, onRemove, onBlock;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .8,
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        children: [
          Row(
            children: [
              UserAvatar(
                userId: friend.id,
                name: friend.name,
                avatarUrl: friend.avatarUrl,
                avatarColor: friend.avatarColor,
                size: 64,
                viewable: true,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      friend.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    LivePresenceLabel(userId: friend.id),
                    if (friend.statusText?.trim().isNotEmpty == true)
                      Text(
                        friend.statusText!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onOpenChat,
            icon: const Icon(Icons.chat_bubble_outline_rounded),
            label: const Text('Enviar mensaje'),
          ),
          const SizedBox(height: 16),
          Text(
            'NODOS EN COMÚN',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: .6,
            ),
          ),
          const SizedBox(height: 4),
          if (friend.sharedNodes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No comparten ningún nodo. Pueden chatear igualmente como '
                'amigos.',
                style: TextStyle(color: AppColors.textMuted, height: 1.4),
              ),
            )
          else
            for (final node in friend.sharedNodes)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.hexagon_outlined),
                title: Text(node.name),
              ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.errorText,
                ),
                onPressed: onRemove,
                icon: const Icon(Icons.person_remove_outlined),
                label: const Text('Eliminar amigo'),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.errorText,
                ),
                onPressed: onBlock,
                icon: const Icon(Icons.block_rounded),
                label: const Text('Bloquear'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Ajuste «Quién puede enviarte solicitudes».
class RequestPrivacyDialog extends ConsumerStatefulWidget {
  const RequestPrivacyDialog({super.key});
  @override
  ConsumerState<RequestPrivacyDialog> createState() =>
      _RequestPrivacyDialogState();
}

class _RequestPrivacyDialogState extends ConsumerState<RequestPrivacyDialog> {
  bool _saving = false;
  String? _error;

  Future<void> _save(RequestPrivacy value) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(friendsRepositoryProvider).setPrivacy(value);
      ref.invalidate(requestPrivacyProvider);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FriendsException
              ? error.message
              : 'No se pudo guardar el ajuste.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(requestPrivacyProvider);
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Quién puede enviarte solicitudes'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: current.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => Text(
              error is FriendsException
                  ? error.message
                  : 'No se pudo cargar el ajuste.',
              style: TextStyle(color: AppColors.errorText),
            ),
            data: (value) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final option in RequestPrivacy.values)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    enabled: !_saving,
                    selected: option == value,
                    selectedColor: AppColors.accent,
                    onTap: option == value ? null : () => _save(option),
                    leading: Icon(
                      option == value
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                    ),
                    title: Text(option.label),
                    subtitle: Text(
                      option.description,
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  'Las solicitudes que ya recibiste siguen pendientes. Quien '
                  'no pueda enviarte una no sabrá por qué.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: AppColors.errorText)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}

/// Diálogo «Agregar amigo»: busca personas por nombre o correo.
class AddFriendDialog extends StatefulWidget {
  const AddFriendDialog({super.key});
  @override
  State<AddFriendDialog> createState() => _AddFriendDialogState();
}

class _AddFriendDialogState extends State<AddFriendDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: AppColors.surface,
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Agregar amigo',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Busca por nombre o por correo electrónico completo.',
              style: TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Nombre o correo completo',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: PeopleSearchSection(query: _controller.text),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cerrar'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
