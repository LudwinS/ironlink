import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/attendance_repository.dart';
import '../../data/calendar_repository.dart';

/// Informe de asistencia de una reunión para moderadores
/// (IRL-SEC-US-01 entradas/salidas, IRL-SEC-US-02 tiempo de participación).
Future<void> showAttendanceDialog(
  BuildContext context,
  CalendarMeeting meeting, {
  AttendanceRepository? repository,
  Future<String?> Function(String fileName, Uint8List bytes)? saveFile,
}) => showDialog<void>(
  context: context,
  builder: (_) => AttendanceDialog(
    meeting: meeting,
    repository: repository ?? AttendanceRepository(),
    saveFile: saveFile ?? _saveWithPicker,
  ),
);

Future<String?> _saveWithPicker(String fileName, Uint8List bytes) =>
    FilePicker.saveFile(
      dialogTitle: 'Guardar asistencia',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      bytes: bytes,
    );

String formatDuration(int seconds) {
  if (seconds < 60) return '$seconds s';
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60;
  return h > 0 ? '$h h ${m.toString().padLeft(2, '0')} min' : '$m min';
}

String _clock(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}:${l.second.toString().padLeft(2, '0')}';
}

class AttendanceDialog extends StatefulWidget {
  const AttendanceDialog({
    super.key,
    required this.meeting,
    required this.repository,
    required this.saveFile,
  });
  final CalendarMeeting meeting;
  final AttendanceRepository repository;
  final Future<String?> Function(String fileName, Uint8List bytes) saveFile;

  @override
  State<AttendanceDialog> createState() => _AttendanceDialogState();
}

class _AttendanceDialogState extends State<AttendanceDialog> {
  late Future<AttendanceReport> _report = _load();
  bool _exporting = false;
  String? _status;
  bool _statusIsError = false;

  Future<AttendanceReport> _load() => widget.repository.fetch(
    widget.meeting.reunion.nodoId,
    widget.meeting.reunion.id,
  );

  void _reload() {
    setState(() {
      _report = _load();
    });
  }

  String get _fileName {
    final d = widget.meeting.reunion.fechaInicio.toLocal();
    final title = widget.meeting.reunion.titulo
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9áéíóúñü]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return 'asistencia-${title.isEmpty ? 'reunion' : title}-'
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.csv';
  }

  Future<void> _export() async {
    setState(() {
      _exporting = true;
      _status = null;
    });
    try {
      final bytes = await widget.repository.csv(
        widget.meeting.reunion.nodoId,
        widget.meeting.reunion.id,
      );
      final path = await widget.saveFile(_fileName, bytes);
      if (!mounted) return;
      setState(() {
        _statusIsError = false;
        _status = path != null
            ? 'CSV guardado en $path'
            : kIsWeb
            ? 'Descarga iniciada.'
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusIsError = true;
        _status = e is AttendanceException
            ? e.message
            : 'No se pudo guardar el CSV.';
      });
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Asistencia · ${widget.meeting.reunion.titulo}'),
      content: SizedBox(
        width: 560,
        child: FutureBuilder<AttendanceReport>(
          future: _report,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    snapshot.error is AttendanceException
                        ? (snapshot.error as AttendanceException).message
                        : 'No se pudo cargar la asistencia.',
                    style: TextStyle(color: AppColors.errorText),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Reintentar'),
                  ),
                ],
              );
            }
            return _ReportView(report: snapshot.data!);
          },
        ),
      ),
      actions: [
        if (_status != null)
          Semantics(
            liveRegion: true,
            child: Text(
              _status!,
              style: TextStyle(
                fontSize: 13,
                color: _statusIsError
                    ? AppColors.errorText
                    : AppColors.textMuted,
              ),
            ),
          ),
        TextButton.icon(
          onPressed: _reload,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Actualizar'),
        ),
        OutlinedButton.icon(
          onPressed: _exporting ? null : _export,
          icon: const Icon(Icons.download_rounded, size: 18),
          label: Text(_exporting ? 'Exportando…' : 'Exportar CSV'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}

class _ReportView extends StatelessWidget {
  const _ReportView({required this.report});
  final AttendanceReport report;

  @override
  Widget build(BuildContext context) {
    final people = report.participants;
    final summary = [
      switch (report.state) {
        'active' => 'En curso',
        'ended' => 'Finalizada',
        _ => 'Aún no inicia',
      },
      if (report.durationSeconds != null)
        'duración ${formatDuration(report.durationSeconds!)}',
      '${people.length} ${people.length == 1 ? 'participante' : 'participantes'}',
    ].join(' · ');

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(summary, style: TextStyle(color: AppColors.textMuted)),
        const SizedBox(height: 4),
        Text(
          'Registro automático del servidor: cada entrada y salida de la sala con su hora. '
          'El tiempo total une las conexiones de cada persona, sin contar dos veces.',
          style: TextStyle(color: AppColors.textSubtle, fontSize: 12.5),
        ),
        const SizedBox(height: 12),
        if (people.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'Nadie se ha unido todavía a esta reunión.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted),
            ),
          )
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in people)
                  _ParticipantTile(
                    participant: p,
                    sessions: report.sessionsOf(p.userId),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({required this.participant, required this.sessions});
  final AttendanceParticipant participant;
  final List<AttendanceSession> sessions;

  @override
  Widget build(BuildContext context) {
    final p = participant;
    final percent = p.percent;
    final entries = '${p.sessions} ${p.sessions == 1 ? 'entrada' : 'entradas'}';
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      title: Row(
        children: [
          Expanded(
            child: Text(
              p.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          if (p.connectedNow)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                'Conectado',
                style: TextStyle(color: AppColors.success, fontSize: 12.5),
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            [
              formatDuration(p.seconds),
              if (percent != null)
                '${percent.toStringAsFixed(percent % 1 == 0 ? 0 : 1)} % de la reunión',
              entries,
            ].join(' · '),
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          if (percent != null) ...[
            const SizedBox(height: 6),
            Semantics(
              label: 'Participación ${percent.round()} por ciento',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: (percent / 100).clamp(0, 1),
                  minHeight: 4,
                  color: AppColors.accent,
                  backgroundColor: AppColors.line,
                ),
              ),
            ),
          ],
        ],
      ),
      children: [
        for (final s in sessions)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(
                  s.open ? Icons.circle : Icons.logout_rounded,
                  size: s.open ? 10 : 16,
                  color: s.open ? AppColors.success : AppColors.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_clock(s.joinedAt)} → ${s.leftAt == null ? 'ahora' : _clock(s.leftAt!)}'
                    ' · ${formatDuration(s.seconds)} · ${AttendanceSession.exitLabel(s.exit)}',
                    style: TextStyle(color: AppColors.text, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
