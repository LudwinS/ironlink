import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/nodos_repository.dart';
import '../../data/reuniones_repository.dart';
import '../../../../core/notify/iron_notice.dart';
import '../../../../core/notify/iron_notify.dart';

/// «Reunirse ahora»: pide nodo (si hay varios) y un título opcional, crea la
/// reunión ya iniciada y la devuelve para entrar. Null si se canceló.
Future<Reunion?> startMeetNow(
  BuildContext context, {
  required List<Nodo> nodos,
  String? nodoId,
  ReunionesRepository? repository,
}) async {
  final choice = await showDialog<(String, String)>(
    context: context,
    builder: (_) => _MeetNowDialog(nodos: nodos, nodoId: nodoId),
  );
  if (choice == null || !context.mounted) return null;
  try {
    return await (repository ?? ReunionesRepository()).meetNow(
      nodoId: choice.$1,
      titulo: choice.$2.isEmpty ? null : choice.$2,
    );
  } catch (e) {
    IronNotify.show(
      IronNotice(
        kind: NoticeKind.error,
        title: e.toString().replaceAll('Exception: ', ''),
      ),
    );
    return null;
  }
}

class _MeetNowDialog extends StatefulWidget {
  const _MeetNowDialog({required this.nodos, this.nodoId});
  final List<Nodo> nodos;
  final String? nodoId;
  @override
  State<_MeetNowDialog> createState() => _MeetNowDialogState();
}

class _MeetNowDialogState extends State<_MeetNowDialog> {
  final _title = TextEditingController();
  late String? _node =
      widget.nodoId ?? (widget.nodos.isNotEmpty ? widget.nodos.first.id : null);

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Reunirse ahora'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Empieza una reunión de inmediato, sin programarla. Las personas '
            'del nodo verán el aviso para unirse.',
          ),
          const SizedBox(height: 16),
          if (widget.nodoId == null && widget.nodos.length > 1) ...[
            DropdownButtonFormField<String>(
              initialValue: _node,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Nodo',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final n in widget.nodos)
                  DropdownMenuItem(
                    value: n.id,
                    child: Text(n.nombre, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _node = v),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _title,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Título (opcional)',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton.icon(
        onPressed: _node == null
            ? null
            : () => Navigator.pop(context, (_node!, _title.text.trim())),
        icon: const Icon(Icons.videocam_rounded),
        label: const Text('Empezar reunión'),
      ),
    ],
  );
}

/// Respuesta a una invitación: Asistiré / Tal vez / No asistiré.
class RsvpButtons extends StatefulWidget {
  const RsvpButtons({
    super.key,
    required this.reunion,
    this.repository,
    this.onChanged,
  });
  final Reunion reunion;
  final ReunionesRepository? repository;

  /// Tras guardar la respuesta (p. ej. para recargar el recuento).
  final VoidCallback? onChanged;
  @override
  State<RsvpButtons> createState() => _RsvpButtonsState();
}

class _RsvpButtonsState extends State<RsvpButtons> {
  late String? _answer = widget.reunion.miRespuesta;
  bool _busy = false;

  @override
  void didUpdateWidget(RsvpButtons old) {
    super.didUpdateWidget(old);
    if (old.reunion.miRespuesta != widget.reunion.miRespuesta) {
      _answer = widget.reunion.miRespuesta;
    }
  }

  Future<void> _set(String answer) async {
    var serie = false;
    if (widget.reunion.serieId != null) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Responder a la serie'),
          content: const Text(
            'Esta reunión se repite. ¿Tu respuesta es solo para esta o para '
            'esta y las siguientes?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Solo esta'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Toda la serie'),
            ),
          ],
        ),
      );
      if (choice == null) return;
      serie = choice;
    }
    if (!mounted) return;
    final previous = _answer;
    setState(() {
      _answer = answer;
      _busy = true;
    });
    try {
      await (widget.repository ?? ReunionesRepository()).respond(
        nodoId: widget.reunion.nodoId,
        reunionId: widget.reunion.id,
        respuesta: answer,
        serie: serie,
      );
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _answer = previous);
      IronNotify.show(
        IronNotice(
          kind: NoticeKind.error,
          title: e.toString().replaceAll('Exception: ', ''),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      for (final (value, label, icon) in [
        ('aceptada', 'Asistiré', Icons.check_circle_outline),
        ('tentativa', 'Tal vez', Icons.help_outline),
        ('rechazada', 'No asistiré', Icons.cancel_outlined),
      ])
        ChoiceChip(
          avatar: Icon(icon, size: 16),
          label: Text(label),
          selected: _answer == value,
          onSelected: _busy
              ? null
              // La respuesta elegida se ve seleccionada, no desactivada.
              : (_) {
                  if (_answer != value) _set(value);
                },
        ),
    ],
  );
}

/// Pregunta si cancelar solo esta reunión o toda la serie. Devuelve null si
/// no se cancela; `true` para la serie.
Future<bool?> confirmCancelMeeting(
  BuildContext context,
  Reunion reunion,
) => showDialog<bool>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: const Text('¿Cancelar la reunión?'),
    content: Text(
      reunion.serieId == null
          ? 'Se cancelará «${reunion.titulo}».'
          : '«${reunion.titulo}» se repite. Puedes cancelar solo esta '
                'reunión o todas las que siguen programadas.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('Volver'),
      ),
      if (reunion.serieId != null)
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Toda la serie'),
        ),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
        onPressed: () => Navigator.pop(ctx, false),
        child: Text(reunion.serieId == null ? 'Cancelar reunión' : 'Solo esta'),
      ),
    ],
  ),
);

/// Al guardar cambios en una reunión que se repite: ¿solo esta, esta y las
/// siguientes o toda la serie? Null si se vuelve atrás.
Future<EditScope?> askEditScope(BuildContext context) => showDialog<EditScope>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: const Text('Editar reunión periódica'),
    content: const Text(
      'Esta reunión forma parte de una serie. ¿A cuáles se aplican los '
      'cambios? Las reuniones ya celebradas o en curso no cambian.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('Volver'),
      ),
      for (final scope in EditScope.values)
        scope == EditScope.serie
            ? FilledButton(
                onPressed: () => Navigator.pop(ctx, scope),
                child: Text(scope.label),
              )
            : TextButton(
                onPressed: () => Navigator.pop(ctx, scope),
                child: Text(scope.label),
              ),
    ],
  ),
);

/// Horario legible: «09:00 – 09:45», solo la hora de inicio o «Todo el día».
String meetingTimeRange(Reunion r) {
  if (r.todoElDia) return 'Todo el día';
  String two(int n) => n.toString().padLeft(2, '0');
  String hm(DateTime t) => '${two(t.hour)}:${two(t.minute)}';
  final start = r.fechaInicio.toLocal();
  final end = r.fechaFin?.toLocal();
  return end == null ? hm(start) : '${hm(start)} – ${hm(end)}';
}

/// Etiqueta corta de la respuesta guardada.
Widget meetingBadges(Reunion r) {
  final chips = <(IconData, String)>[
    if (r.ubicacion?.isNotEmpty == true) (Icons.place_outlined, r.ubicacion!),
    if (r.repite) (Icons.repeat_rounded, 'Serie'),
    if (r.privada) (Icons.lock_outline, 'Llamada privada'),
    if (r.espontanea && !r.privada) (Icons.bolt_rounded, 'Instantánea'),
    if (r.invitados > 1)
      (Icons.group_outlined, '${r.aceptados}/${r.invitados} asistirán'),
  ];
  return Wrap(
    spacing: 10,
    runSpacing: 4,
    children: [
      for (final (icon, text) in chips)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: AppColors.textMuted),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
          ],
        ),
    ],
  );
}
