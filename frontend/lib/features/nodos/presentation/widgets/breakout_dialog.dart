import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/breakout_repository.dart';

/// Gestión de salas de trabajo para moderadores (IRL-RTC-US-07). Devuelve la
/// sala que el moderador eligió visitar, si eligió alguna.
Future<BreakoutTarget?> showBreakoutDialog(
  BuildContext context, {
  required String nodoId,
  required String reunionId,
  String? ownUserId,
  BreakoutRepository? repository,
}) => showDialog<BreakoutTarget>(
  context: context,
  builder: (_) => BreakoutDialog(
    nodoId: nodoId,
    reunionId: reunionId,
    ownUserId: ownUserId,
    repository: repository ?? BreakoutRepository(),
  ),
);

class BreakoutDialog extends StatefulWidget {
  const BreakoutDialog({
    super.key,
    required this.nodoId,
    required this.reunionId,
    required this.repository,
    this.ownUserId,
  });
  final String nodoId, reunionId;
  final String? ownUserId;
  final BreakoutRepository repository;

  @override
  State<BreakoutDialog> createState() => _BreakoutDialogState();
}

class _BreakoutDialogState extends State<BreakoutDialog> {
  BreakoutState? _state;
  String? _error;
  bool _busy = false;
  int _count = 2;

  /// Sala elegida para cada persona (índice) o null si no va a ninguna.
  final Map<String, int?> _assigned = {};

  @override
  void initState() {
    super.initState();
    _run(() => widget.repository.fetch(widget.nodoId, widget.reunionId));
  }

  List<BreakoutPerson> get _people => [
    for (final p in _state?.connected ?? const <BreakoutPerson>[])
      if (p.userId != widget.ownUserId) p,
  ];

  Future<void> _run(Future<BreakoutState> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = await action();
      if (!mounted) return;
      setState(() {
        _state = state;
        if (_assigned.isEmpty) _autoAssign();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _autoAssign() {
    final state = _state;
    if (state == null) return;
    final people = _people.map((p) => p.userId).toList();
    final (rooms, left) = BreakoutRepository.distribute(
      people,
      _count,
      state.capacity,
    );
    _assigned
      ..clear()
      ..addEntries([
        for (var i = 0; i < rooms.length; i++)
          for (final user in rooms[i].members) MapEntry(user, i),
        for (final user in left) MapEntry(user, null),
      ]);
  }

  List<BreakoutDraft> get _drafts {
    final rooms = [for (var i = 1; i <= _count; i++) BreakoutDraft('Sala $i')];
    for (final entry in _assigned.entries) {
      final index = entry.value;
      if (index != null && index < _count) rooms[index].members.add(entry.key);
    }
    return rooms;
  }

  String? get _capacityProblem {
    final capacity = _state?.capacity ?? 3;
    final full = _drafts.where((r) => r.members.length > capacity);
    return full.isEmpty
        ? null
        : '${full.first.name} supera el máximo de $capacity personas por sala.';
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return AlertDialog(
      title: const Text('Salas de trabajo'),
      content: SizedBox(
        width: 480,
        child: state == null
            ? (_error != null
                  ? Text(_error!, style: TextStyle(color: AppColors.errorText))
                  : const SizedBox(
                      height: 120,
                      child: Center(child: CircularProgressIndicator()),
                    ))
            : SingleChildScrollView(
                child: state.open ? _openRooms(state) : _planner(state),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
        if (state != null && state.open)
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _run(
                    () => widget.repository.close(
                      widget.nodoId,
                      widget.reunionId,
                    ),
                  ),
            icon: const Icon(Icons.meeting_room_outlined, size: 18),
            label: const Text('Cerrar todas las salas'),
          )
        else if (state != null)
          OutlinedButton.icon(
            onPressed: _busy || _capacityProblem != null
                ? null
                : () => _run(
                    () => widget.repository.open(
                      widget.nodoId,
                      widget.reunionId,
                      _drafts,
                    ),
                  ),
            icon: const Icon(Icons.call_split_rounded, size: 18),
            label: Text(_busy ? 'Abriendo…' : 'Abrir salas'),
          ),
      ],
    );
  }

  Widget _message(String text, {bool error = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(
        color: error ? AppColors.errorText : AppColors.textMuted,
        fontSize: 13,
      ),
    ),
  );

  Widget _openRooms(BreakoutState state) {
    final where = {for (final p in state.connected) p.userId: p.salaId};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) _message(_error!, error: true),
        _message(
          'Las salas están abiertas. Cerrarlas devuelve a todos a la sala principal.',
        ),
        for (final room in state.rooms)
          Card(
            child: ListTile(
              title: Text(room.name),
              subtitle: Text(
                room.members.isEmpty
                    ? 'Sin personas asignadas'
                    : room.members
                          .map(
                            (m) => where[m.userId] == room.id
                                ? '${m.name} (en la sala)'
                                : m.name,
                          )
                          .join(', '),
              ),
              trailing: TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).pop(BreakoutTarget(room.id, room.name)),
                child: const Text('Visitar'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _planner(BreakoutState state) {
    final people = _people;
    final problem = _capacityProblem;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) _message(_error!, error: true),
        _message(
          'Cada sala admite hasta ${state.capacity} personas. Los asignados reciben un aviso y entran en 10 s; tú puedes visitar cualquier sala.',
        ),
        Row(
          children: [
            const Expanded(child: Text('Número de salas')),
            IconButton(
              tooltip: 'Menos salas',
              onPressed: _count > 1
                  ? () => setState(() {
                      _count--;
                      _autoAssign();
                    })
                  : null,
              icon: const Icon(Icons.remove_rounded),
            ),
            Text('$_count', style: const TextStyle(fontSize: 16)),
            IconButton(
              tooltip: 'Más salas',
              onPressed: _count < 10
                  ? () => setState(() {
                      _count++;
                      _autoAssign();
                    })
                  : null,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
        if (people.isEmpty)
          _message('Aún no hay otros participantes conectados para repartir.')
        else ...[
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(_autoAssign),
              icon: const Icon(Icons.shuffle_rounded, size: 18),
              label: const Text('Repartir automáticamente'),
            ),
          ),
          for (final person in people)
            Row(
              children: [
                Expanded(
                  child: Text(person.name, overflow: TextOverflow.ellipsis),
                ),
                DropdownButton<int?>(
                  value: _assigned[person.userId],
                  onChanged: (v) =>
                      setState(() => _assigned[person.userId] = v),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Sala principal'),
                    ),
                    for (var i = 0; i < _count; i++)
                      DropdownMenuItem(value: i, child: Text('Sala ${i + 1}')),
                  ],
                ),
              ],
            ),
        ],
        if (problem != null) _message(problem, error: true),
      ],
    );
  }
}
