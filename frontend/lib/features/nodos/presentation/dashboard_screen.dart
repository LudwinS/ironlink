import 'dart:async';
import '../../../core/widgets/iron_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notify/iron_notice.dart';
import '../../../core/notify/iron_notify.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/nodos_provider.dart';
import '../data/nodos_repository.dart';
import '../data/live_updates_controller.dart';
import '../data/calendar_repository.dart';
import '../../../core/presence/live_presence.dart';
import 'widgets/calendar_workspace.dart';
import 'widgets/live_updates_banner.dart';
import 'widgets/notifications_panel.dart';
import '../data/notifications_repository.dart';
import 'rtc_call_page.dart';

// Import newly extracted widgets
import 'widgets/workspace_navigation.dart';
import 'widgets/direct_chats_workspace.dart';
import 'widgets/workspace_preferences.dart';
import '../providers/chat_provider.dart';
import 'widgets/nodo_chat_workspace.dart';
import 'widgets/create_nodo_dialog.dart';
import 'widgets/join_nodo_dialog.dart';
import '../../social/data/friends_repository.dart';
import '../../social/presentation/friends_workspace.dart';
import '../../social/presentation/people_search_section.dart';
import '../../social/providers/friends_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Paleta de colores oficial IronLink
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Constantes de layout
// ─────────────────────────────────────────────────────────────────────────────

const double _mobileBreakpoint = 600.0;

// ─────────────────────────────────────────────────────────────────────────────
// Utilidades RBAC
// ─────────────────────────────────────────────────────────────────────────────

// ═════════════════════════════════════════════════════════════════════════════
// DashboardScreen — Pantalla principal
// ═════════════════════════════════════════════════════════════════════════════

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  int _selectedIndex = 0;
  final _search = TextEditingController();
  late final LiveUpdatesController _live;
  bool _joiningLive = false;
  int _calendarRevision = 0;

  Future<void> _joinCalendarMeeting(CalendarMeeting event) async {
    if (_joiningLive ||
        !event.canJoin ||
        LivePresence.values.value[LivePresence.selfId] == 'in_call') {
      return;
    }
    _joiningLive = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              RtcCallPage(reunion: event.reunion, canEnd: event.canModerate),
        ),
      );
    } finally {
      _joiningLive = false;
      if (mounted) setState(() => _calendarRevision++);
    }
  }

  Future<void> _joinLiveMeeting(LiveMeeting meeting) async {
    if (_joiningLive || !_live.connected) return;
    _joiningLive = true;
    final node = ref
        .read(nodosProvider)
        .nodos
        .where((n) => n.id == meeting.nodeId)
        .firstOrNull;
    final canEnd =
        meeting.creatorId == _live.userId ||
        node?.creadorId == _live.userId ||
        {'ADMIN', 'MODERATOR'}.contains(node?.rol);
    _live.dismiss(meeting.id);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              RtcCallPage(reunion: meeting.toReunion(), canEnd: canEnd),
        ),
      );
    } finally {
      _joiningLive = false;
      if (mounted) setState(() => _calendarRevision++);
    }
  }

  StreamSubscription<void>? _arrivals;

  /// IRL-NTF-US-01: al llegar un recordatorio se anuncia con su texto.
  Future<void> _announceNotification() async {
    String text = 'Tienes una notificación nueva.';
    try {
      final today = await NotificationsRepository().today();
      if (today.isNotEmpty) text = today.first.message;
    } catch (_) {
      /* Sin detalle, el aviso genérico sigue siendo útil. */
    }
    if (!mounted) return;
    IronNotify.show(
      IronNotice(
        kind: NoticeKind.reminder,
        title: text,
        actions: [NoticeAction('Ver', _openNotifications, primary: true)],
      ),
    );
  }

  /// Avisos en vivo: una reunión que empieza, una solicitud de amistad o un
  /// mensaje de amistad nuevo. La primera instantánea solo fija el punto de
  /// partida, para no anunciar lo que ya existía; sin conexión no se compara
  /// (la lista vacía de una desconexión no cuenta como cambio).
  Set<String>? _knownMeetings;
  int? _knownRequests;
  int? _knownUnread;
  void _announceLive() {
    if (!_live.connected) return;
    final meetings = _live.meetings;
    final known = _knownMeetings;
    _knownMeetings = {for (final m in meetings) m.id};
    if (known != null) {
      final nodos = ref.read(nodosProvider).nodos;
      for (final meeting in meetings) {
        if (known.contains(meeting.id) || meeting.creatorId == _live.userId) {
          continue;
        }
        final node = nodos.where((n) => n.id == meeting.nodeId).firstOrNull;
        IronNotify.show(
          IronNotice(
            id: 'meeting-${meeting.id}',
            kind: NoticeKind.meeting,
            context: node == null
                ? 'Reunión en curso'
                : 'Reunión en curso · ${node.nombre}',
            title: '${meeting.creatorName} inició ${meeting.title}',
            initials: _initials(meeting.creatorName),
            actions: [
              NoticeAction('Ignorar', () => _live.dismiss(meeting.id)),
              NoticeAction(
                'Unirse',
                () => unawaited(_joinLiveMeeting(meeting)),
                primary: true,
              ),
            ],
          ),
        );
      }
    }
    final requests = _live.pendingFriendRequests;
    if (_knownRequests != null && requests > _knownRequests!) {
      IronNotify.show(
        IronNotice(
          id: 'friend-requests-$requests',
          kind: NoticeKind.friendRequest,
          title: requests == 1
              ? 'Tienes una solicitud de amistad'
              : 'Tienes $requests solicitudes de amistad',
          actions: [
            NoticeAction(
              'Ver',
              () => _handleNavSelect(WorkspaceDestination.amigos.index),
              primary: true,
            ),
          ],
        ),
      );
    }
    _knownRequests = requests;
    final unread = _live.unreadFriendMessages;
    final inChats = _selectedIndex == WorkspaceDestination.chats.index;
    if (_knownUnread != null && unread > _knownUnread! && !inChats) {
      IronNotify.show(
        IronNotice(
          id: 'dm-$unread',
          kind: NoticeKind.message,
          title: 'Nuevo mensaje de un amigo',
          subtitle: unread == 1 ? null : '$unread mensajes sin leer',
          actions: [
            NoticeAction(
              'Abrir',
              () => _handleNavSelect(WorkspaceDestination.chats.index),
              primary: true,
            ),
          ],
        ),
      );
    }
    _knownUnread = unread;
  }

  static String _initials(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    return words.take(2).map((w) => w[0].toUpperCase()).join();
  }

  Future<void> _openNotifications() => showNotificationsPanel(context);

  Widget _bell() => AnimatedBuilder(
    animation: _live,
    builder: (context, _) => NotificationsBell(
      unread: _live.unreadNotifications,
      onPressed: _openNotifications,
    ),
  );

  /// En móvil no hay cabecera de escritorio: barra mínima con la campana.
  Widget _mobileHeader() => Container(
    height: 48,
    padding: const EdgeInsets.only(left: 16, right: 4),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: AppColors.line)),
    ),
    child: Row(
      children: [
        const IronLogo.mark(size: 22),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'IronLink',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        _bell(),
      ],
    ),
  );

  /// Contador de solicitudes y lista de presencia: si cambian (alguien envió,
  /// aceptó o eliminó una amistad) se vuelven a pedir amigos y solicitudes.
  /// Si cambian los mensajes de amistad sin leer, se refresca la bandeja.
  String _friendsSignature = '';
  int? _friendUnread;
  void _onLiveChanged() {
    _announceLive();
    final unread = _live.unreadFriendMessages;
    if (_friendUnread != null && unread != _friendUnread && mounted) {
      ref.invalidate(directContactsProvider);
    }
    _friendUnread = unread;
    final keys = LivePresence.values.value.keys.toList()..sort();
    final signature =
        '${_live.pendingFriendRequests}|${_live.acceptedFriends}|'
        '${_live.sentFriendRequests}|${keys.join(',')}';
    if (signature == _friendsSignature) return;
    final first = _friendsSignature.isEmpty;
    _friendsSignature = signature;
    if (!first && mounted) refreshFriends(ref);
  }

  /// Abre (o crea bajo demanda) el chat de amistad: no necesita un nodo.
  void _openFriendChat(Friend friend) {
    ref
        .read(directChatRequestProvider.notifier)
        .state = DirectChatTarget.friend(
      userId: friend.id,
      name: friend.name,
      avatarUrl: friend.avatarUrl,
      avatarColor: friend.avatarColor,
    );
    _handleNavSelect(WorkspaceDestination.chats.index);
  }

  @override
  void dispose() {
    _live.removeListener(_onLiveChanged);
    _arrivals?.cancel();
    _live.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _live = LiveUpdatesController()..addListener(_onLiveChanged);
    _arrivals = _live.notificationArrivals.listen(
      (_) => unawaited(_announceNotification()),
    );
    unawaited(_live.start());
    // Carga inicial de nodos al entrar al dashboard y arranque del polling
    Future.microtask(() {
      ref.read(workspaceNodeVisibleProvider.notifier).state = false;
      ref.read(nodosProvider.notifier).loadNodos();
      ref.read(nodosProvider.notifier).startPolling();
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < _mobileBreakpoint;
    final role = ref.watch(userRoleProvider);

    final nodos = ref.watch(nodosProvider).nodos;
    final selected = ref.watch(selectedNodoProvider);
    final prefs = ref.watch(workspacePreferencesProvider);
    final media = MediaQuery.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _openSearch,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _openSearch,
        for (var i = 0; i < workspaceLabels.length; i++)
          SingleActivator(
            [
              LogicalKeyboardKey.digit1,
              LogicalKeyboardKey.digit2,
              LogicalKeyboardKey.digit3,
              LogicalKeyboardKey.digit4,
              LogicalKeyboardKey.digit5,
              LogicalKeyboardKey.digit6,
            ][i],
            alt: true,
          ): () =>
              _handleNavSelect(i),
      },
      child: Focus(
        autofocus: true,
        child: MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(
              media.textScaler.scale(1) * prefs.scale,
            ),
            disableAnimations: media.disableAnimations || prefs.reduceMotion,
          ),
          child: Scaffold(
            backgroundColor: AppColors.bg,
            bottomNavigationBar: isMobile
                ? AnimatedBuilder(
                    animation: _live,
                    builder: (context, _) => NavigationBar(
                      selectedIndex: workspaceNavOrder.indexOf(_selectedIndex),
                      onDestinationSelected: (i) =>
                          _handleNavSelect(workspaceNavOrder[i]),
                      backgroundColor: AppColors.surface,
                      indicatorColor: AppColors.accentDeep,
                      destinations: [
                        for (final i in workspaceNavOrder)
                          NavigationDestination(
                            icon: i == 3
                                ? ProfileNavIcon(
                                    size: 26,
                                    selected: _selectedIndex == 3,
                                  )
                                : workspaceNavIcon(
                                    i,
                                    pendingFriends: _live.pendingFriendRequests,
                                    unreadChats: _live.unreadFriendMessages,
                                  ),
                            label: workspaceLabels[i],
                            tooltip: workspaceLabels[i],
                          ),
                      ],
                    ),
                  )
                : null,
            body: Row(
              children: [
                if (!isMobile)
                  AnimatedBuilder(
                    animation: _live,
                    builder: (context, _) => WorkspaceNavigation(
                      selected: _selectedIndex,
                      onSelect: _handleNavSelect,
                      nodos: nodos,
                      selectedNodoId: selected?.id,
                      unread: ref.watch(unreadCountsProvider),
                      onOpenNodo: _openNodo,
                      onAddNodo: _addNodo,
                      pendingFriends: _live.pendingFriendRequests,
                      unreadChats: _live.unreadFriendMessages,
                    ),
                  ),
                // Contenido principal
                Expanded(
                  child: Column(
                    children: [
                      if (!isMobile) _header() else _mobileHeader(),
                      LiveUpdatesBanner(live: _live, onJoin: _joinLiveMeeting),
                      if (_selectedIndex == 1)
                        Container(
                          height: 52,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          color: AppColors.surface,
                          child: Row(
                            children: [
                              if (selected != null)
                                IconButton(
                                  tooltip: 'Volver a Nodos',
                                  onPressed: () {
                                    ref
                                            .read(selectedNodoProvider.notifier)
                                            .state =
                                        null;
                                    ref
                                            .read(
                                              selectedSubgrupoProvider.notifier,
                                            )
                                            .state =
                                        null;
                                  },
                                  icon: const Icon(Icons.arrow_back_rounded),
                                ),
                              Expanded(
                                child: Text(
                                  selected?.nombre ?? 'Nodos',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Crear o unirse a un nodo',
                                onPressed: _addNodo,
                                icon: const Icon(Icons.add_rounded),
                              ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: IndexedStack(
                          index: _selectedIndex,
                          children: [
                            DirectChatsWorkspace(
                              nodos: nodos,
                              compact: prefs.compact,
                              active: _selectedIndex == 0,
                            ),
                            _MainContent(
                              role: role,
                              active: _selectedIndex == 1,
                            ),
                            _searchPage(),
                            const WorkspacePersonal(),
                            CalendarWorkspace(
                              nodos: nodos,
                              active: _selectedIndex == 4,
                              revision: _calendarRevision,
                              onJoin: _joinCalendarMeeting,
                            ),
                            FriendsWorkspace(
                              active:
                                  _selectedIndex ==
                                  WorkspaceDestination.amigos.index,
                              onOpenChat: _openFriendChat,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() => Container(
    height: 52,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: AppColors.line)),
    ),
    child: Row(
      children: [
        const IronLogo.mark(size: 24),
        const SizedBox(width: 10),
        const Text(
          'IronLink',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _openSearch,
            icon: const Icon(Icons.search_rounded, size: 18),
            label: const Text(
              'Buscar o ir a una conversación…    ⌘ / Ctrl K',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _bell(),
        IconButton(
          tooltip: 'Tu perfil y ajustes',
          onPressed: () => _handleNavSelect(3),
          icon: const ProfileNavIcon(size: 26),
        ),
      ],
    ),
  );

  void _openSearch() => _handleNavSelect(2);

  void _openNodo(Nodo nodo) {
    ref.read(selectedSubgrupoProvider.notifier).state = null;
    ref.read(selectedNodoProvider.notifier).state = nodo;
    ref.read(nodosProvider.notifier).clearUnreadCount(nodo.id);
    _handleNavSelect(1);
  }

  void _addNodo() => showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: const Text('Crear nodo'),
            onTap: () {
              Navigator.pop(sheetContext);
              _showCreateNodoDialog(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.login_rounded),
            title: const Text('Unirse con código'),
            onTap: () {
              Navigator.pop(sheetContext);
              _showJoinNodoDialog(context);
            },
          ),
        ],
      ),
    ),
  );

  Widget _searchPage() {
    final query = _search.text.trim().toLowerCase();
    final nodos = ref
        .watch(nodosProvider)
        .nodos
        .where((n) => n.nombre.toLowerCase().contains(query));
    final messages = ref
        .watch(chatMessagesProvider)
        .mensajes
        .where((m) => m.contenido.toLowerCase().contains(query));
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Buscar',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search_rounded),
            hintText: 'Personas, nodos y mensajes del canal abierto',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Busca personas por nombre o correo (mínimo 2 caracteres), tus nodos y los mensajes cargados del canal abierto. No incluye archivos ni canales privados ajenos.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 20),
        PeopleSearchSection(query: _search.text),
        for (final nodo in nodos)
          ListTile(
            leading: const Icon(Icons.hexagon_outlined),
            title: Text(nodo.nombre),
            subtitle: Text('${nodo.miembrosCount} integrantes'),
            onTap: () => _openNodo(nodo),
          ),
        if (query.isNotEmpty)
          for (final m in messages)
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline_rounded),
              title: Text(m.contenido),
              subtitle: const Text('Canal abierto'),
              onTap: () => _handleNavSelect(1),
            ),
        if (query.isNotEmpty &&
            query.characters.length < FriendsRepository.minQuery &&
            nodos.isEmpty &&
            messages.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Sin resultados. Prueba con otro término.'),
          ),
      ],
    );
  }

  void _handleNavSelect(int index) {
    ref.read(workspaceNodeVisibleProvider.notifier).state = index == 1;
    setState(() => _selectedIndex = index);
  }

  void _showCreateNodoDialog(BuildContext context) {
    showDialog(context: context, builder: (_) => const CreateNodoDialog());
  }

  void _showJoinNodoDialog(BuildContext context) {
    showDialog(context: context, builder: (_) => const JoinNodoDialog());
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// _MainContent — Área de contenido principal
// ═════════════════════════════════════════════════════════════════════════════

class _MainContent extends ConsumerWidget {
  const _MainContent({required this.role, required this.active});
  final String role;
  final bool active;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(nodosProvider);
    final selected = ref.watch(selectedNodoProvider);
    if (selected != null) {
      return NodoChatWorkspace(
        key: ValueKey(selected.id),
        nodo: selected,
        active: active,
      );
    }
    void open(Nodo nodo) {
      ref.read(selectedSubgrupoProvider.notifier).state = null;
      ref.read(selectedNodoProvider.notifier).state = nodo;
      ref.read(nodosProvider.notifier).clearUnreadCount(nodo.id);
    }

    final unread = ref.watch(unreadCountsProvider);
    final list = Material(
      color: AppColors.surface,
      child: Column(
        children: [
          if (state.status == NodosStatus.error)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    'No se pudieron actualizar los nodos.',
                    style: TextStyle(color: AppColors.errorText),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.read(nodosProvider.notifier).loadNodos(),
                    child: const Text('Reintentar'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: state.status == NodosStatus.loading && state.nodos.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : state.nodos.isEmpty
                ? WorkspaceEmpty(
                    title: 'Tu primer nodo',
                    description:
                        'Crea un espacio para tu equipo o únete con un código.',
                    icon: Icons.hexagon_outlined,
                    action: OutlinedButton(
                      onPressed: () => showDialog(
                        context: context,
                        builder: (_) => const CreateNodoDialog(),
                      ),
                      child: const Text('Crear nodo'),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: () =>
                        ref.read(nodosProvider.notifier).loadNodos(),
                    child: ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        for (final nodo in state.nodos)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Material(
                              color: AppColors.surface2,
                              borderRadius: BorderRadius.circular(12),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                leading: Icon(
                                  Icons.hexagon_outlined,
                                  size: 36,
                                  color: AppColors.textMuted,
                                ),
                                title: Text(
                                  nodo.nombre,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Text(
                                  '${nodo.miembrosCount} integrantes · ${nodo.rol ?? 'MEMBER'}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                                trailing: (unread[nodo.id] ?? 0) > 0
                                    ? Badge(
                                        label: Text('${unread[nodo.id]}'),
                                        backgroundColor: AppColors.accent,
                                        textColor: AppColors.bg,
                                      )
                                    : const Icon(Icons.chevron_right),
                                onTap: () => open(nodo),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (_, size) => size.maxWidth > 800
          ? Row(
              children: [
                SizedBox(width: 280, child: list),
                const VerticalDivider(width: 1),
                const Expanded(
                  child: WorkspaceEmpty(
                    title: 'Un espacio para cada equipo',
                    description:
                        'Abre un nodo para ver sus canales, integrantes y videollamadas.',
                    icon: Icons.hexagon_outlined,
                  ),
                ),
              ],
            )
          : list,
    );
  }
}
