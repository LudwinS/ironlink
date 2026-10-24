import 'dart:async';
import 'package:flutter/material.dart';
import '../../../../core/presence/live_presence.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import 'workspace_preferences.dart';
import '../../../../core/widgets/user_avatar.dart';
import '../../data/nodos_repository.dart';
import '../../data/direct_messages_repository.dart';
import '../../data/subgrupos_repository.dart';
import '../../providers/nodos_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/subgrupos_provider.dart';
import '../../../iam/providers/auth_provider.dart';
import 'nodo_details_dialog.dart';
import 'subgrupos_view.dart';
import 'reuniones_view.dart';
import 'assign_members_dialog.dart';
import 'edit_subgrupo_dialog.dart';
import 'meeting_link_widgets.dart';
import 'direct_messages_dialog.dart';
import '../../../../core/notify/iron_notice.dart';
import '../../../../core/notify/iron_notify.dart';

Color _getStatusColor(String? status) {
  if (status == null || status.isEmpty) return const Color(0xFF10B981);
  final lower = status.toLowerCase();
  if (status.contains('🔴') ||
      lower.contains('ocupado') ||
      lower.contains('no molestar')) {
    return const Color(0xFFEF4444);
  }
  if (status.contains('🟡') ||
      lower.contains('reunión') ||
      lower.contains('reunion') ||
      lower.contains('ausente')) {
    return const Color(0xFFF59E0B);
  }
  if (status.contains('📚') ||
      lower.contains('estudiando') ||
      lower.contains('desarrollando')) {
    return AppColors.accentText;
  }
  return const Color(0xFF10B981);
}

const double _mobileBreakpoint = 1100.0;
final workspaceDraftsProvider = StateProvider<Map<String, String>>((ref) {
  ref.watch(authProvider.select((s) => s.userId));
  return {};
});

class NodoChatWorkspace extends ConsumerStatefulWidget {
  final Nodo nodo;
  final bool active;
  const NodoChatWorkspace({super.key, required this.nodo, this.active = true});

  @override
  ConsumerState<NodoChatWorkspace> createState() => _NodoChatWorkspaceState();
}

class _NodoChatWorkspaceState extends ConsumerState<NodoChatWorkspace> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  List<NodoMiembro> _miembros = [];
  List<SubgrupoMiembro> _subMiembros = [];
  Timer? _membersTimer;
  Timer? _directTimer;
  int _directUnread = 0;
  bool _showMembersSidebar = false;
  bool _sending = false;
  String? _sendError;
  late StateController<Map<String, String>> _draftStore;
  late String _draftKey;
  int _currentTab = 0; // 0: Chat, 1: Subgrupos, 2: Reuniones

  @override
  void initState() {
    super.initState();
    _draftStore = ref.read(workspaceDraftsProvider.notifier);
    _draftKey =
        '${widget.nodo.id}:${ref.read(selectedSubgrupoProvider)?.id ?? 'general'}';
    _msgCtrl.text = _draftStore.state[_draftKey] ?? '';
    _msgCtrl.addListener(() {
      _draftStore.state = {..._draftStore.state, _draftKey: _msgCtrl.text};
    });
    _fetchMiembros();
    unawaited(_refreshDirectUnread());
    _membersTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (widget.active) _fetchMiembros();
    });
    _directTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (widget.active) unawaited(_refreshDirectUnread());
    });
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    _membersTimer?.cancel();
    _directTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchMiembros() async {
    try {
      final repo = ref.read(nodosRepositoryProvider);
      final list = await repo.fetchMiembros(widget.nodo.id);
      if (mounted) {
        setState(() {
          _miembros = list;
        });
      }

      final currentSub = ref.read(selectedSubgrupoProvider);
      if (currentSub != null) {
        try {
          final subRepo = ref.read(subgruposRepositoryProvider);
          final subList = await subRepo.fetchSubgrupoMiembros(
            nodoId: widget.nodo.id,
            subgrupoId: currentSub.id,
          );
          if (mounted) {
            setState(() {
              _subMiembros = subList;
            });
          }
        } catch (_) {}
      }
    } catch (_) {
      // Silencioso
    }
  }

  Future<void> _refreshDirectUnread() async {
    final ownId = ref.read(authProvider).userId;
    if (ownId == null) return;
    try {
      final inbox = await DirectMessagesRepository().inbox(widget.nodo.id);
      final unread = inbox
          .where(
            (message) => message.recipientId == ownId && message.readAt == null,
          )
          .length;
      if (!mounted) return;
      if (unread > _directUnread) {
        final latest = inbox.firstWhere(
          (message) => message.recipientId == ownId && message.readAt == null,
        );
        IronNotify.show(
          IronNotice(
            kind: NoticeKind.message,
            title: latest.kind == 'call_invite'
                ? 'Tienes una invitación a videollamada.'
                : 'Tienes un mensaje directo nuevo.',
            actions: [
              NoticeAction(
                'Abrir',
                () => _openDirectMessages(latest.senderId),
                primary: true,
              ),
            ],
          ),
        );
      }
      if (unread != _directUnread) setState(() => _directUnread = unread);
    } catch (_) {
      // Los mensajes de nodo siguen funcionando si el servicio directo falla.
    }
  }

  Future<void> _openDirectMessages([String? peerId]) async {
    final ownId = ref.read(authProvider).userId;
    if (ownId == null) return;
    if (_miembros.isEmpty) await _fetchMiembros();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => DirectMessagesDialog(
        nodoId: widget.nodo.id,
        ownUserId: ownId,
        members: _miembros,
        initialPeerId: peerId,
      ),
    );
    if (mounted) unawaited(_refreshDirectUnread());
  }

  void _scrollToBottom() {
    if (!mounted) return;
    if (_scrollCtrl.hasClients) {
      if (MediaQuery.of(context).disableAnimations) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
        return;
      }
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _sendMessage() async {
    final draft = _msgCtrl.text;
    final key = _draftKey;
    if (draft.trim().isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    final success = await ref
        .read(chatMessagesProvider.notifier)
        .sendMensaje(draft);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (success) {
        if (_draftKey == key && _msgCtrl.text == draft) {
          _msgCtrl.clear();
        } else if (_draftStore.state[key] == draft) {
          _draftStore.state = {..._draftStore.state, key: ''};
        }
      } else {
        _sendError =
            'No enviado. Tu borrador se conserva; vuelve a pulsar Enviar.';
      }
    });
    if (success) _scrollToBottom();
  }

  Future<bool> _confirmMemberAction(String name, String action) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('$action a $name'),
            content: Text(
              '¿Confirmas que quieres ${action.toLowerCase()} a $name del nodo ${widget.nodo.nombre}?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(action),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _changeRole(String targetUserId, String newRol) async {
    try {
      final repo = ref.read(nodosRepositoryProvider);
      await repo.updateMiembroRol(
        nodoId: widget.nodo.id,
        userId: targetUserId,
        newRol: newRol,
      );
      _fetchMiembros();
    } catch (e) {
      _showErrorSnack(e.toString().replaceAll('Exception: ', ''));
    }
  }

  Future<void> _kickMember(String targetUserId, String name) async {
    if (!await _confirmMemberAction(name, 'Expulsar') || !mounted) return;
    try {
      final repo = ref.read(nodosRepositoryProvider);
      await repo.kickMiembro(widget.nodo.id, targetUserId);
      _fetchMiembros();
      _showSuccessSnack('Usuario $name expulsado');
    } catch (e) {
      _showErrorSnack(e.toString().replaceAll('Exception: ', ''));
    }
  }

  Future<void> _banMember(String targetUserId, String name) async {
    if (!await _confirmMemberAction(name, 'Bloquear') || !mounted) return;
    try {
      final repo = ref.read(nodosRepositoryProvider);
      await repo.banMiembro(widget.nodo.id, targetUserId);
      _fetchMiembros();
      _showSuccessSnack('Usuario $name baneado');
    } catch (e) {
      _showErrorSnack(e.toString().replaceAll('Exception: ', ''));
    }
  }

  void _showSuccessSnack(String msg) {
    if (!mounted) return;
    IronNotify.show(IronNotice(kind: NoticeKind.success, title: msg));
  }

  void _showErrorSnack(String msg) {
    if (!mounted) return;
    IronNotify.show(IronNotice(kind: NoticeKind.error, title: msg));
  }

  Widget _channels({bool sheet = false}) {
    final groups = ref.watch(subgruposProvider(widget.nodo.id)).subgrupos;
    final selected = ref.watch(selectedSubgrupoProvider);
    void choose(Subgrupo? sub, int tab) {
      ref.read(selectedSubgrupoProvider.notifier).state = sub;
      setState(() => _currentTab = tab);
      _fetchMiembros();
      if (sheet) Navigator.pop(context);
    }

    Widget row(
      String title,
      IconData icon,
      VoidCallback onTap, {
      bool active = false,
      int unread = 0,
    }) => ListTile(
      dense: true,
      selected: active,
      selectedColor: AppColors.accent,
      selectedTileColor: _darkChannelSelection,
      leading: Icon(icon, size: 18),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      trailing: unread > 0
          ? Badge(
              label: Text('$unread'),
              backgroundColor: AppColors.accent,
              textColor: AppColors.bg,
            )
          : null,
      onTap: onTap,
    );
    return Material(
      color: AppColors.surface,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'CANALES PÚBLICOS',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ),
          row(
            'General',
            Icons.tag,
            () => choose(null, 0),
            active: selected == null && _currentTab == 0,
          ),
          for (final sub in groups.where((s) => !s.esPrivado))
            row(
              sub.nombre,
              Icons.tag,
              () => choose(sub, 0),
              active: selected?.id == sub.id && _currentTab == 0,
              unread: sub.unreadCount,
            ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              'CANALES PRIVADOS',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ),
          for (final sub in groups.where((s) => s.esPrivado))
            row(
              sub.nombre,
              Icons.lock_outline,
              () => choose(sub, 0),
              active: selected?.id == sub.id && _currentTab == 0,
              unread: sub.unreadCount,
            ),
          const Divider(),
          row(
            'Gestionar subgrupos',
            Icons.tune_rounded,
            () => choose(null, 1),
            active: _currentTab == 1,
          ),
          row(
            'Reuniones y llamadas',
            Icons.videocam_outlined,
            () => choose(null, 2),
            active: _currentTab == 2,
          ),
          row(
            'Directos del nodo',
            Icons.chat_bubble_outline,
            _openDirectMessages,
            unread: _directUnread,
          ),
        ],
      ),
    );
  }

  static Color get _darkChannelSelection => AppColors.bubbleMine;

  void _showChannels() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (_) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: _channels(sheet: true),
      ),
    ),
  );

  void _toggleMembers() {
    if (MediaQuery.sizeOf(context).width >= _mobileBreakpoint) {
      setState(() => _showMembersSidebar = !_showMembersSidebar);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (_) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: ListView(
            children: [
              const ListTile(
                title: Text('Integrantes', style: TextStyle(fontSize: 21)),
              ),
              if (_miembros.isEmpty)
                const ListTile(
                  title: Text(
                    'No hay integrantes cargados. Actualiza el nodo.',
                  ),
                ),
              for (final m in _miembros)
                _buildMemberRow(
                  m,
                  ref.read(userEmailProvider),
                  ref.read(userRoleProvider).toUpperCase() == 'ADMIN',
                  widget.nodo.rol?.toUpperCase() ?? 'MEMBER',
                  widget.nodo.rol?.toUpperCase() == 'OWNER' ||
                      ref.read(userRoleProvider).toUpperCase() == 'ADMIN',
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatMessagesProvider);
    final selectedSubgrupo = ref.watch(selectedSubgrupoProvider);
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < _mobileBreakpoint;
    final currentUserEmail = ref.watch(userEmailProvider);
    final globalRole = ref.watch(userRoleProvider);
    final currentUserNodeRole = widget.nodo.rol?.toUpperCase() ?? 'MEMBER';
    final isGlobalAdmin = globalRole.toUpperCase() == 'ADMIN';
    final isOwnerOrGlobalAdmin =
        currentUserNodeRole == 'OWNER' || isGlobalAdmin;
    ref.listen<Subgrupo?>(selectedSubgrupoProvider, (previous, next) {
      _draftKey = '${widget.nodo.id}:${next?.id ?? 'general'}';
      _msgCtrl.text = _draftStore.state[_draftKey] ?? '';
      setState(() => _sendError = null);
    });

    final isSubgrupoLocked =
        selectedSubgrupo != null &&
        selectedSubgrupo.esPrivado &&
        !selectedSubgrupo.isMember &&
        !isOwnerOrGlobalAdmin;

    final themeColor = selectedSubgrupo != null
        ? AppColors.accent
        : AppColors.accent;

    // Auto scroll al cargar mensajes o recibir nuevos
    ref.listen<ChatMessagesState>(chatMessagesProvider, (prev, next) {
      if (prev == null || next.mensajes.length > prev.mensajes.length) {
        Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
      }
    });

    return Row(
      children: [
        if (!isMobile) SizedBox(width: 230, child: _channels()),
        // Área central de chat
        Expanded(
          child: Container(
            color: AppColors.bg,
            child: Column(
              children: [
                Container(
                  height: 60,
                  color: AppColors.surface,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      if (isMobile)
                        IconButton(
                          tooltip: 'Canales del nodo',
                          onPressed: _showChannels,
                          icon: const Icon(Icons.menu_rounded),
                        ),
                      Icon(
                        selectedSubgrupo?.esPrivado == true
                            ? Icons.lock_outline
                            : Icons.tag,
                        color: AppColors.textMuted,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _currentTab == 1
                                  ? 'Subgrupos'
                                  : _currentTab == 2
                                  ? 'Reuniones y llamadas'
                                  : selectedSubgrupo?.nombre ?? 'General',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              selectedSubgrupo?.descripcion ??
                                  'Canal de ${widget.nodo.nombre}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Reuniones y videollamadas',
                        onPressed: () => setState(() => _currentTab = 2),
                        icon: Icon(
                          Icons.videocam_outlined,
                          color: AppColors.textMuted,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Integrantes',
                        onPressed: _toggleMembers,
                        icon: Icon(
                          Icons.people_outline,
                          color: AppColors.textMuted,
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Ajustes del canal',
                        onSelected: (value) async {
                          if (value == 'node') {
                            showDialog(
                              context: context,
                              builder: (_) =>
                                  NodoDetailsDialog(nodo: widget.nodo),
                            );
                          } else if (selectedSubgrupo != null &&
                              value == 'members') {
                            await AssignMembersDialog.show(
                              context,
                              nodoId: widget.nodo.id,
                              subgrupo: selectedSubgrupo,
                            );
                            _fetchMiembros();
                          } else if (selectedSubgrupo != null &&
                              value == 'edit') {
                            await EditSubgrupoDialog.show(
                              context,
                              nodoId: widget.nodo.id,
                              subgrupo: selectedSubgrupo,
                            );
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'node',
                            child: Text('Ajustes del nodo'),
                          ),
                          if (selectedSubgrupo != null &&
                              (isOwnerOrGlobalAdmin ||
                                  selectedSubgrupo.creadoPor ==
                                      ref.read(authProvider).userId)) ...[
                            const PopupMenuItem(
                              value: 'members',
                              child: Text('Asignar integrantes'),
                            ),
                            const PopupMenuItem(
                              value: 'edit',
                              child: Text('Editar subgrupo'),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (_sendError != null || chatState.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _sendError ?? chatState.error!,
                            style: TextStyle(
                              color: AppColors.errorText,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => ref
                              .read(chatMessagesProvider.notifier)
                              .loadMensajes(),
                          child: const Text('Actualizar'),
                        ),
                      ],
                    ),
                  ),

                // Cuerpo condicional según Tab seleccionado
                if (_currentTab == 1)
                  Expanded(
                    child: SubgruposView(
                      nodoId: widget.nodo.id,
                      onOpenChat: (sub) {
                        ref.read(selectedSubgrupoProvider.notifier).state = sub;
                        setState(() => _currentTab = 0);
                        _fetchMiembros();
                      },
                    ),
                  )
                else if (_currentTab == 2)
                  Expanded(child: ReunionesView(nodoId: widget.nodo.id))
                else if (isSubgrupoLocked) ...[
                  // Pantalla de bloqueo si el subgrupo es privado y no es miembro
                  Expanded(
                    child: Center(
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 420),
                        margin: const EdgeInsets.all(24),
                        padding: const EdgeInsets.all(32),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: AppColors.accent.withValues(alpha: 0.3),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: AppColors.accent.withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.lock_person_rounded,
                                color: AppColors.accent,
                                size: 48,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              'Subgrupo Privado: ${selectedSubgrupo.nombre}',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              selectedSubgrupo.descripcion?.isNotEmpty == true
                                  ? selectedSubgrupo.descripcion!
                                  : 'Este subgrupo es privado. Para poder ver los mensajes y participar en las conversaciones, debes unirte al equipo.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 13,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  foregroundColor: AppColors.bg,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                icon: Icon(Icons.login_rounded, size: 18),
                                label: Text(
                                  'Unirse a este subgrupo',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                                onPressed: () async {
                                  final success = await ref
                                      .read(
                                        subgruposProvider(
                                          widget.nodo.id,
                                        ).notifier,
                                      )
                                      .toggleJoin(selectedSubgrupo);
                                  if (success) {
                                    final updatedList = ref
                                        .read(subgruposProvider(widget.nodo.id))
                                        .subgrupos;
                                    final updatedSub = updatedList.firstWhere(
                                      (s) => s.id == selectedSubgrupo.id,
                                      orElse: () => selectedSubgrupo.copyWith(
                                        isMember: true,
                                        miembrosCount:
                                            selectedSubgrupo.miembrosCount + 1,
                                      ),
                                    );
                                    ref
                                            .read(
                                              selectedSubgrupoProvider.notifier,
                                            )
                                            .state =
                                        updatedSub;
                                    _fetchMiembros();
                                    _showSuccessSnack(
                                      '¡Te has unido al subgrupo exitosamente!',
                                    );
                                  } else {
                                    final err =
                                        ref
                                            .read(
                                              subgruposProvider(widget.nodo.id),
                                            )
                                            .errorMessage ??
                                        'No se pudo unir al subgrupo.';
                                    _showErrorSnack(err);
                                  }
                                },
                              ),
                            ),
                            SizedBox(height: 12),
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                foregroundColor: AppColors.textMuted,
                              ),
                              icon: Icon(Icons.arrow_back, size: 16),
                              label: Text('Volver al chat general'),
                              onPressed: () {
                                ref
                                        .read(selectedSubgrupoProvider.notifier)
                                        .state =
                                    null;
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ] else ...[
                  // Banner informativo de Subgrupo Activo
                  if (selectedSubgrupo != null)
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.08),
                        border: Border(
                          bottom: BorderSide(color: AppColors.line, width: 0.5),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            color: AppColors.accent,
                            size: 16,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Estás en el canal de subgrupo #${selectedSubgrupo.nombre}. Los mensajes enviados aquí solo son visibles para los integrantes del subgrupo.',
                              style: TextStyle(
                                color: AppColors.accent,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.textMuted,
                              padding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () {
                              ref
                                      .read(selectedSubgrupoProvider.notifier)
                                      .state =
                                  null;
                            },
                            child: Text(
                              'Ir al General',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Lista de Mensajes
                  Expanded(
                    child: chatState.loading
                        ? Center(
                            child: CircularProgressIndicator(color: themeColor),
                          )
                        : chatState.mensajes.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  selectedSubgrupo != null
                                      ? Icons.groups_rounded
                                      : Icons.chat_bubble_outline_rounded,
                                  size: 48,
                                  color: AppColors.textMuted.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                                SizedBox(height: 12),
                                Text(
                                  selectedSubgrupo != null
                                      ? '¡Bienvenido al subgrupo #${selectedSubgrupo.nombre}!'
                                      : '¡Aquí comienza la conversación!',
                                  style: TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  selectedSubgrupo != null
                                      ? 'Comienza a compartir ideas y colaborar con tu equipo en este subgrupo.'
                                      : 'Envía un mensaje para saludar a todos.',
                                  style: TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ChatBackdrop(
                            child: ListView.builder(
                              controller: _scrollCtrl,
                              padding: EdgeInsets.symmetric(vertical: 16),
                              itemCount: chatState.mensajes.length,
                              itemBuilder: (context, i) {
                                final msg = chatState.mensajes[i];
                                final isSelf =
                                    msg.userId ==
                                    ref.watch(authProvider).userId;
                                final senderMember = _miembros
                                    .cast<NodoMiembro?>()
                                    .firstWhere(
                                      (m) => m?.userId == msg.userId,
                                      orElse: () => null,
                                    );
                                final isOwner =
                                    msg.userId == widget.nodo.creadorId;
                                final role = isOwner
                                    ? 'OWNER'
                                    : (senderMember?.rol ??
                                          (isSelf
                                              ? widget.nodo.rol
                                              : 'MEMBER'));

                                return ChatMessageRow(
                                  mensaje: msg,
                                  isSelf: isSelf,
                                  userRole: role,
                                  accentColor: themeColor,
                                  senderAvatarUrl:
                                      senderMember?.avatarUrl ?? msg.avatarUrl,
                                  senderAvatarColor:
                                      senderMember?.avatarColor ??
                                      msg.avatarColor,
                                  senderStatusText:
                                      senderMember?.statusText ??
                                      msg.statusText,
                                );
                              },
                            ),
                          ),
                  ),

                  // Entrada de texto inferior
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      border: Border(
                        top: BorderSide(color: AppColors.line, width: 0.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _msgCtrl,
                            style: TextStyle(
                              color: AppColors.text,
                              fontSize: 14,
                            ),
                            cursorColor: themeColor,
                            onFieldSubmitted: (_) => _sendMessage(),
                            decoration: InputDecoration(
                              hintText: selectedSubgrupo != null
                                  ? 'Enviar mensaje a #${selectedSubgrupo.nombre}'
                                  : 'Enviar mensaje a #${widget.nodo.nombre}',
                              hintStyle: TextStyle(
                                color: AppColors.textMuted.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                              filled: true,
                              fillColor: AppColors.bg,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide(color: AppColors.line),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide(color: AppColors.line),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide(
                                  color: themeColor,
                                  width: 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 8),
                        CircleAvatar(
                          backgroundColor: themeColor,
                          radius: 20,
                          child: IconButton(
                            icon: Icon(
                              Icons.send_rounded,
                              color: AppColors.bg,
                              size: 18,
                            ),
                            onPressed: _sending ? null : _sendMessage,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // Lateral derecho de Miembros estilo Discord
        if (_showMembersSidebar && !isMobile)
          Container(
            width: 220,
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border(
                left: BorderSide(color: AppColors.line, width: 0.5),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    selectedSubgrupo != null
                        ? 'MIEMBROS SUBGRUPO (${_subMiembros.isNotEmpty ? _subMiembros.length : selectedSubgrupo.miembrosCount})'
                        : 'INTEGRANTES (${_miembros.length})',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                Expanded(
                  child: selectedSubgrupo != null && _subMiembros.isNotEmpty
                      ? ListView.builder(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          itemCount: _subMiembros.length,
                          itemBuilder: (context, idx) {
                            final m = _subMiembros[idx];
                            final isSelf = m.email == currentUserEmail;
                            return SubgrupoMemberSidebarRow(
                              member: m,
                              isSelf: isSelf,
                            );
                          },
                        )
                      : _miembros.isEmpty
                      ? Center(
                          child: CircularProgressIndicator(color: themeColor),
                        )
                      : ListView(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          children: [
                            // Propietarios
                            if (_miembros.any(
                              (m) => m.rol.toUpperCase() == 'OWNER',
                            )) ...[
                              _categoryHeader('PROPIETARIO'),
                              ..._miembros
                                  .where((m) => m.rol.toUpperCase() == 'OWNER')
                                  .map(
                                    (m) => _buildMemberRow(
                                      m,
                                      currentUserEmail,
                                      isGlobalAdmin,
                                      currentUserNodeRole,
                                      isOwnerOrGlobalAdmin,
                                    ),
                                  ),
                            ],
                            // Administradores
                            if (_miembros.any(
                              (m) => m.rol.toUpperCase() == 'ADMIN',
                            )) ...[
                              _categoryHeader('ADMINISTRADORES'),
                              ..._miembros
                                  .where((m) => m.rol.toUpperCase() == 'ADMIN')
                                  .map(
                                    (m) => _buildMemberRow(
                                      m,
                                      currentUserEmail,
                                      isGlobalAdmin,
                                      currentUserNodeRole,
                                      isOwnerOrGlobalAdmin,
                                    ),
                                  ),
                            ],
                            // Miembros normales
                            if (_miembros.any(
                              (m) => m.rol.toUpperCase() == 'MEMBER',
                            )) ...[
                              _categoryHeader('MIEMBROS'),
                              ..._miembros
                                  .where((m) => m.rol.toUpperCase() == 'MEMBER')
                                  .map(
                                    (m) => _buildMemberRow(
                                      m,
                                      currentUserEmail,
                                      isGlobalAdmin,
                                      currentUserNodeRole,
                                      isOwnerOrGlobalAdmin,
                                    ),
                                  ),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _categoryHeader(String text) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.0,
        ),
      ),
    );
  }

  Widget _buildMemberRow(
    NodoMiembro m,
    String currentUserEmail,
    bool isGlobalAdmin,
    String currentUserNodeRole,
    bool isOwnerOrGlobalAdmin,
  ) {
    final isSelf = m.email == currentUserEmail;

    // Check if current user can manage this specific member
    bool canManage = false;
    if (!isSelf) {
      if (isGlobalAdmin || currentUserNodeRole == 'OWNER') {
        canManage = true;
      } else if (currentUserNodeRole == 'ADMIN') {
        canManage = m.rol.toUpperCase() == 'MEMBER';
      }
    }

    return MemberSidebarRow(
      member: m,
      isSelf: isSelf,
      canManage: canManage,
      onKick: () => _kickMember(m.userId, m.name),
      onBan: () => _banMember(m.userId, m.name),
      onChangeRole: (newRol) => _changeRole(m.userId, newRol),
      onDirectMessage: isSelf ? null : () => _openDirectMessages(m.userId),
    );
  }
}

// ── Fila del Integrante del Subgrupo en el Panel Lateral ────────────────────

class SubgrupoMemberSidebarRow extends StatelessWidget {
  final SubgrupoMiembro member;
  final bool isSelf;

  const SubgrupoMemberSidebarRow({
    super.key,
    required this.member,
    required this.isSelf,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = _getStatusColor(member.statusText);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                UserAvatar(
                  userId: member.userId,
                  viewable: true,
                  avatarUrl: member.avatarUrl,
                  avatarColor: member.avatarColor,
                  name: member.name,
                  size: 32,
                  showBorder: isSelf,
                  borderColor: AppColors.accent,
                ),
              ],
            ),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isSelf ? '${member.name} (Tú)' : member.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelf ? AppColors.accent : AppColors.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  LivePresenceLabel(userId: member.userId),
                  Text(
                    member.statusText?.isNotEmpty == true
                        ? member.statusText!
                        : '',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Fila de Mensaje del Chat ────────────────────────────────────────────────

class ChatMessageRow extends StatelessWidget {
  final Mensaje mensaje;
  final bool isSelf;
  final String? userRole;
  final Color accentColor;
  final String? senderAvatarUrl;
  final String? senderAvatarColor;
  final String? senderStatusText;

  ChatMessageRow({
    super.key,
    required this.mensaje,
    required this.isSelf,
    this.userRole,
    Color? accentColor,
    this.senderAvatarUrl,
    this.senderAvatarColor,
    this.senderStatusText,
  }) : accentColor = accentColor ?? AppColors.accent;

  Widget _buildRoleTag(String role) {
    Color color;
    Color bg;
    String label;
    switch (role.toUpperCase()) {
      case 'OWNER':
        color = const Color(0xFFF59E0B); // Gold / Amber
        bg = const Color(0xFFF59E0B).withValues(alpha: 0.18);
        label = 'CREADOR';
        break;
      case 'ADMIN':
        color = AppColors.accent;
        bg = AppColors.accent.withValues(alpha: 0.18);
        label = 'ADMIN';
        break;
      default:
        color = AppColors.textMuted;
        bg = AppColors.textMuted.withValues(alpha: 0.12);
        label = 'MIEMBRO';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = senderStatusText ?? mensaje.statusText;
    final statusColor = _getStatusColor(status);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar con soporte para Foto Personalizada / Color Base
          UserAvatar(
            userId: mensaje.userId,
            viewable: true,
            avatarUrl: senderAvatarUrl ?? mensaje.avatarUrl,
            avatarColor: senderAvatarColor ?? mensaje.avatarColor,
            name: mensaje.userName,
            size: 40,
            showBorder: isSelf,
            borderColor: accentColor,
          ),
          const SizedBox(width: 12),
          // Contenido del mensaje
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    Text(
                      mensaje.userName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelf ? accentColor : AppColors.text,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    if (userRole != null && userRole!.isNotEmpty)
                      _buildRoleTag(userRole!),
                    if (status != null && status.trim().isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: statusColor.withValues(alpha: 0.3),
                            width: 0.8,
                          ),
                        ),
                        child: Text(
                          status.trim(),
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    Text(
                      _formatTime(mensaje.createdAt),
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                MessageWithMeetingLink(
                  text: mensaje.contenido,
                  child: Text(
                    mensaje.contenido,
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime date) {
    final localDate = date.toLocal();
    final hour = localDate.hour.toString().padLeft(2, '0');
    final minute = localDate.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

// ── Fila del Integrante en el Panel Lateral ─────────────────────────────────

class MemberSidebarRow extends StatelessWidget {
  final NodoMiembro member;
  final bool isSelf;
  final bool canManage;
  final VoidCallback? onKick;
  final VoidCallback? onBan;
  final Function(String)? onChangeRole;
  final VoidCallback? onDirectMessage;

  const MemberSidebarRow({
    super.key,
    required this.member,
    required this.isSelf,
    required this.canManage,
    this.onKick,
    this.onBan,
    this.onChangeRole,
    this.onDirectMessage,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = _getStatusColor(member.statusText);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
        child: Row(
          children: [
            // Avatar con Indicador de Presencia en vivo y Foto personalizada
            Stack(
              clipBehavior: Clip.none,
              children: [
                UserAvatar(
                  userId: member.userId,
                  viewable: true,
                  avatarUrl: member.avatarUrl,
                  avatarColor: member.avatarColor,
                  name: member.name,
                  size: 32,
                  showBorder: isSelf,
                  borderColor: AppColors.accent,
                ),
              ],
            ),
            const SizedBox(width: 10),
            // Name y Presencia
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isSelf ? '${member.name} (Tú)' : member.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelf ? AppColors.accent : AppColors.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  LivePresenceLabel(userId: member.userId),
                  Text(
                    member.statusText?.isNotEmpty == true
                        ? member.statusText!
                        : '',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (onDirectMessage != null)
              IconButton(
                tooltip: 'Enviar mensaje directo',
                onPressed: onDirectMessage,
                icon: Icon(
                  Icons.chat_bubble_outline,
                  color: AppColors.accent,
                  size: 18,
                ),
              ),
            // Options if canManage
            if (canManage)
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_vert_rounded,
                  color: AppColors.textMuted,
                  size: 16,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                color: AppColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: AppColors.line),
                ),
                onSelected: (action) {
                  if (action == 'KICK' && onKick != null) {
                    onKick!();
                  } else if (action == 'BAN' && onBan != null) {
                    onBan!();
                  } else if (action == 'ADMIN' && onChangeRole != null) {
                    onChangeRole!('ADMIN');
                  } else if (action == 'MEMBER' && onChangeRole != null) {
                    onChangeRole!('MEMBER');
                  }
                },
                itemBuilder: (ctx) => [
                  PopupMenuItem(
                    value: 'ADMIN',
                    child: Row(
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          color: AppColors.accent,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          member.rol == 'ADMIN'
                              ? '✓ Administrador'
                              : 'Hacer Administrador',
                          style: TextStyle(color: AppColors.text, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'MEMBER',
                    child: Row(
                      children: [
                        Icon(
                          Icons.person_outline_rounded,
                          color: AppColors.textMuted,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          member.rol == 'MEMBER'
                              ? '✓ Miembro'
                              : 'Hacer Miembro',
                          style: TextStyle(color: AppColors.text, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(height: 1),
                  PopupMenuItem(
                    value: 'KICK',
                    child: Row(
                      children: [
                        const Icon(
                          Icons.gavel_rounded,
                          color: Colors.orange,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Expulsar',
                          style: TextStyle(color: Colors.orange, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'BAN',
                    child: Row(
                      children: [
                        const Icon(
                          Icons.block_rounded,
                          color: Colors.red,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Banear',
                          style: TextStyle(color: Colors.red, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
