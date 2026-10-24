import 'package:flutter/material.dart';
import '../../../../core/presence/live_presence.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/nodos_repository.dart';
import '../../data/reuniones_repository.dart';
import 'meeting_actions.dart';

const _weekdays = [
  'lunes',
  'martes',
  'miércoles',
  'jueves',
  'viernes',
  'sábado',
  'domingo',
];

/// Opciones de repetición, como en el calendario de un equipo.
Map<String, String> repetitionOptions(DateTime date) => {
  'none': 'No se repite',
  'daily': 'Cada día',
  'weekdays': 'Días laborables (lunes a viernes)',
  'weekly': 'Cada semana el ${_weekdays[date.weekday - 1]}',
  'biweekly': 'Cada 2 semanas el ${_weekdays[date.weekday - 1]}',
  'monthly': 'Cada mes el día ${date.day}',
};

/// Texto corto de una repetición guardada.
String repetitionLabel(String? frecuencia) => switch (frecuencia) {
  'daily' => 'Se repite cada día',
  'weekdays' => 'Se repite de lunes a viernes',
  'weekly' => 'Se repite cada semana',
  'biweekly' => 'Se repite cada 2 semanas',
  'monthly' => 'Se repite cada mes',
  _ => '',
};

String _two(int n) => n.toString().padLeft(2, '0');
String hourLabel(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

/// Como máximo se consulta la disponibilidad de 20 personas a la vez.
const _maxAvailabilityUsers = 20;

/// Nueva reunión de IronLink (o edición de una existente): título,
/// asistentes con su disponibilidad, fecha, horario o todo el día,
/// ubicación, repetición y descripción. La reunión se celebra en IronLink y
/// el enlace para compartir se genera solo.
class CreateReunionDialog extends StatefulWidget {
  const CreateReunionDialog({
    super.key,
    this.nodoId,
    this.nodos = const [],
    this.initialDate,
    this.repository,
    this.loadMembers,
    this.editing,
  });

  /// Nodo fijo (desde la pestaña de reuniones del nodo).
  final String? nodoId;

  /// Nodos entre los que elegir (desde el calendario).
  final List<Nodo> nodos;
  final DateTime? initialDate;
  final ReunionesRepository? repository;
  final Future<List<NodoMiembro>> Function(String nodoId)? loadMembers;

  /// Reunión que se edita; null para programar una nueva.
  final Reunion? editing;

  /// Devuelve la reunión creada (la primera de una serie) o editada, o null
  /// si se canceló.
  static Future<Reunion?> show(
    BuildContext context, {
    String? nodoId,
    List<Nodo> nodos = const [],
    DateTime? initialDate,
    Reunion? editing,
    ReunionesRepository? repository,
  }) => showDialog<Reunion>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    builder: (_) => CreateReunionDialog(
      nodoId: nodoId,
      nodos: nodos,
      initialDate: initialDate,
      editing: editing,
      repository: repository,
    ),
  );

  @override
  State<CreateReunionDialog> createState() => _CreateReunionDialogState();
}

class _CreateReunionDialogState extends State<CreateReunionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  late final ReunionesRepository _repository;

  String? _nodoId;
  late DateTime _date;
  late TimeOfDay _start;
  late TimeOfDay _end;
  bool _allDay = false;
  String _frecuencia = 'none';
  int _ocurrencias = 4;
  bool _wholeNode = true;
  List<NodoMiembro>? _members;
  final Set<String> _invited = {};
  bool _saving = false;
  String? _error;

  /// Intervalos ocupados de cada asistente el día elegido.
  Map<String, List<BusyInterval>>? _busy;
  int _busyGeneration = 0;

  Reunion? get _editing => widget.editing;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? ReunionesRepository();
    final editing = _editing;
    if (editing != null) {
      _nodoId = editing.nodoId;
      _titleCtrl.text = editing.titulo;
      _descCtrl.text = editing.descripcion ?? '';
      _locationCtrl.text = editing.ubicacion ?? '';
      _allDay = editing.todoElDia;
      final start = editing.fechaInicio.toLocal();
      final end = (editing.fechaFin ?? start.add(const Duration(minutes: 30)))
          .toLocal();
      _date = DateTime(start.year, start.month, start.day);
      _start = editing.todoElDia
          ? const TimeOfDay(hour: 9, minute: 0)
          : TimeOfDay.fromDateTime(start);
      _end = editing.todoElDia
          ? const TimeOfDay(hour: 9, minute: 30)
          : TimeOfDay.fromDateTime(end);
      // Se decide al cargar los integrantes si son todo el nodo.
      _wholeNode = false;
      _invited.addAll(editing.asistentes);
    } else {
      _nodoId =
          widget.nodoId ??
          (widget.nodos.length == 1 ? widget.nodos.single.id : null);
      // La siguiente media hora en punto, como en un calendario.
      final now = DateTime.now();
      final next = DateTime(
        now.year,
        now.month,
        now.day,
        now.hour,
        now.minute < 30 ? 30 : 60,
      );
      final day = widget.initialDate;
      final sameDay =
          day == null ||
          (day.year == now.year &&
              day.month == now.month &&
              day.day == now.day);
      final start = sameDay ? next : DateTime(day.year, day.month, day.day, 9);
      _date = DateTime(start.year, start.month, start.day);
      _start = TimeOfDay.fromDateTime(start);
      _end = TimeOfDay.fromDateTime(start.add(const Duration(minutes: 30)));
    }
    if (_nodoId != null) _loadMembers();
  }

  @override
  void dispose() {
    _busyGeneration++;
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    final nodo = _nodoId!;
    setState(() => _members = null);
    List<NodoMiembro> list;
    try {
      final loader = widget.loadMembers ?? NodosRepository().fetchMiembros;
      // Quien organiza ya asiste: no se ofrece invitarse a sí mismo.
      list = (await loader(
        nodo,
      )).where((m) => m.userId != LivePresence.selfId).toList();
    } catch (_) {
      list = const [];
    }
    if (!mounted || _nodoId != nodo) return;
    setState(() {
      _members = list;
      final editing = _editing;
      if (editing != null && list.isNotEmpty) {
        final invited = editing.asistentes.toSet();
        _wholeNode = list.every((m) => invited.contains(m.userId));
      }
    });
    _refreshAvailability();
  }

  /// Personas cuya disponibilidad se muestra (sin quien organiza).
  List<String> get _attendees {
    final members = _members ?? const <NodoMiembro>[];
    final ids = _wholeNode
        ? members.map((m) => m.userId)
        : members.map((m) => m.userId).where(_invited.contains);
    return ids.take(_maxAvailabilityUsers).toList();
  }

  Future<void> _refreshAvailability() async {
    final nodo = _nodoId;
    final users = _attendees;
    final generation = ++_busyGeneration;
    if (nodo == null || users.isEmpty) {
      if (_busy != null) setState(() => _busy = null);
      return;
    }
    final from = DateTime(_date.year, _date.month, _date.day);
    final to = DateTime(_date.year, _date.month, _date.day + 1);
    try {
      final busy = await _repository.fetchAvailability(
        nodoId: nodo,
        desde: from,
        hasta: to,
        usuarios: users,
        excluir: _editing?.id,
      );
      if (!mounted || generation != _busyGeneration) return;
      setState(() => _busy = busy);
    } catch (_) {
      // Sin disponibilidad se puede programar igual.
      if (mounted && generation == _busyGeneration) {
        setState(() => _busy = null);
      }
    }
  }

  DateTime _at(TimeOfDay t) =>
      DateTime(_date.year, _date.month, _date.day, t.hour, t.minute);
  int get _minutes => _at(_end).difference(_at(_start)).inMinutes;

  /// Horario efectivo: de medianoche a medianoche si es de todo el día.
  (DateTime, DateTime) get _range => _allDay
      ? (
          DateTime(_date.year, _date.month, _date.day),
          DateTime(_date.year, _date.month, _date.day + 1),
        )
      : (_at(_start), _at(_end));

  void _setDuration(int minutes) => setState(
    () => _end = TimeOfDay.fromDateTime(
      _at(_start).add(Duration(minutes: minutes)),
    ),
  );

  String _memberName(String id) =>
      _members?.where((m) => m.userId == id).firstOrNull?.name ?? 'Alguien';

  /// Asistentes con otra reunión en el horario elegido.
  List<String> get _conflicts {
    final busy = _busy;
    if (busy == null || _allDay || _minutes <= 0) return const [];
    final (start, end) = _range;
    return [
      for (final id in _attendees)
        if ((busy[id] ?? const []).any((b) => b.overlaps(start, end))) id,
    ];
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final (start, end) = _range;
    final editing = _editing;
    final timeChanged =
        editing == null ||
        _allDay != editing.todoElDia ||
        !start.isAtSameMomentAs(editing.fechaInicio) ||
        (editing.fechaFin == null || !end.isAtSameMomentAs(editing.fechaFin!));
    final today = DateTime.now();
    String? error;
    if (_nodoId == null) {
      error = 'Elige el nodo de la reunión.';
    } else if (!_allDay && !end.isAfter(start)) {
      error = 'La reunión debe terminar después de empezar.';
    } else if (timeChanged &&
        (_allDay
            ? start.isBefore(DateTime(today.year, today.month, today.day))
            : start.isBefore(today.subtract(const Duration(minutes: 5))))) {
      error = 'Esa hora ya pasó. Para empezar ahora usa «Reunirse ahora».';
    } else if (!_wholeNode && _invited.isEmpty) {
      error = 'Invita al menos a una persona o elige todo el nodo.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    var scope = EditScope.una;
    if (editing?.serieId != null) {
      final chosen = await askEditScope(context);
      if (chosen == null || !mounted) return;
      scope = chosen;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final Reunion saved;
      if (editing == null) {
        (saved, _) = await _repository.createReunion(
          nodoId: _nodoId!,
          titulo: _titleCtrl.text.trim(),
          descripcion: _descCtrl.text.trim(),
          fechaInicio: start,
          fechaFin: end,
          frecuencia: _frecuencia,
          ocurrencias: _frecuencia == 'none' ? 1 : _ocurrencias,
          invitados: _wholeNode ? null : _invited.toList(),
          todoElDia: _allDay,
          ubicacion: _locationCtrl.text.trim(),
        );
      } else {
        saved = await _repository.updateReunion(
          nodoId: editing.nodoId,
          reunionId: editing.id,
          titulo: _titleCtrl.text.trim(),
          descripcion: _descCtrl.text.trim(),
          ubicacion: _locationCtrl.text.trim(),
          fechaInicio: timeChanged ? start : null,
          fechaFin: timeChanged ? end : null,
          todoElDia: timeChanged ? _allDay : null,
          invitados: _editedInvitees(editing),
          alcance: scope,
        );
      }
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString().replaceAll('Exception: ', '');
        });
      }
    }
  }

  /// Lista completa de invitados si cambió; null si sigue igual o no se
  /// pudieron cargar los integrantes.
  List<String>? _editedInvitees(Reunion editing) {
    final members = _members;
    if (members == null || members.isEmpty) return null;
    final chosen = _wholeNode
        ? members.map((m) => m.userId).toSet()
        : members.map((m) => m.userId).where(_invited.contains).toSet();
    final before = editing.asistentes.toSet();
    final same = chosen.length == before.length && chosen.containsAll(before);
    return same ? null : chosen.toList();
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        color: AppColors.textMuted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _picker({
    required String label,
    required IconData icon,
    required String value,
    required VoidCallback onTap,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _label(label),
      Semantics(
        button: true,
        label: '$label: $value',
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.line),
            ),
            child: Row(
              children: [
                Icon(icon, color: AppColors.accentText, size: 16),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    value,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.text, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  /// Franja del día de cada asistente con sus horas ocupadas y el horario
  /// elegido encima, como el asistente de programación de un calendario.
  Widget _availability() {
    final busy = _busy;
    final attendees = _attendees;
    if (busy == null || attendees.isEmpty) return const SizedBox.shrink();
    final (start, end) = _range;
    final day = DateTime(_date.year, _date.month, _date.day);
    // Ventana visible: de 7:00 a 21:00, ampliada si hace falta.
    var first = 7, last = 21;
    void widen(DateTime from, DateTime to) {
      final a = from.isBefore(day) ? 0 : from.hour;
      final b = !to.isBefore(day.add(const Duration(days: 1)))
          ? 24
          : to.hour + (to.minute > 0 ? 1 : 0);
      if (a < first) first = a;
      if (b > last) last = b;
    }

    if (!_allDay && _minutes > 0) widen(start, end);
    for (final id in attendees) {
      for (final b in busy[id] ?? const <BusyInterval>[]) {
        widen(b.start, b.end);
      }
    }
    final windowStart = day.add(Duration(hours: first));
    final windowMinutes = (last - first) * 60;
    double fraction(DateTime t) =>
        (t.difference(windowStart).inMinutes / windowMinutes).clamp(0.0, 1.0);

    Widget bar(String id) {
      final blocks = busy[id] ?? const <BusyInterval>[];
      final description = blocks.isEmpty
          ? 'libre todo el día'
          : 'ocupado ${blocks.map((b) => '${hourLabel(b.start)}–${hourLabel(b.end)}').join(', ')}';
      return Semantics(
        label: '${_memberName(id)}: $description',
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            return Container(
              height: 18,
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: AppColors.line),
              ),
              child: Stack(
                children: [
                  for (final b in blocks)
                    Positioned(
                      left: fraction(b.start) * w,
                      width: ((fraction(b.end) - fraction(b.start)) * w).clamp(
                        2.0,
                        w,
                      ),
                      top: 0,
                      bottom: 0,
                      child: Container(
                        color: AppColors.textSubtle.withValues(alpha: 0.55),
                      ),
                    ),
                  if (!_allDay && _minutes > 0)
                    Positioned(
                      left: fraction(start) * w,
                      width: ((fraction(end) - fraction(start)) * w).clamp(
                        2.0,
                        w,
                      ),
                      top: 0,
                      bottom: 0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.18),
                          border: Border.all(color: AppColors.accent),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      );
    }

    final conflicts = _conflicts;
    final shown = attendees.take(8).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('Disponibilidad de los asistentes'),
          for (final id in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      _memberName(id),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppColors.text, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: bar(id)),
                ],
              ),
            ),
          if (attendees.length > shown.length)
            Text(
              'y ${attendees.length - shown.length} más',
              style: TextStyle(color: AppColors.textSubtle, fontSize: 11),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 104),
            child: Row(
              children: [
                Text(
                  '${_two(first)}:00',
                  style: TextStyle(color: AppColors.textSubtle, fontSize: 11),
                ),
                const Spacer(),
                Text(
                  '${_two(last % 24)}:00',
                  style: TextStyle(color: AppColors.textSubtle, fontSize: 11),
                ),
              ],
            ),
          ),
          for (final id in conflicts)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${_memberName(id).split(' ').first} tiene otra '
                      'reunión a esa hora',
                      style: TextStyle(color: AppColors.warning, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          if (conflicts.isEmpty && !_allDay && _minutes > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Todos están libres a esa hora.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 560;
    final editing = _editing;
    final date = '${_two(_date.day)}/${_two(_date.month)}/${_date.year}';
    final now = DateTime.now();
    final datePicker = _picker(
      label: 'Fecha',
      icon: Icons.calendar_today_rounded,
      value: date,
      onTap: () async {
        final earliest = now.subtract(const Duration(days: 1));
        final picked = await showDatePicker(
          context: context,
          initialDate: _date,
          firstDate: _date.isBefore(earliest) ? _date : earliest,
          lastDate: now.add(const Duration(days: 365)),
        );
        if (picked == null) return;
        setState(() => _date = picked);
        _refreshAvailability();
      },
    );
    final pickers = [
      datePicker,
      _picker(
        label: 'Inicio',
        icon: Icons.access_time_rounded,
        value: hourLabel(_at(_start)),
        onTap: () async {
          final picked = await showTimePicker(
            context: context,
            initialTime: _start,
          );
          if (picked == null) return;
          final keep = _minutes > 0 ? _minutes : 30;
          setState(() => _start = picked);
          _setDuration(keep);
        },
      ),
      _picker(
        label: 'Fin',
        icon: Icons.timelapse_rounded,
        value: hourLabel(_at(_end)),
        onTap: () async {
          final picked = await showTimePicker(
            context: context,
            initialTime: _end,
          );
          if (picked != null) setState(() => _end = picked);
        },
      ),
    ];
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: Container(
        width: 560,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line),
        ),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      editing == null
                          ? Icons.event_rounded
                          : Icons.edit_calendar_rounded,
                      color: AppColors.accentText,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        editing == null ? 'Nueva reunión' : 'Editar reunión',
                        style: TextStyle(
                          color: AppColors.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Cerrar',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _titleCtrl,
                  autofocus: editing == null,
                  maxLength: 120,
                  style: TextStyle(color: AppColors.text, fontSize: 15),
                  decoration: _input('Agregar un título'),
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Escribe el título de la reunión'
                      : null,
                ),
                if (editing == null &&
                    widget.nodoId == null &&
                    widget.nodos.length > 1) ...[
                  const SizedBox(height: 8),
                  _label('Nodo'),
                  DropdownButtonFormField<String>(
                    initialValue: _nodoId,
                    isExpanded: true,
                    decoration: _input('Elige el nodo'),
                    items: [
                      for (final n in widget.nodos)
                        DropdownMenuItem(
                          value: n.id,
                          child: Text(
                            n.nombre,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      setState(() {
                        _nodoId = v;
                        _invited.clear();
                        _busy = null;
                      });
                      if (v != null) _loadMembers();
                    },
                  ),
                ],
                const SizedBox(height: 12),
                _label('Asistentes'),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Todo el nodo'),
                      selected: _wholeNode,
                      onSelected: (_) {
                        setState(() => _wholeNode = true);
                        _refreshAvailability();
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Personas específicas'),
                      selected: !_wholeNode,
                      onSelected: (_) {
                        setState(() => _wholeNode = false);
                        _refreshAvailability();
                      },
                    ),
                  ],
                ),
                if (!_wholeNode) ...[
                  const SizedBox(height: 8),
                  if (_nodoId == null)
                    Text(
                      'Elige primero el nodo.',
                      style: TextStyle(color: AppColors.textMuted),
                    )
                  else if (_members == null)
                    const LinearProgressIndicator()
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final m in _members!)
                          FilterChip(
                            label: Text(m.name),
                            selected: _invited.contains(m.userId),
                            onSelected: (on) {
                              setState(
                                () => on
                                    ? _invited.add(m.userId)
                                    : _invited.remove(m.userId),
                              );
                              _refreshAvailability();
                            },
                          ),
                      ],
                    ),
                ],
                const SizedBox(height: 12),
                // Material propio: el contenedor del diálogo tiene fondo.
                Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile(
                    value: _allDay,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    secondary: Icon(
                      Icons.wb_sunny_outlined,
                      color: AppColors.accentText,
                      size: 20,
                    ),
                    title: Text(
                      'Todo el día',
                      style: TextStyle(color: AppColors.text, fontSize: 14),
                    ),
                    onChanged: (v) => setState(() => _allDay = v),
                  ),
                ),
                const SizedBox(height: 4),
                if (_allDay)
                  datePicker
                else if (narrow)
                  ...pickers.expand((p) => [p, const SizedBox(height: 10)])
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 4, child: pickers[0]),
                      const SizedBox(width: 10),
                      Expanded(flex: 3, child: pickers[1]),
                      const SizedBox(width: 10),
                      Expanded(flex: 3, child: pickers[2]),
                    ],
                  ),
                if (!_allDay) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'Duración:',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                      for (final mins in [15, 30, 45, 60, 90])
                        ChoiceChip(
                          label: Text(switch (mins) {
                            60 => '1 h',
                            90 => '1 h 30 min',
                            _ => '$mins min',
                          }),
                          selected: _minutes == mins,
                          onSelected: (_) => _setDuration(mins),
                        ),
                    ],
                  ),
                ],
                _availability(),
                const SizedBox(height: 16),
                if (editing == null) ...[
                  _label('Repetición'),
                  DropdownButtonFormField<String>(
                    key: ValueKey(_date),
                    initialValue: _frecuencia,
                    isExpanded: true,
                    decoration: _input(''),
                    items: [
                      for (final e in repetitionOptions(_date).entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setState(() => _frecuencia = v ?? 'none'),
                  ),
                  if (_frecuencia != 'none') ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Termina después de $_ocurrencias reuniones',
                            style: TextStyle(color: AppColors.text),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Una reunión menos',
                          onPressed: _ocurrencias > 2
                              ? () => setState(() => _ocurrencias--)
                              : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        IconButton(
                          tooltip: 'Una reunión más',
                          onPressed: _ocurrencias < 52
                              ? () => setState(() => _ocurrencias++)
                              : null,
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                  ],
                ] else if (editing.repite)
                  Row(
                    children: [
                      Icon(
                        Icons.repeat_rounded,
                        size: 16,
                        color: AppColors.textMuted,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          repetitionLabel(editing.repeticion),
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _locationCtrl,
                  maxLength: 200,
                  style: TextStyle(color: AppColors.text, fontSize: 13),
                  decoration: _input('Ubicación (opcional)').copyWith(
                    prefixIcon: Icon(
                      Icons.place_outlined,
                      color: AppColors.textMuted,
                      size: 18,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descCtrl,
                  maxLines: 3,
                  maxLength: 2000,
                  style: TextStyle(color: AppColors.text, fontSize: 13),
                  decoration: _input('Agenda o detalles de la reunión'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(color: Color(0xFFEF4444)),
                  ),
                ],
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancelar'),
                    ),
                    FilledButton.icon(
                      onPressed: _saving ? null : _submit,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              editing == null
                                  ? Icons.send_rounded
                                  : Icons.save_rounded,
                              size: 18,
                            ),
                      label: Text(editing == null ? 'Programar' : 'Guardar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _input(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: AppColors.textSubtle, fontSize: 13),
    filled: true,
    fillColor: AppColors.bg,
    counterText: '',
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: AppColors.line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: AppColors.line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: AppColors.accent),
    ),
  );
}
