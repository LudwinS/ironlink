import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/presence/live_presence.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/calendar_repository.dart';
import '../../data/meeting_link.dart';
import '../../data/nodos_repository.dart';
import '../rtc_call_page.dart';

/// Entra a la llamada de una reunión. El ticket RTC vuelve a validar acceso y
/// cupo en el servidor; aquí solo se evita abrir una segunda llamada.
Future<void> joinMeeting(BuildContext context, CalendarMeeting meeting) async {
  if (LivePresence.values.value[LivePresence.selfId] == 'in_call') return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          RtcCallPage(reunion: meeting.reunion, canEnd: meeting.canModerate),
    ),
  );
}

/// Diálogo para compartir una reunión: copiar el enlace o publicarlo en el
/// canal general del nodo, donde lo ven todos los integrantes.
Future<void> showMeetingShareDialog(
  BuildContext context,
  CalendarMeeting meeting, {
  NodosRepository? repository,
}) => showDialog<void>(
  context: context,
  builder: (_) => _MeetingShareDialog(
    meeting: meeting,
    repository: repository ?? NodosRepository(),
  ),
);

class _MeetingShareDialog extends StatefulWidget {
  const _MeetingShareDialog({required this.meeting, required this.repository});
  final CalendarMeeting meeting;
  final NodosRepository repository;

  @override
  State<_MeetingShareDialog> createState() => _MeetingShareDialogState();
}

class _MeetingShareDialogState extends State<_MeetingShareDialog> {
  bool _posting = false;
  String? _status;
  bool _failed = false;

  String get _link => MeetingLink.forMeeting(widget.meeting.reunion.id);

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _link));
    if (mounted) {
      setState(() {
        _failed = false;
        _status = 'Enlace copiado.';
      });
    }
  }

  Future<void> _post() async {
    setState(() {
      _posting = true;
      _status = null;
    });
    try {
      await widget.repository.sendMensaje(
        widget.meeting.reunion.nodoId,
        MeetingLink.announcement(widget.meeting),
      );
      if (!mounted) return;
      setState(() {
        _failed = false;
        _status =
            'Publicado en el canal general de ${widget.meeting.nodeName}.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _status = e.toString().replaceAll('Exception: ', '');
      });
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Compartir reunión'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.meeting.reunion.titulo,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Solo los integrantes de ${widget.meeting.nodeName} podrán abrirlo; el enlace no incluye credenciales.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.line),
              ),
              child: SelectableText(
                _link,
                style: TextStyle(color: AppColors.accentText, fontSize: 13),
              ),
            ),
            if (_status != null) ...[
              const SizedBox(height: 10),
              Semantics(
                liveRegion: true,
                child: Text(
                  _status!,
                  style: TextStyle(
                    color: _failed ? AppColors.errorText : AppColors.textMuted,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
        OutlinedButton.icon(
          onPressed: _posting ? null : _post,
          icon: const Icon(Icons.forum_outlined, size: 18),
          label: Text(_posting ? 'Publicando…' : 'Publicar en el canal'),
        ),
        OutlinedButton.icon(
          onPressed: _copy,
          icon: const Icon(Icons.link_rounded, size: 18),
          label: const Text('Copiar enlace'),
        ),
      ],
    );
  }
}

/// Tarjeta que muestra una reunión enlazada y permite unirse con un clic.
class MeetingLinkCard extends StatefulWidget {
  const MeetingLinkCard({
    super.key,
    required this.reunionId,
    this.repository,
    this.onJoin,
  });

  final String reunionId;
  final MeetingLinkRepository? repository;

  /// Por defecto abre la llamada con [joinMeeting].
  final void Function(CalendarMeeting meeting)? onJoin;

  @override
  State<MeetingLinkCard> createState() => _MeetingLinkCardState();
}

class _MeetingLinkCardState extends State<MeetingLinkCard> {
  late Future<MeetingLookup> _lookup = _load();

  Future<MeetingLookup> _load() =>
      (widget.repository ?? MeetingLinkRepository()).resolve(widget.reunionId);

  @override
  void didUpdateWidget(MeetingLinkCard old) {
    super.didUpdateWidget(old);
    if (old.reunionId != widget.reunionId) _lookup = _load();
  }

  Future<void> _join(CalendarMeeting meeting) async {
    if (widget.onJoin != null) {
      widget.onJoin!(meeting);
    } else {
      await joinMeeting(context, meeting);
    }
    // Al volver de la llamada el estado (en curso/finalizada) pudo cambiar.
    if (!mounted) return;
    setState(() {
      _lookup = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.line),
        ),
        child: FutureBuilder<MeetingLookup>(
          future: _lookup,
          builder: (context, snapshot) {
            final lookup = snapshot.data;
            if (lookup == null) {
              return const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Flexible(child: Text('Cargando reunión…')),
                ],
              );
            }
            return switch (lookup) {
              MeetingUnavailable(:final message) => Row(
                children: [
                  Icon(Icons.event_busy_outlined, color: AppColors.textMuted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      message,
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Reintentar',
                    onPressed: () => setState(() {
                      _lookup = _load();
                    }),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              MeetingFound(:final meeting) => _Details(
                meeting: meeting,
                onJoin: () => _join(meeting),
              ),
            };
          },
        ),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.meeting, required this.onJoin});
  final CalendarMeeting meeting;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final room = meeting.reunion;
    final start = room.fechaInicio.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final when =
        '${start.day}/${start.month}/${start.year} · ${two(start.hour)}:${two(start.minute)}';
    final (status, hint) = switch (room.rtcEstado) {
      'active' => ('En curso', null),
      'ended' => ('Finalizada', 'Esta reunión ya terminó.'),
      _ => ('Programada', 'Podrás unirte cuando un moderador la inicie.'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.event_outlined, color: AppColors.accentText, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                room.titulo,
                style: TextStyle(
                  color: AppColors.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${meeting.nodeName} · $when · $status',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
        const SizedBox(height: 8),
        if (room.rtcEstado == 'active')
          ValueListenableBuilder<Map<String, String>>(
            valueListenable: LivePresence.values,
            builder: (context, states, _) {
              final inCall = states[LivePresence.selfId] == 'in_call';
              return OutlinedButton.icon(
                onPressed: !meeting.canJoin || inCall ? null : onJoin,
                icon: const Icon(Icons.video_call_outlined, size: 18),
                label: Text(
                  inCall
                      ? 'Ya estás en una llamada'
                      : meeting.canJoin
                      ? 'Unirse'
                      : 'No puedes unirte',
                ),
              );
            },
          )
        else
          Text(
            hint!,
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
      ],
    );
  }
}

/// Pantalla que abre un enlace de reunión (ruta `/reunion/:id`), por ejemplo
/// al pegarlo en el navegador.
class MeetingLinkScreen extends StatelessWidget {
  const MeetingLinkScreen({super.key, required this.reunionId});
  final String reunionId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reunión compartida'),
        leading: IconButton(
          tooltip: 'Ir a IronLink',
          onPressed: () => context.go('/home'),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: MeetingLinkCard(reunionId: reunionId),
        ),
      ),
    );
  }
}

/// Muestra el texto de un mensaje y, si enlaza una reunión, su tarjeta.
class MessageWithMeetingLink extends StatelessWidget {
  const MessageWithMeetingLink({
    super.key,
    required this.text,
    required this.child,
  });
  final String text;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final id = MeetingLink.find(text);
    if (id == null) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        MeetingLinkCard(reunionId: id),
      ],
    );
  }
}
