import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import 'workspace_preferences.dart';
import '../../../../core/widgets/user_avatar.dart';
import '../../../iam/providers/auth_provider.dart';
import '../../../social/providers/friends_provider.dart';
import '../../data/direct_messages_repository.dart';
import '../../data/nodos_repository.dart';
import '../../providers/nodos_provider.dart';
import '../../data/reuniones_repository.dart';
import '../rtc_call_page.dart';
import 'meeting_link_widgets.dart';
import 'workspace_navigation.dart';
import '../../../../core/notify/iron_notice.dart';
import '../../../../core/notify/iron_notify.dart';

final directRepositoryProvider = Provider((ref) => DirectMessagesRepository());
final directOwnUserIdProvider = Provider(
  (ref) => ref.watch(authProvider.select((s) => s.userId)),
);

/// Estado de sesión de los chats privados que debe sobrevivir a que el
/// árbol se vuelva a montar (por ejemplo, al cambiar de tema).
class DirectSessionState {
  final Map<String, String> drafts = {};
  final Map<String, String> replyDrafts = {};
  final Set<String> pinned = {};
}

final directSessionProvider = Provider<DirectSessionState>((ref) {
  ref.watch(authProvider.select((s) => s.userId));
  return DirectSessionState();
});

/// Petición de abrir un chat desde otra vista: el chat directo con [userId]
/// dentro de [nodeId] o, con [DirectChatTarget.friend], el chat de amistad
/// (sin nodo), que se crea bajo demanda y siempre se puede abrir.
class DirectChatTarget {
  const DirectChatTarget({required String this.nodeId, required this.userId})
    : name = null,
      avatarUrl = null,
      avatarColor = null;
  const DirectChatTarget.friend({
    required this.userId,
    required String this.name,
    this.avatarUrl,
    this.avatarColor,
  }) : nodeId = null;
  final String? nodeId, name, avatarUrl, avatarColor;
  final String userId;
  bool get isFriend => nodeId == null;
}

final directChatRequestProvider = StateProvider<DirectChatTarget?>((ref) {
  ref.watch(authProvider.select((s) => s.userId));
  return null;
});

/// Un chat de la bandeja. Convive en dos formas:
/// - chat directo de nodo ([nodo] no nulo): canal de trabajo entre
///   integrantes de un nodo, con invitaciones a videollamadas;
/// - chat de amistad ([nodo] nulo): como los MD de Discord, no necesita un
///   nodo en común y solo existe mientras sean amigos.
class DirectContact {
  const DirectContact(Nodo this.nodo, this.member, this.messages)
    : _unread = null;

  /// Chat de amistad. [unread] viene del servidor porque [messages] solo
  /// trae el último mensaje en la bandeja.
  const DirectContact.friend(this.member, this.messages, {int? unread})
    : nodo = null,
      _unread = unread;

  factory DirectContact.friendOf({
    required String userId,
    required String name,
    String? avatarUrl,
    String? avatarColor,
    List<DirectMessage> messages = const [],
    int? unread,
  }) => DirectContact.friend(
    NodoMiembro(
      userId: userId,
      name: name,
      email: '',
      rol: 'MEMBER',
      avatarUrl: avatarUrl,
      avatarColor: avatarColor,
    ),
    messages,
    unread: unread,
  );

  final Nodo? nodo;
  final NodoMiembro member;
  final List<DirectMessage> messages;
  final int? _unread;
  bool get isFriend => nodo == null;
  // Keep the existing node-scoped authorization boundary, even for the same
  // peer; the friendship chat is a separate conversation.
  String get key =>
      isFriend ? 'amigo:${member.userId}' : '${nodo!.id}:${member.userId}';

  /// Dónde vive la conversación: el nodo o «Amigos».
  String get origin => nodo?.nombre ?? 'Amigos';
  DirectMessage? get latest => messages.isEmpty ? null : messages.last;
  int unread(String ownId) =>
      _unread ??
      messages.where((m) => m.recipientId == ownId && m.readAt == null).length;
}

final directContactsProvider =
    FutureProvider.family<List<DirectContact>, List<Nodo>>((ref, nodos) async {
      final ownId = ref.watch(directOwnUserIdProvider);
      if (ownId == null) return [];
      final repo = ref.watch(directRepositoryProvider);
      final membersRepo = ref.watch(nodosRepositoryProvider);
      final contacts = <DirectContact>[];
      // Sequential nodes bound fan-out; within each node these two reads are independent.
      for (final nodo in nodos) {
        final result = await Future.wait<Object>([
          membersRepo.fetchMiembros(nodo.id),
          repo.inbox(nodo.id),
        ]);
        final members = result[0] as List<NodoMiembro>;
        final inbox = result[1] as List<DirectMessage>;
        for (final member in members.where((m) => m.userId != ownId)) {
          final messages =
              inbox
                  .where(
                    (m) =>
                        m.senderId == member.userId ||
                        m.recipientId == member.userId,
                  )
                  .toList()
                ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
          contacts.add(DirectContact(nodo, member, messages));
        }
      }
      // Chats de amistad: si fallan, la bandeja de nodos sigue disponible.
      try {
        for (final c in await repo.friendConversations()) {
          contacts.add(
            DirectContact.friendOf(
              userId: c.userId,
              name: c.name,
              avatarUrl: c.avatarUrl,
              avatarColor: c.avatarColor,
              messages: [c.latest],
              unread: c.unread,
            ),
          );
        }
      } catch (_) {}
      contacts.sort(
        (a, b) => (b.latest?.createdAt ?? DateTime(1970)).compareTo(
          a.latest?.createdAt ?? DateTime(1970),
        ),
      );
      return contacts;
    });

class DirectChatsWorkspace extends ConsumerStatefulWidget {
  const DirectChatsWorkspace({
    super.key,
    required this.nodos,
    this.compact = false,
    this.active = true,
  });
  final List<Nodo> nodos;
  final bool compact, active;
  @override
  ConsumerState<DirectChatsWorkspace> createState() =>
      _DirectChatsWorkspaceState();
}

class _DirectChatsWorkspaceState extends ConsumerState<DirectChatsWorkspace> {
  DirectContact? _selected;
  DirectChatTarget? _handledTarget;
  bool _unreadOnly = false;
  late final DirectSessionState _session = ref.read(directSessionProvider);
  Set<String> get _pinned => _session.pinned;
  Map<String, String> get _drafts => _session.drafts;
  Map<String, String> get _replyDrafts => _session.replyDrafts;
  List<Nodo> _stableNodos = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _stableNodos = widget.nodos;
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && widget.active) {
        ref.invalidate(directContactsProvider(_stableNodos));
      }
    });
  }

  @override
  void didUpdateWidget(DirectChatsWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nodos.map((n) => n.id).join('|') !=
        _stableNodos.map((n) => n.id).join('|')) {
      _stableNodos = widget.nodos;
      final node = _selected?.nodo;
      if (node != null && !widget.nodos.any((n) => n.id == node.id)) {
        _selected = null;
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contacts = ref.watch(directContactsProvider(_stableNodos));
    final ownId = ref.watch(directOwnUserIdProvider) ?? '';
    _openRequested(contacts);
    return LayoutBuilder(
      builder: (context, size) {
        final narrow = size.maxWidth < 600;
        final list = Material(
          color: AppColors.surface,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Chats',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Actualizar chats',
                      onPressed: () =>
                          ref.invalidate(directContactsProvider(_stableNodos)),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                    IconButton(
                      tooltip: 'Nuevo chat',
                      onPressed: () => _newChat(contacts.valueOrNull ?? []),
                      icon: Icon(Icons.edit_square, color: AppColors.accent),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(
                      label: const Text('Todos'),
                      selected: !_unreadOnly,
                      onSelected: (_) => setState(() => _unreadOnly = false),
                    ),
                    ChoiceChip(
                      label: const Text('No leídos'),
                      selected: _unreadOnly,
                      onSelected: (_) => setState(() => _unreadOnly = true),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: contacts.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => WorkspaceEmpty(
                    title: 'No se pudieron cargar los chats',
                    description: 'Comprueba tu conexión y vuelve a intentarlo.',
                    action: OutlinedButton(
                      onPressed: () =>
                          ref.invalidate(directContactsProvider(_stableNodos)),
                      child: const Text('Reintentar'),
                    ),
                  ),
                  data: (all) {
                    final current = _selected;
                    final rows =
                        [
                              ...all,
                              // Chat de amistad recién abierto, aún vacío.
                              if (current != null &&
                                  !all.any((c) => c.key == current.key))
                                current,
                            ]
                            .where(
                              (c) =>
                                  c.latest != null || c.key == _selected?.key,
                            )
                            .where((c) => !_unreadOnly || c.unread(ownId) > 0)
                            .toList()
                          ..sort((a, b) {
                            final pin =
                                (_pinned.contains(b.key) ? 1 : 0) -
                                (_pinned.contains(a.key) ? 1 : 0);
                            return pin != 0
                                ? pin
                                : (b.latest?.createdAt ?? DateTime(1970))
                                      .compareTo(
                                        a.latest?.createdAt ?? DateTime(1970),
                                      );
                          });
                    if (rows.isEmpty) {
                      return WorkspaceEmpty(
                        title: _unreadOnly
                            ? 'Estás al día'
                            : 'Aún no tienes chats',
                        description: _unreadOnly
                            ? 'No tienes mensajes sin leer.'
                            : 'Escribe a un amigo o a alguien de tus nodos '
                                  'para empezar.',
                        action: _unreadOnly
                            ? null
                            : OutlinedButton.icon(
                                onPressed: () => _newChat(all),
                                icon: const Icon(Icons.edit_square),
                                label: const Text('Nuevo chat'),
                              ),
                      );
                    }
                    return ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final c = rows[i];
                        final unread = c.unread(ownId);
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Material(
                            color: _selected?.key == c.key
                                ? AppColors.accentDeep.withValues(alpha: .45)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            child: ListTile(
                              dense: widget.compact,
                              leading: UserAvatar(
                                userId: c.member.userId,
                                name: c.member.name,
                                avatarUrl: c.member.avatarUrl,
                                avatarColor: c.member.avatarColor,
                                size: widget.compact ? 30 : 36,
                              ),
                              title: Text(
                                c.member.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                '${c.origin} · ${c.latest?.content ?? 'Nueva conversación'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textMuted,
                                ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (unread > 0)
                                    Badge(
                                      label: Text('$unread'),
                                      backgroundColor: AppColors.accent,
                                      textColor: AppColors.bg,
                                    ),
                                  PopupMenuButton<String>(
                                    tooltip: 'Opciones del chat',
                                    onSelected: (_) => setState(() {
                                      if (!_pinned.add(c.key)) {
                                        _pinned.remove(c.key);
                                      }
                                    }),
                                    itemBuilder: (_) => [
                                      PopupMenuItem(
                                        value: 'pin',
                                        child: Text(
                                          _pinned.contains(c.key)
                                              ? 'Desfijar'
                                              : 'Fijar arriba',
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              onTap: () => setState(() => _selected = c),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
        final selected = _selected;
        final thread = selected == null
            ? const WorkspaceEmpty(
                title: 'Tu equipo, más cerca',
                description:
                    'Selecciona un chat o escribe a un amigo o a un integrante de tus nodos.',
              )
            : DirectConversation(
                key: ValueKey(selected.key),
                contact: selected,
                ownId: ownId,
                repository: ref.read(directRepositoryProvider),
                active: widget.active,
                draft: _drafts[selected.key] ?? '',
                replyDraft: _replyDrafts[selected.key],
                onDraft: (value) => _drafts[selected.key] = value,
                onReplyDraft: (value) {
                  if (value == null) {
                    _replyDrafts.remove(selected.key);
                  } else {
                    _replyDrafts[selected.key] = value;
                  }
                },
                onBack: () => setState(() => _selected = null),
                onSent: () {
                  if (mounted) {
                    ref.invalidate(directContactsProvider(_stableNodos));
                  }
                },
              );
        if (narrow) return selected == null ? list : thread;
        return Row(
          children: [
            SizedBox(width: 280, child: list),
            const VerticalDivider(width: 1),
            Expanded(child: thread),
          ],
        );
      },
    );
  }

  /// Atiende [directChatRequestProvider]. El chat de amistad se abre al
  /// momento (se crea bajo demanda); el de nodo espera a los contactos.
  void _openRequested(AsyncValue<List<DirectContact>> contacts) {
    final target = ref.watch(directChatRequestProvider);
    final all = contacts.valueOrNull;
    if (target == null || identical(target, _handledTarget)) return;
    if (!target.isFriend && (all == null || contacts.isLoading)) return;
    _handledTarget = target;
    final DirectContact? match = target.isFriend
        ? all?.where((c) => c.key == 'amigo:${target.userId}').firstOrNull ??
              DirectContact.friendOf(
                userId: target.userId,
                name: target.name ?? '',
                avatarUrl: target.avatarUrl,
                avatarColor: target.avatarColor,
              )
        : all!
              .where(
                (c) =>
                    c.nodo?.id == target.nodeId &&
                    c.member.userId == target.userId,
              )
              .firstOrNull;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(directChatRequestProvider.notifier).state = null;
      if (match != null) {
        setState(() => _selected = match);
      } else {
        IronNotify.show(
          IronNotice(
            kind: NoticeKind.warning,
            title:
                'No se encontró el chat: comprueba que sigan en el mismo nodo.',
          ),
        );
      }
    });
  }

  Future<void> _newChat(List<DirectContact> contacts) async {
    final picked = await showModalBottomSheet<DirectContact>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: Column(
            children: [
              const ListTile(
                title: Text('Nuevo chat', style: TextStyle(fontSize: 21)),
                subtitle: Text(
                  'Tus amigos (sin necesidad de un nodo en común) e '
                  'integrantes de tus nodos. Cada chat de nodo conserva su '
                  'nodo de origen.',
                ),
              ),
              Expanded(
                child: Consumer(
                  builder: (context, ref, _) {
                    final friends =
                        ref.watch(friendsListProvider).valueOrNull ?? const [];
                    final nodeContacts = contacts
                        .where((c) => !c.isFriend)
                        .toList();
                    if (friends.isEmpty && nodeContacts.isEmpty) {
                      return const WorkspaceEmpty(
                        title: 'No hay contactos disponibles',
                        description:
                            'Agrega amigos o únete a un nodo con otros integrantes y actualiza los chats.',
                      );
                    }
                    return ListView(
                      children: [
                        if (friends.isNotEmpty) const _PickerLabel('Amigos'),
                        for (final f in friends)
                          ListTile(
                            leading: UserAvatar(
                              userId: f.id,
                              name: f.name,
                              avatarUrl: f.avatarUrl,
                              avatarColor: f.avatarColor,
                              size: 36,
                            ),
                            title: Text(f.name),
                            subtitle: const Text('Chat de amistad'),
                            onTap: () => Navigator.pop(
                              context,
                              contacts
                                      .where((c) => c.key == 'amigo:${f.id}')
                                      .firstOrNull ??
                                  DirectContact.friendOf(
                                    userId: f.id,
                                    name: f.name,
                                    avatarUrl: f.avatarUrl,
                                    avatarColor: f.avatarColor,
                                  ),
                            ),
                          ),
                        if (nodeContacts.isNotEmpty)
                          const _PickerLabel('Integrantes de tus nodos'),
                        for (final c in nodeContacts)
                          ListTile(
                            leading: UserAvatar(
                              userId: c.member.userId,
                              name: c.member.name,
                              avatarUrl: c.member.avatarUrl,
                              size: 36,
                            ),
                            title: Text(c.member.name),
                            subtitle: Text(c.origin),
                            onTap: () => Navigator.pop(context, c),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _selected = picked);
  }
}

class _PickerLabel extends StatelessWidget {
  const _PickerLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
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

/// Mensaje del servidor para errores esperables (amistad terminada, límite
/// de envío, longitud); el resto usa [fallback].
String serverMessage(Object error, String fallback) {
  if (error is DioException) {
    final status = error.response?.statusCode ?? 0;
    final data = error.response?.data;
    if ({400, 403, 429}.contains(status) &&
        data is Map &&
        data['message'] is String) {
      return data['message'] as String;
    }
  }
  return fallback;
}

class DirectConversation extends StatefulWidget {
  const DirectConversation({
    super.key,
    required this.contact,
    required this.ownId,
    required this.repository,
    required this.onBack,
    required this.onSent,
    required this.onDraft,
    required this.onReplyDraft,
    this.draft = '',
    this.replyDraft,
    this.active = true,
    this.meetings,
  });
  final DirectContact contact;
  final ReunionesRepository? meetings;
  final String ownId, draft;
  final String? replyDraft;
  final bool active;
  final DirectMessagesRepository repository;
  final VoidCallback onBack, onSent;
  final ValueChanged<String> onDraft;
  final ValueChanged<String?> onReplyDraft;
  @override
  State<DirectConversation> createState() => _DirectConversationState();
}

class _DirectConversationState extends State<DirectConversation> {
  late final TextEditingController _composer;
  late List<DirectMessage> _messages;
  String? _error, _reply;
  late String _savedDraft;
  bool _sending = false, _refreshing = false, _loading = true;
  Timer? _timer;
  int _mutationEpoch = 0;
  @override
  void didUpdateWidget(DirectConversation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) unawaited(_refresh());
  }

  @override
  void initState() {
    super.initState();
    _savedDraft = widget.draft;
    _composer = TextEditingController(text: widget.draft)
      ..addListener(_saveDraft);
    _reply = widget.replyDraft;
    _messages = widget.contact.messages;
    unawaited(_refresh());
    _timer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => unawaited(_refresh()),
    );
  }

  void _saveDraft() {
    _savedDraft = _composer.text;
    widget.onDraft(_savedDraft);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _composer.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing || !widget.active || _sending) return;
    _refreshing = true;
    final epoch = _mutationEpoch;
    try {
      final contact = widget.contact;
      final messages = contact.isFriend
          ? await widget.repository.friendHistory(contact.member.userId)
          : await widget.repository.history(
              contact.nodo!.id,
              contact.member.userId,
            );
      if (mounted && widget.active && epoch == _mutationEpoch) {
        final initialLoad = _loading;
        setState(() {
          _messages = messages;
          _loading = false;
        });
        if (initialLoad) widget.onSent();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = serverMessage(
            error,
            'No se pudieron actualizar los mensajes. Reintenta.',
          );
        });
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _send() async {
    final draft = _composer.text;
    final text = draft.trim();
    final reply = _reply;
    if (text.isEmpty || _sending) return;
    final content = reply == null
        ? text
        : '> ${reply.replaceAll('\n', ' ')}\n\n$text';
    if (content.length > 2000) {
      setState(
        () => _error =
            'El mensaje, incluida la cita, supera los 2000 caracteres.',
      );
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final contact = widget.contact;
      final sent = contact.isFriend
          ? await widget.repository.friendSend(contact.member.userId, content)
          : await widget.repository.sendText(
              contact.nodo!.id,
              contact.member.userId,
              content,
            );
      if (!mounted) {
        if (_savedDraft == draft) widget.onDraft('');
        if (_reply == reply) widget.onReplyDraft(null);
        widget.onSent();
        return;
      }
      _mutationEpoch++;
      setState(() {
        if (!_messages.any((m) => m.id == sent.id)) {
          _messages = [..._messages, sent];
        }
        if (_composer.text == draft) _composer.clear();
        if (_reply == reply) {
          _reply = null;
          widget.onReplyDraft(null);
        }
      });
      widget.onSent();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = serverMessage(
            error,
            'No enviado. Tu borrador se conserva; pulsa Enviar para reintentar.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  bool _calling = false;

  /// Llamada espontánea y privada con este contacto: crea una reunión ya
  /// iniciada que solo ven ambos, le envía la invitación y abre la llamada.
  Future<void> _call() async {
    final node = widget.contact.nodo;
    if (_calling || node == null) return;
    setState(() {
      _calling = true;
      _error = null;
    });
    try {
      final peer = widget.contact.member;
      final reunion = await (widget.meetings ?? ReunionesRepository()).meetNow(
        nodoId: node.id,
        titulo: 'Llamada con ${peer.name}',
        invitados: [peer.userId],
        privada: true,
      );
      final invite = await widget.repository.invite(
        node.id,
        peer.userId,
        reunion.id,
      );
      if (!mounted) return;
      setState(() => _messages = [..._messages, invite]);
      widget.onSent();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RtcCallPage(reunion: reunion, canEnd: true),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'No se pudo iniciar la llamada.');
      }
    } finally {
      if (mounted) setState(() => _calling = false);
    }
  }

  Future<void> _join(DirectMessage invitation) async {
    final node = widget.contact.nodo;
    if (node == null) return;
    try {
      final meetings = await ReunionesRepository().fetchReuniones(node.id);
      final meeting = meetings
          .where((m) => m.id == invitation.reunionId && m.rtcEstado == 'active')
          .firstOrNull;
      if (meeting == null) throw StateError('ended');
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RtcCallPage(
            reunion: meeting,
            canEnd: widget.ownId == meeting.creadoPor,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'La llamada ya terminó o no está disponible.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        height: 60,
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Volver a Chats',
              onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            UserAvatar(
              userId: widget.contact.member.userId,
              viewable: true,
              name: widget.contact.member.name,
              avatarUrl: widget.contact.member.avatarUrl,
              size: 34,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.contact.member.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    widget.contact.isFriend
                        ? 'Chat de amistad'
                        : widget.contact.origin,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            // Las llamadas se crean como reuniones de un nodo.
            if (!widget.contact.isFriend)
              IconButton(
                tooltip: 'Llamar',
                onPressed: _calling ? null : _call,
                icon: const Icon(Icons.call_rounded),
              ),
            IconButton(
              tooltip: 'Detalles del chat',
              icon: const Icon(Icons.info_outline),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.contact.member.name,
                          style: const TextStyle(fontSize: 21),
                        ),
                        const SizedBox(height: 12),
                        if (widget.contact.isFriend) ...[
                          const Text(
                            'Chat de amistad: no depende de ningún nodo.',
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Solo ustedes dos pueden leerlo y escribirse mientras sean amigos. Si alguien bloquea al otro, nadie puede escribir.',
                          ),
                        ] else ...[
                          Text(
                            'Conversación privada del nodo ${widget.contact.origin}.',
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Solo tú y este integrante pueden consultar los mensajes. Las invitaciones activas se abren desde el chat.',
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      if (_error != null)
        Material(
          color: AppColors.error.withValues(alpha: .12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(color: AppColors.errorText, fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    setState(() => _error = null);
                    _refresh();
                  },
                  child: const Text('Actualizar'),
                ),
              ],
            ),
          ),
        ),
      Expanded(
        child: _loading && _messages.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : _messages.isEmpty
            ? const WorkspaceEmpty(
                title: 'Aquí empieza la conversación',
                description: 'Envía el primer mensaje.',
              )
            : ChatBackdrop(
                child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final m = _messages[_messages.length - index - 1];
                    final mine = m.senderId == widget.ownId;
                    return Align(
                      alignment: mine
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: GestureDetector(
                        onLongPress: () => _quote(m),
                        onSecondaryTap: () => _quote(m),
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 5),
                          padding: const EdgeInsets.all(12),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.sizeOf(context).width < 600
                                ? 300
                                : 480,
                          ),
                          decoration: BoxDecoration(
                            color: mine
                                ? AppColors.bubbleMine
                                : AppColors.surface2,
                            border: Border.all(color: AppColors.line),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              MessageWithMeetingLink(
                                text: m.content,
                                child: Text(
                                  m.content,
                                  style: TextStyle(
                                    color: AppColors.text,
                                    height: 1.45,
                                  ),
                                ),
                              ),
                              if (m.kind == 'call_invite' &&
                                  m.reunionId != null)
                                TextButton.icon(
                                  onPressed: () => _join(m),
                                  icon: const Icon(Icons.videocam_outlined),
                                  label: const Text('Entrar a la llamada'),
                                ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    messageTime(m.createdAt),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                  if (mine) ...[
                                    const SizedBox(width: 6),
                                    Icon(
                                      m.readAt == null
                                          ? Icons.check
                                          : Icons.done_all,
                                      size: 14,
                                      color: m.readAt == null
                                          ? AppColors.textMuted
                                          : AppColors.accent,
                                    ),
                                    Text(
                                      m.readAt == null ? ' Enviado' : ' Leído',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
      if (_reply != null)
        ListTile(
          dense: true,
          title: const Text('Responder con cita'),
          subtitle: Text(_reply!, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            tooltip: 'Cancelar respuesta',
            onPressed: () => setState(() {
              _reply = null;
              widget.onReplyDraft(null);
            }),
            icon: const Icon(Icons.close),
          ),
        ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _composer,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: 2000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: 'Mensaje a ${widget.contact.member.name}',
                    filled: true,
                    fillColor: AppColors.bg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide(color: AppColors.control),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: _sending ? 'Enviando' : 'Enviar mensaje',
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.bg,
                ),
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ),
      ),
    ],
  );

  void _quote(DirectMessage m) {
    setState(
      () => _reply = m.content.length > 240
          ? '${m.content.substring(0, 240)}…'
          : m.content,
    );
    widget.onReplyDraft(_reply);
  }
}

String messageTime(DateTime date) {
  final local = date.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}
