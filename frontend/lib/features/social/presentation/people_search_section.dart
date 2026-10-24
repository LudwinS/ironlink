import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/user_avatar.dart';
import '../data/friends_repository.dart';
import '../providers/friends_provider.dart';
import 'block_dialog.dart';
import '../../../core/notify/iron_notice.dart';
import '../../../core/notify/iron_notify.dart';

/// Sección «Personas» del buscador: resultados con la acción de amistad que
/// corresponde a cada uno (agregar, solicitud enviada, aceptar o amigos) y
/// la opción de bloquear o desbloquear. Por nombre la coincidencia es
/// parcial; con «@» solo encuentra el correo completo.
class PeopleSearchSection extends ConsumerStatefulWidget {
  const PeopleSearchSection({
    super.key,
    required this.query,
    this.debounce = const Duration(milliseconds: 300),
  });
  final String query;
  final Duration debounce;

  @override
  ConsumerState<PeopleSearchSection> createState() =>
      _PeopleSearchSectionState();
}

class _PeopleSearchSectionState extends ConsumerState<PeopleSearchSection> {
  List<PersonResult> _results = const [];
  String? _error;
  bool _loading = false;
  final Set<String> _busy = {};
  Timer? _timer;
  int _epoch = 0;

  String get _query => widget.query.trim();

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(PeopleSearchSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query.trim() != _query) _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Solo se llama desde initState/didUpdateWidget, que preceden a build:
  /// basta con cambiar los campos.
  void _schedule() {
    _timer?.cancel();
    final epoch = ++_epoch;
    if (_query.characters.length < FriendsRepository.minQuery) {
      _results = const [];
      _error = null;
      _loading = false;
      return;
    }
    _loading = true;
    _error = null;
    _timer = Timer(widget.debounce, () => unawaited(_run(epoch)));
  }

  Future<void> _run(int epoch) async {
    try {
      final results = await ref.read(friendsRepositoryProvider).search(_query);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _results = results;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _error = error is FriendsException
            ? error.message
            : 'No se pudo buscar personas.';
        _loading = false;
      });
    }
  }

  Future<void> _act(PersonResult person) async {
    if (_busy.contains(person.id)) return;
    final repository = ref.read(friendsRepositoryProvider);
    setState(() => _busy.add(person.id));
    try {
      PersonResult next = person;
      switch (person.friendship) {
        case Friendship.none:
          final sent = await repository.send(person.id);
          next = person.copyWith(
            friendship: sent.status,
            requestId: sent.requestId,
          );
        case Friendship.received:
          await repository.accept(person.requestId!);
          next = person.copyWith(friendship: Friendship.friends);
        case Friendship.sent:
        case Friendship.friends:
          return;
      }
      if (!mounted) return;
      _replace(next);
      refreshFriends(ref);
    } catch (error) {
      if (mounted) _snack(error);
    } finally {
      if (mounted) setState(() => _busy.remove(person.id));
    }
  }

  void _replace(PersonResult next) => setState(() {
    _results = [for (final p in _results) p.id == next.id ? next : p];
  });

  void _snack(Object error) => IronNotify.show(
    IronNotice(
      kind: NoticeKind.error,
      title: error is FriendsException
          ? error.message
          : 'No se pudo completar la acción.',
    ),
  );

  Future<void> _setBlocked(PersonResult person, bool blocked) async {
    if (_busy.contains(person.id)) return;
    if (blocked && !await confirmBlock(context, person.name)) return;
    if (!mounted) return;
    final repository = ref.read(friendsRepositoryProvider);
    setState(() => _busy.add(person.id));
    try {
      if (blocked) {
        await repository.block(person.id);
      } else {
        await repository.unblock(person.id);
      }
      if (!mounted) return;
      // Bloquear borra la amistad y las solicitudes; desbloquear no las
      // restaura.
      _replace(
        PersonResult(
          id: person.id,
          name: person.name,
          avatarUrl: person.avatarUrl,
          avatarColor: person.avatarColor,
          friendship: Friendship.none,
          sharesNode: person.sharesNode,
          blocked: blocked,
        ),
      );
      refreshFriends(ref);
    } catch (error) {
      if (mounted) _snack(error);
    } finally {
      if (mounted) setState(() => _busy.remove(person.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_query.characters.length < FriendsRepository.minQuery) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Text(
            'PERSONAS',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: .6,
            ),
          ),
        ),
        if (_loading && _results.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_error!, style: TextStyle(color: AppColors.errorText)),
          )
        else if (_results.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              FriendsRepository.isEmailQuery(_query)
                  ? 'Ninguna cuenta usa ese correo. Escribe el correo '
                        'completo; por correo no se admiten coincidencias '
                        'parciales.'
                  : 'Nadie coincide con «$_query».',
              style: TextStyle(color: AppColors.textMuted),
            ),
          )
        else
          for (final person in _results)
            PersonRow(
              person: person,
              busy: _busy.contains(person.id),
              onAction: () => _act(person),
              onBlock: () => _setBlocked(person, true),
              onUnblock: () => _setBlocked(person, false),
            ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// Fila adaptable: en pantallas estrechas el botón baja bajo el nombre.
class PersonRow extends StatelessWidget {
  const PersonRow({
    super.key,
    required this.person,
    required this.onAction,
    this.onBlock,
    this.onUnblock,
    this.busy = false,
  });
  final PersonResult person;
  final VoidCallback onAction;
  final VoidCallback? onBlock, onUnblock;
  final bool busy;

  Widget _button() {
    if (person.blocked) {
      return OutlinedButton.icon(
        onPressed: busy ? null : onUnblock,
        icon: busy
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.lock_open_rounded, size: 18),
        label: const Text('Desbloquear'),
      );
    }
    final (label, icon) = switch (person.friendship) {
      Friendship.none => ('Agregar amigo', Icons.person_add_alt_1_rounded),
      Friendship.sent => ('Solicitud enviada', Icons.schedule_rounded),
      Friendship.received => ('Aceptar', Icons.check_rounded),
      Friendship.friends => ('Amigos', Icons.people_alt_rounded),
    };
    final actionable =
        !busy &&
        (person.friendship == Friendship.none ||
            person.friendship == Friendship.received);
    final child = busy
        ? const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon, size: 18);
    return actionable
        ? FilledButton.tonalIcon(
            onPressed: onAction,
            icon: child,
            label: Text(label),
          )
        : OutlinedButton.icon(onPressed: null, icon: child, label: Text(label));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final narrow = size.maxWidth < 440;
      final details = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            person.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(
            person.blocked
                ? 'Bloqueada'
                : person.sharesNode
                ? 'Comparten un nodo'
                : 'Sin nodos en común',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: person.blocked ? AppColors.errorText : AppColors.textMuted,
            ),
          ),
          if (narrow) ...[const SizedBox(height: 6), _button()],
        ],
      );
      final menu = person.blocked || onBlock == null
          ? null
          : PopupMenuButton<String>(
              tooltip: 'Más opciones para ${person.name}',
              enabled: !busy,
              onSelected: (_) => onBlock!(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'bloquear',
                  child: Text(
                    'Bloquear',
                    style: TextStyle(color: AppColors.errorText),
                  ),
                ),
              ],
            );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            UserAvatar(
              userId: person.id,
              name: person.name,
              avatarUrl: person.avatarUrl,
              avatarColor: person.avatarColor,
              size: 38,
            ),
            const SizedBox(width: 12),
            Expanded(child: details),
            if (!narrow) ...[const SizedBox(width: 12), _button()],
            ?menu,
          ],
        ),
      );
    },
  );
}
