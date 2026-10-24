import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/presence/live_presence.dart';
import '../../../../core/security/secure_vault.dart';
import '../../data/reuniones_repository.dart';
import '../../providers/reuniones_provider.dart';
import '../rtc_call_page.dart';
import '../../providers/nodos_provider.dart';
import 'create_reunion_dialog.dart';
import 'meeting_actions.dart';
import '../../../../core/notify/iron_notice.dart';
import '../../../../core/notify/iron_notify.dart';

class ReunionesView extends ConsumerWidget {
  final String nodoId;
  const ReunionesView({super.key, required this.nodoId});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final created = await CreateReunionDialog.show(context, nodoId: nodoId);
    if (created != null) {
      await ref.read(reunionesProvider(nodoId).notifier).loadReuniones();
    }
  }

  /// «Reunirse ahora» en este nodo: la reunión empieza al instante.
  Future<void> _meetNow(BuildContext context, WidgetRef ref) async {
    final nodo = ref
        .read(nodosProvider)
        .nodos
        .where((n) => n.id == nodoId)
        .toList();
    final reunion = await startMeetNow(context, nodos: nodo, nodoId: nodoId);
    if (reunion == null || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RtcCallPage(reunion: reunion, canEnd: true),
      ),
    );
    ref.read(reunionesProvider(nodoId).notifier).loadReuniones();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reunionesState = ref.watch(reunionesProvider(nodoId));

    if (reunionesState.isLoading && reunionesState.reuniones.isEmpty) {
      return Center(child: CircularProgressIndicator(color: AppColors.accent));
    }

    return Container(
      color: AppColors.bg,
      child: Column(
        children: [
          // Sub-header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.video_call_rounded,
                            color: AppColors.accent,
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Reuniones y Sesiones de Nodo (${reunionesState.reuniones.length})',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Videollamadas programadas, clases y revisiones de sprint',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textSubtle,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.videocam_rounded, size: 18),
                  label: const Text('Reunirse ahora'),
                  onPressed: () => _meetNow(context, ref),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.bg,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text(
                    'Nueva reunión',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  onPressed: () => _create(context, ref),
                ),
              ],
            ),
          ),
          Divider(color: AppColors.line, height: 1),

          // Content
          Expanded(
            child: reunionesState.reuniones.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            shape: BoxShape.circle,
                            border: Border.all(color: AppColors.line),
                          ),
                          child: Icon(
                            Icons.event_available_outlined,
                            color: AppColors.textMuted,
                            size: 40,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No hay reuniones programadas',
                          style: TextStyle(
                            color: AppColors.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Programa una sesión síncrona o clase para colaborar con el equipo.',
                          style: TextStyle(
                            color: AppColors.textSubtle,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: AppColors.bg,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(Icons.video_call, size: 16),
                          label: const Text(
                            'Programar Primera Reunión',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          onPressed: () => _create(context, ref),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(24),
                    itemCount: reunionesState.reuniones.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 14),
                    itemBuilder: (context, idx) {
                      final reunion = reunionesState.reuniones[idx];
                      return _ReunionCard(reunion: reunion, nodoId: nodoId);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ReunionCard extends ConsumerWidget {
  final Reunion reunion;
  final String nodoId;
  const _ReunionCard({required this.reunion, required this.nodoId});

  String _formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActive = reunion.rtcEstado == 'active';
    final isEnded = reunion.rtcEstado == 'ended';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Date icon block
          Container(
            width: 52,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.line),
            ),
            child: Column(
              children: [
                Text(
                  reunion.fechaInicio.toLocal().day.toString(),
                  style: TextStyle(
                    color: AppColors.accent,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  _monthName(reunion.fechaInicio.toLocal().month),
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),

          // Main details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      reunion.titulo,
                      style: TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color:
                            (!isEnded ? AppColors.accent : AppColors.textSubtle)
                                .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        isEnded
                            ? 'Finalizada'
                            : (isActive ? '● En curso' : '● Programada'),
                        style: TextStyle(
                          color: !isEnded
                              ? AppColors.accent
                              : AppColors.textMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                if (reunion.descripcion != null &&
                    reunion.descripcion!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    reunion.descripcion!,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.access_time_rounded,
                      color: AppColors.textSubtle,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      reunion.todoElDia
                          ? '${_formatDate(reunion.fechaInicio.toLocal()).split(' ').first} · Todo el día'
                          : '${_formatDate(reunion.fechaInicio.toLocal())}'
                                '${reunion.fechaFin == null ? '' : ' – ${meetingTimeRange(reunion).split(' – ').last}'}',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Icon(
                      Icons.person_pin_circle_outlined,
                      color: AppColors.textSubtle,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Por ${reunion.creadorNombre}',
                      style: TextStyle(
                        color: AppColors.textSubtle,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                meetingBadges(reunion),
                if (reunion.miRespuesta != null &&
                    reunion.rtcEstado == 'scheduled' &&
                    reunion.creadoPor != LivePresence.selfId) ...[
                  const SizedBox(height: 8),
                  RsvpButtons(reunion: reunion),
                ],
              ],
            ),
          ),

          // Action buttons
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (reunion.rtcEstado != 'ended') ...[
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.bg,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.videocam_rounded, size: 16),
                  label: Text(
                    reunion.rtcEstado == 'active'
                        ? 'Entrar a llamada'
                        : 'Iniciar llamada',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  onPressed: () async {
                    try {
                      if (reunion.rtcEstado == 'scheduled') {
                        await ref
                            .read(reunionesRepositoryProvider)
                            .startMeeting(
                              nodoId: nodoId,
                              reunionId: reunion.id,
                            );
                      }
                      if (!context.mounted) return;
                      final canEnd =
                          await SecureVault.getUserId() == reunion.creadoPor;
                      if (!context.mounted) return;
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              RtcCallPage(reunion: reunion, canEnd: canEnd),
                        ),
                      );
                      ref
                          .read(reunionesProvider(nodoId).notifier)
                          .loadReuniones();
                    } catch (_) {
                      if (!context.mounted) return;
                      IronNotify.show(
                        IronNotice(
                          kind: NoticeKind.warning,
                          title:
                              'No puedes iniciar la reunión. Un organizador debe iniciarla primero.',
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(width: 8),
              ],
              if (reunion.rtcEstado == 'scheduled' &&
                  reunion.creadoPor == LivePresence.selfId)
                IconButton(
                  icon: Icon(
                    Icons.edit_calendar_outlined,
                    color: AppColors.textSubtle,
                    size: 18,
                  ),
                  tooltip: 'Editar reunión',
                  onPressed: () async {
                    final updated = await CreateReunionDialog.show(
                      context,
                      editing: reunion,
                    );
                    if (updated != null) {
                      ref
                          .read(reunionesProvider(nodoId).notifier)
                          .loadReuniones();
                    }
                  },
                ),
              IconButton(
                icon: Icon(
                  Icons.delete_outline_rounded,
                  color: AppColors.textSubtle,
                  size: 18,
                ),
                tooltip: 'Cancelar reunión',
                onPressed: () async {
                  final serie = await confirmCancelMeeting(context, reunion);
                  if (serie != null) {
                    ref
                        .read(reunionesProvider(nodoId).notifier)
                        .deleteReunion(reunion.id, serie: serie);
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _monthName(int month) {
    const months = [
      'ENE',
      'FEB',
      'MAR',
      'ABR',
      'MAY',
      'JUN',
      'JUL',
      'AGO',
      'SEP',
      'OCT',
      'NOV',
      'DIC',
    ];
    return months[month - 1];
  }
}
