import 'package:flutter/material.dart';
import '../../../../core/presence/live_presence.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/calendar_repository.dart';
import 'attendance_dialog.dart';
import 'create_reunion_dialog.dart';
import 'meeting_actions.dart';
import 'meeting_link_widgets.dart';
import '../../data/nodos_repository.dart';
import '../../data/reuniones_repository.dart';
import '../../../../core/notify/iron_notice.dart';
import '../../../../core/notify/iron_notify.dart';

/// Vista del calendario: cuadrícula del mes o semana con franjas horarias.
enum CalendarView { month, week }

/// Lunes de la semana de [day], a medianoche local.
DateTime weekStartOf(DateTime day) =>
    DateTime(day.year, day.month, day.day - (day.weekday - DateTime.monday));

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Inicio y fin locales de una reunión (30 min si no tiene fin).
(DateTime, DateTime) meetingBounds(Reunion r) {
  final start = r.fechaInicio.toLocal();
  final end = r.fechaFin?.toLocal() ?? start.add(const Duration(minutes: 30));
  return (start, end.isAfter(start) ? end : start);
}

/// Reuniones de un día con su carril y el número de carriles del grupo de
/// reuniones que se solapan, para dibujarlas lado a lado.
List<(CalendarMeeting, int, int)> layoutDay(List<CalendarMeeting> events) {
  final sorted = [...events]
    ..sort((a, b) {
      final (sa, ea) = meetingBounds(a.reunion);
      final (sb, eb) = meetingBounds(b.reunion);
      final byStart = sa.compareTo(sb);
      return byStart != 0 ? byStart : eb.compareTo(ea);
    });
  final result = <(CalendarMeeting, int, int)>[];
  var group = <(CalendarMeeting, int)>[];
  var laneEnds = <DateTime>[];
  DateTime? groupEnd;
  void flush() {
    for (final (event, lane) in group) {
      result.add((event, lane, laneEnds.length));
    }
    group = [];
    laneEnds = [];
    groupEnd = null;
  }

  for (final event in sorted) {
    final (start, end) = meetingBounds(event.reunion);
    if (groupEnd != null && !start.isBefore(groupEnd!)) flush();
    var lane = laneEnds.indexWhere((e) => !e.isAfter(start));
    if (lane == -1) {
      laneEnds.add(end);
      lane = laneEnds.length - 1;
    } else {
      laneEnds[lane] = end;
    }
    group.add((event, lane));
    if (groupEnd == null || end.isAfter(groupEnd!)) groupEnd = end;
  }
  flush();
  return result;
}

class CalendarWorkspace extends StatefulWidget {
  const CalendarWorkspace({
    super.key,
    required this.nodos,
    required this.active,
    required this.onJoin,
    this.repository,
    this.meetings,
    this.now,
    this.revision = 0,
    this.initialView = CalendarView.month,
  });
  final List<Nodo> nodos;
  final bool active;
  final ValueChanged<CalendarMeeting> onJoin;
  final CalendarRepository? repository;
  final ReunionesRepository? meetings;
  final DateTime? now;
  final int revision;
  final CalendarView initialView;
  @override
  State<CalendarWorkspace> createState() => _CalendarWorkspaceState();
}

class _CalendarWorkspaceState extends State<CalendarWorkspace> {
  late final CalendarRepository _repository;
  late final ReunionesRepository _meetings;
  late DateTime _month;
  late DateTime _weekStart;
  late CalendarView _view;
  DateTime? _day;
  String? _node;
  CalendarResult? _result;
  bool _loading = false;
  String? _error;
  int _generation = 0;
  static const _months = [
    'Enero',
    'Febrero',
    'Marzo',
    'Abril',
    'Mayo',
    'Junio',
    'Julio',
    'Agosto',
    'Septiembre',
    'Octubre',
    'Noviembre',
    'Diciembre',
  ];
  static const _shortMonths = [
    'ene',
    'feb',
    'mar',
    'abr',
    'may',
    'jun',
    'jul',
    'ago',
    'sep',
    'oct',
    'nov',
    'dic',
  ];
  static const _shortDays = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  static const _longDays = [
    'Lunes',
    'Martes',
    'Miércoles',
    'Jueves',
    'Viernes',
    'Sábado',
    'Domingo',
  ];

  /// Alto de una hora en la vista semanal.
  static const _hourHeight = 48.0;
  static const _gutter = 52.0;

  DateTime get _today => widget.now ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? CalendarRepository();
    _meetings = widget.meetings ?? ReunionesRepository();
    final now = _today;
    _month = DateTime(now.year, now.month);
    _weekStart = weekStartOf(now);
    _view = widget.initialView;
    if (widget.active) _load();
  }

  @override
  void didUpdateWidget(CalendarWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.nodos.map((n) => n.id).toSet();
    final after = widget.nodos.map((n) => n.id).toSet();
    final changed = before.length != after.length || !before.containsAll(after);
    if (changed && !after.contains(_node)) _node = null;
    if (!widget.active) {
      _generation++;
      _result = null;
      _loading = false;
    } else if (!oldWidget.active ||
        changed ||
        oldWidget.revision != widget.revision) {
      _load();
    }
  }

  /// En la vista semanal se piden los meses que toca la semana (uno o dos).
  Future<CalendarResult> _fetch() async {
    if (_view == CalendarView.month) {
      return _repository.fetchMonth(_month, nodeId: _node);
    }
    final last = _weekStart.add(const Duration(days: 6));
    final months = {
      DateTime(_weekStart.year, _weekStart.month),
      DateTime(last.year, last.month),
    };
    final results = await Future.wait(
      months.map((m) => _repository.fetchMonth(m, nodeId: _node)),
    );
    final seen = <String>{};
    return CalendarResult([
      for (final r in results)
        for (final m in r.meetings)
          if (seen.add(m.reunion.id)) m,
    ], truncated: results.any((r) => r.truncated));
  }

  Future<void> _load() async {
    if (!widget.active) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _result = null;
      _error = null;
    });
    try {
      final result = await _fetch();
      if (!mounted || generation != _generation || !widget.active) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation || !widget.active) return;
      setState(() {
        _error = 'No se pudo cargar el calendario.';
        _loading = false;
      });
    }
  }

  String _nodeName(String id) =>
      widget.nodos.where((n) => n.id == id).firstOrNull?.nombre ?? 'Nodo';

  void _snack(String text, {NoticeKind kind = NoticeKind.success}) =>
      IronNotify.show(IronNotice(kind: kind, title: text));

  Future<void> _newMeeting() async {
    final created = await CreateReunionDialog.show(
      context,
      nodos: widget.nodos,
      nodoId: _node,
      initialDate: _day,
      repository: widget.meetings,
    );
    if (created == null || !mounted) return;
    final local = created.fechaInicio.toLocal();
    setState(() {
      _month = DateTime(local.year, local.month);
      _day = DateTime(local.year, local.month, local.day);
      _weekStart = weekStartOf(local);
    });
    _snack('«${created.titulo}» quedó en tu calendario.');
    _load();
  }

  Future<void> _edit(CalendarMeeting event) async {
    final updated = await CreateReunionDialog.show(
      context,
      editing: event.reunion,
      repository: _meetings,
    );
    if (updated == null || !mounted) return;
    _snack('Cambios guardados en «${updated.titulo}».');
    _load();
  }

  Future<void> _meetNow() async {
    final reunion = await startMeetNow(
      context,
      nodos: widget.nodos,
      nodoId: _node,
      repository: _meetings,
    );
    if (reunion == null || !mounted) return;
    widget.onJoin(
      CalendarMeeting(
        reunion: reunion,
        nodeName: _nodeName(reunion.nodoId),
        canModerate: true,
        canJoin: true,
      ),
    );
  }

  Future<void> _start(CalendarMeeting event) async {
    try {
      await _meetings.startMeeting(
        nodoId: event.reunion.nodoId,
        reunionId: event.reunion.id,
      );
    } catch (_) {
      if (!mounted) return;
      _snack('No se pudo iniciar la reunión.', kind: NoticeKind.error);
      _load();
      return;
    }
    if (!mounted) return;
    widget.onJoin(
      CalendarMeeting(
        reunion: event.reunion.copyWith(rtcEstado: 'active'),
        nodeName: event.nodeName,
        canModerate: event.canModerate,
        canJoin: true,
      ),
    );
  }

  Future<void> _cancel(CalendarMeeting event) async {
    final serie = await confirmCancelMeeting(context, event.reunion);
    if (serie == null) return;
    try {
      await _meetings.deleteReunion(
        nodoId: event.reunion.nodoId,
        reunionId: event.reunion.id,
        serie: serie,
      );
    } catch (e) {
      if (!mounted) return;
      _snack(
        e.toString().replaceAll('Exception: ', ''),
        kind: NoticeKind.error,
      );
    }
    _load();
  }

  void _changeMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _day = null;
    });
    _load();
  }

  void _changeWeek(int delta) {
    setState(() {
      _weekStart = DateTime(
        _weekStart.year,
        _weekStart.month,
        _weekStart.day + 7 * delta,
      );
    });
    _load();
  }

  void _goToday() {
    final today = _today;
    setState(() {
      _month = DateTime(today.year, today.month);
      _day = DateTime(today.year, today.month, today.day);
      _weekStart = weekStartOf(today);
    });
    _load();
  }

  void _setView(CalendarView view) {
    if (view == _view) return;
    setState(() {
      if (view == CalendarView.week) {
        final today = _today;
        final anchor =
            _day ??
            (today.year == _month.year && today.month == _month.month
                ? today
                : _month);
        _weekStart = weekStartOf(anchor);
      } else {
        // El mes al que pertenece la mayor parte de la semana (su jueves).
        final thursday = _weekStart.add(const Duration(days: 3));
        _month = DateTime(thursday.year, thursday.month);
        _day = null;
      }
      _view = view;
    });
    _load();
  }

  /// Abre una reunión con las mismas acciones que su tarjeta.
  void _open(CalendarMeeting event) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: _meeting(
              event,
              close: () => Navigator.of(dialogContext).pop(),
            ),
          ),
        ),
      ),
    );
  }

  String _weekLabel() {
    final last = _weekStart.add(const Duration(days: 6));
    final a = _weekStart, b = last;
    final from = a.month == b.month
        ? '${a.day}'
        : '${a.day} ${_shortMonths[a.month - 1]}';
    return '$from – ${b.day} ${_shortMonths[b.month - 1]} ${b.year}';
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final meetings = (_result?.meetings ?? []).where((event) {
      final date = event.reunion.fechaInicio.toLocal();
      return _day == null || _sameDay(date, _day!);
    }).toList();
    final week = _view == CalendarView.week;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        LayoutBuilder(
          builder: (context, box) {
            // Como en un calendario de equipo: acciones arriba a la derecha;
            // en pantallas estrechas solo el icono (con su descripción).
            final compact = box.maxWidth < 560;
            final disabled = widget.nodos.isEmpty;
            return Row(
              children: [
                const Expanded(
                  child: Text(
                    'Calendario',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Actualizar calendario',
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh),
                ),
                if (compact) ...[
                  IconButton(
                    tooltip: 'Reunirse ahora',
                    onPressed: disabled ? null : _meetNow,
                    icon: const Icon(Icons.videocam_rounded),
                  ),
                  IconButton.filled(
                    tooltip: 'Nueva reunión',
                    onPressed: disabled ? null : _newMeeting,
                    icon: const Icon(Icons.add_rounded),
                  ),
                ] else ...[
                  OutlinedButton.icon(
                    onPressed: disabled ? null : _meetNow,
                    icon: const Icon(Icons.videocam_rounded),
                    label: const Text('Reunirse ahora'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: disabled ? null : _newMeeting,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Nueva reunión'),
                  ),
                ],
              ],
            );
          },
        ),
        const Text('Reuniones de todos tus nodos · horario local'),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, box) {
            final nodes = DropdownButtonFormField<String>(
              key: ValueKey(_node),
              initialValue: _node ?? '',
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Nodo',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('Todos los nodos'),
                ),
                for (final node in widget.nodos)
                  DropdownMenuItem(
                    value: node.id,
                    child: Text(node.nombre, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) {
                setState(() => _node = value == '' ? null : value);
                _load();
              },
            );
            final views = SegmentedButton<CalendarView>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: CalendarView.month,
                  icon: Icon(Icons.calendar_view_month_rounded, size: 18),
                  label: Text('Mes'),
                ),
                ButtonSegment(
                  value: CalendarView.week,
                  icon: Icon(Icons.view_week_rounded, size: 18),
                  label: Text('Semana'),
                ),
              ],
              selected: {_view},
              onSelectionChanged: (s) => _setView(s.first),
            );
            // En pantallas anchas, el selector de vista junto al filtro.
            if (box.maxWidth >= 560) {
              return Row(
                children: [
                  Expanded(child: nodes),
                  const SizedBox(width: 12),
                  views,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                nodes,
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerLeft, child: views),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        if (week)
          Row(
            children: [
              IconButton(
                tooltip: 'Semana anterior',
                onPressed: () => _changeWeek(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(child: Text(_weekLabel(), textAlign: TextAlign.center)),
              IconButton(
                tooltip: 'Semana siguiente',
                onPressed: () => _changeWeek(1),
                icon: const Icon(Icons.chevron_right),
              ),
              TextButton(onPressed: _goToday, child: const Text('Hoy')),
            ],
          )
        else ...[
          Row(
            children: [
              IconButton(
                tooltip: 'Mes anterior',
                onPressed: () => _changeMonth(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  '${_months[_month.month - 1]} ${_month.year}',
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                tooltip: 'Mes siguiente',
                onPressed: () => _changeMonth(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          _monthGrid(),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => setState(() => _day = null),
                child: const Text('Todo el mes'),
              ),
              TextButton(onPressed: _goToday, child: const Text('Hoy')),
            ],
          ),
        ],
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_error != null) ...[
          Text(_error!),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _load,
              child: const Text('Reintentar'),
            ),
          ),
        ],
        if (_result?.truncated == true)
          const Text(
            'Se muestran las primeras 500 reuniones. Filtra por nodo para reducir la lista.',
          ),
        if (week && !_loading && _error == null && _result != null)
          _weekView(_result!.meetings)
        else if (!week) ...[
          if (!_loading &&
              _error == null &&
              _result != null &&
              meetings.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No hay reuniones en este intervalo.'),
            ),
          for (final event in meetings) _meeting(event),
        ],
      ],
    );
  }

  Widget _monthGrid() {
    final first = (_month.weekday - DateTime.monday) % 7;
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          children: [
            Row(
              children: [
                for (final label in ['L', 'M', 'X', 'J', 'V', 'S', 'D'])
                  Expanded(child: Center(child: Text(label))),
              ],
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisExtent: 46,
              ),
              itemCount: first + days,
              itemBuilder: (context, index) {
                if (index < first) return const SizedBox.shrink();
                final day = index - first + 1;
                final date = DateTime(_month.year, _month.month, day);
                final hasMeeting = (_result?.meetings ?? []).any(
                  (e) => _sameDay(e.reunion.fechaInicio.toLocal(), date),
                );
                return Semantics(
                  label:
                      '$day ${_months[_month.month - 1]}${hasMeeting ? ", con reuniones" : ""}',
                  selected: _day == date,
                  child: TextButton(
                    onPressed: () => setState(() => _day = date),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      backgroundColor: _day == date
                          ? Theme.of(context).colorScheme.primaryContainer
                          : null,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('$day'),
                        if (hasMeeting) const Icon(Icons.circle, size: 5),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ─── Vista semanal ─────────────────────────────────────────────────────

  Widget _weekView(List<CalendarMeeting> all) {
    final days = [
      for (var i = 0; i < 7; i++)
        DateTime(_weekStart.year, _weekStart.month, _weekStart.day + i),
    ];
    List<CalendarMeeting> on(DateTime day, {required bool allDay}) => [
      for (final e in all)
        if (e.reunion.todoElDia == allDay &&
            _sameDay(e.reunion.fechaInicio.toLocal(), day))
          e,
    ];
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth < 700
          ? _weekAgenda(days, on)
          : _weekGrid(days, on, box.maxWidth),
    );
  }

  /// Pantallas estrechas: la semana como agenda por días.
  Widget _weekAgenda(
    List<DateTime> days,
    List<CalendarMeeting> Function(DateTime, {required bool allDay}) on,
  ) {
    final today = _today;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, day) in days.indexed) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(
              '${_longDays[i]} ${day.day} de ${_months[day.month - 1].toLowerCase()}'
              '${_sameDay(day, today) ? ' · Hoy' : ''}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: _sameDay(day, today)
                    ? AppColors.accentText
                    : AppColors.text,
              ),
            ),
          ),
          if (on(day, allDay: true).isEmpty && on(day, allDay: false).isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Sin reuniones',
                style: TextStyle(color: AppColors.textSubtle, fontSize: 12),
              ),
            ),
          for (final event in [
            ...on(day, allDay: true),
            ...(on(day, allDay: false)..sort(
              (a, b) => a.reunion.fechaInicio.compareTo(b.reunion.fechaInicio),
            )),
          ])
            _agendaRow(event),
        ],
      ],
    );
  }

  Widget _agendaRow(CalendarMeeting event) {
    final room = event.reunion;
    return Card(
      key: ValueKey('week-event-${room.id}'),
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(event),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 4,
                height: 36,
                decoration: BoxDecoration(
                  color: _statusColor(room),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      room.titulo,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      [
                        meetingTimeRange(room),
                        event.nodeName,
                        if (room.ubicacion?.isNotEmpty == true) room.ubicacion!,
                      ].join(' · '),
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _statusColor(Reunion room) => switch (room.rtcEstado) {
    'active' => AppColors.success,
    'ended' => AppColors.textSubtle,
    _ => AppColors.accent,
  };

  /// Pantallas anchas: 7 columnas con franjas horarias.
  Widget _weekGrid(
    List<DateTime> days,
    List<CalendarMeeting> Function(DateTime, {required bool allDay}) on,
    double width,
  ) {
    final today = _today;
    // Franja visible: de 8:00 a 18:00, ampliada para que quepan las reuniones.
    var first = 8, last = 18;
    for (final day in days) {
      for (final e in on(day, allDay: false)) {
        final (start, end) = meetingBounds(e.reunion);
        if (start.hour < first) first = start.hour;
        final endHour = _sameDay(start, end)
            ? end.hour + (end.minute > 0 ? 1 : 0)
            : 24;
        if (endHour > last) last = endHour;
      }
    }
    final column = (width - _gutter) / 7;
    final hasAllDay = days.any((d) => on(d, allDay: true).isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox(width: _gutter),
            for (final (i, day) in days.indexed)
              SizedBox(
                width: column,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${_shortDays[i]} ${day.day}',
                      key: ValueKey('week-day-$i'),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _sameDay(day, today)
                            ? AppColors.accentText
                            : AppColors.text,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (hasAllDay)
          Container(
            key: const ValueKey('week-all-day'),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: AppColors.line),
                bottom: BorderSide(color: AppColors.line),
              ),
            ),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: _gutter,
                  child: Text(
                    'Todo el día',
                    style: TextStyle(color: AppColors.textSubtle, fontSize: 10),
                  ),
                ),
                for (final day in days)
                  SizedBox(
                    width: column,
                    child: Column(
                      children: [
                        for (final e in on(day, allDay: true))
                          _block(e, compact: true),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        SizedBox(
          height: (last - first) * _hourHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _gutter,
                child: Stack(
                  children: [
                    for (var h = first; h < last; h++)
                      Positioned(
                        top: (h - first) * _hourHeight,
                        left: 0,
                        right: 6,
                        child: Text(
                          '${h.toString().padLeft(2, '0')}:00',
                          key: ValueKey('week-hour-$h'),
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: AppColors.textSubtle,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              for (final day in days)
                SizedBox(
                  width: column,
                  child: _dayColumn(
                    day,
                    on(day, allDay: false),
                    first,
                    last,
                    column,
                    isToday: _sameDay(day, today),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dayColumn(
    DateTime day,
    List<CalendarMeeting> events,
    int first,
    int last,
    double width, {
    required bool isToday,
  }) {
    final top = DateTime(day.year, day.month, day.day, first);
    final bottom = DateTime(day.year, day.month, day.day + 1);
    return Container(
      decoration: BoxDecoration(
        color: isToday ? AppColors.accentTint.withValues(alpha: 0.25) : null,
        border: Border(left: BorderSide(color: AppColors.line)),
      ),
      child: Stack(
        children: [
          for (var h = first; h < last; h++)
            Positioned(
              top: (h - first) * _hourHeight,
              left: 0,
              right: 0,
              child: Divider(height: 1, color: AppColors.line),
            ),
          for (final (event, lane, lanes) in layoutDay(events))
            () {
              final (start, rawEnd) = meetingBounds(event.reunion);
              final end = rawEnd.isAfter(bottom) ? bottom : rawEnd;
              final minutes = start.difference(top).inMinutes;
              final length = end.difference(start).inMinutes;
              final laneWidth = (width - 4) / lanes;
              return Positioned(
                top: minutes / 60 * _hourHeight,
                height: (length < 20 ? 20 : length) / 60 * _hourHeight,
                left: 2 + lane * laneWidth,
                width: laneWidth - 2,
                child: _block(event),
              );
            }(),
        ],
      ),
    );
  }

  /// Reunión en la vista semanal; al tocarla se abre con sus acciones.
  Widget _block(CalendarMeeting event, {bool compact = false}) {
    final room = event.reunion;
    final color = _statusColor(room);
    return Semantics(
      button: true,
      label: '${room.titulo}, ${meetingTimeRange(room)}',
      child: Padding(
        padding: EdgeInsets.only(bottom: compact ? 2 : 0),
        child: Material(
          key: ValueKey('week-event-${room.id}'),
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _open(event),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: color, width: 3)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: ExcludeSemantics(child: _blockText(room, compact)),
            ),
          ),
        ),
      ),
    );
  }

  /// Título y horario; en bloques bajos (texto grande) se recorta sin
  /// desbordar.
  Widget _blockText(Reunion room, bool compact) {
    final title = Text(
      room.titulo,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: AppColors.text,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
    if (compact) return title;
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minHeight: 0,
        maxHeight: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            title,
            Text(
              meetingTimeRange(room),
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Tarjeta de reunión ────────────────────────────────────────────────

  /// Con [close] (vista semanal) se cierra el diálogo antes de cada acción.
  Widget _meeting(CalendarMeeting event, {VoidCallback? close}) {
    final room = event.reunion;
    final start = room.fechaInicio.toLocal();
    final status = switch (room.rtcEstado) {
      'active' => 'En curso',
      'ended' => 'Finalizada',
      _ => 'Programada',
    };
    final mine = room.creadoPor == LivePresence.selfId;
    VoidCallback act(VoidCallback action) => () {
      close?.call();
      action();
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              room.titulo,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Text(event.nodeName),
            Text(
              '${start.day}/${start.month}/${start.year} · ${meetingTimeRange(room)} · $status',
            ),
            if (room.descripcion?.isNotEmpty == true) Text(room.descripcion!),
            Text('Organiza: ${room.creadorNombre}'),
            const SizedBox(height: 4),
            meetingBadges(room),
            // Invitación pendiente de respuesta, como en un calendario de equipo.
            if (!mine &&
                room.miRespuesta != null &&
                room.rtcEstado == 'scheduled') ...[
              const SizedBox(height: 8),
              RsvpButtons(
                reunion: room,
                repository: _meetings,
                onChanged: _load,
              ),
            ],
            Wrap(
              spacing: 4,
              children: [
                if (room.rtcEstado == 'scheduled' && event.canModerate)
                  TextButton.icon(
                    onPressed: act(() => _start(event)),
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('Iniciar reunión'),
                  ),
                if (room.rtcEstado == 'scheduled' && event.canModerate)
                  TextButton.icon(
                    onPressed: act(() => _edit(event)),
                    icon: const Icon(Icons.edit_calendar_outlined),
                    label: const Text('Editar'),
                  ),
                // Enlace (IRL-WKS-US-06) y asistencia (IRL-SEC-US-01/02).
                if (room.rtcEstado != 'ended')
                  TextButton.icon(
                    onPressed: () => showMeetingShareDialog(context, event),
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Compartir enlace'),
                  ),
                if (event.canModerate && room.rtcEstado != 'scheduled')
                  TextButton.icon(
                    onPressed: () => showAttendanceDialog(context, event),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('Asistencia'),
                  ),
                if (event.canModerate && room.rtcEstado == 'scheduled')
                  TextButton.icon(
                    onPressed: act(() => _cancel(event)),
                    icon: const Icon(Icons.event_busy_outlined),
                    label: const Text('Cancelar'),
                  ),
              ],
            ),
            if (room.rtcEstado == 'active')
              ValueListenableBuilder<Map<String, String>>(
                valueListenable: LivePresence.values,
                builder: (context, states, _) => TextButton.icon(
                  onPressed:
                      !event.canJoin || states[LivePresence.selfId] == 'in_call'
                      ? null
                      : act(() => widget.onJoin(event)),
                  icon: const Icon(Icons.video_call_outlined),
                  label: const Text('Unirse ahora'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
