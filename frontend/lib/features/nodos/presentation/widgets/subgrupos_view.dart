import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/subgrupos_repository.dart';
import '../../providers/subgrupos_provider.dart';
import '../../providers/chat_provider.dart';
import 'create_subgrupo_dialog.dart';
import 'edit_subgrupo_dialog.dart';
import 'assign_members_dialog.dart';
import '../../../../core/notify/iron_notice.dart';
import '../../../../core/notify/iron_notify.dart';


class SubgruposView extends ConsumerWidget {
  final String nodoId;
  final void Function(Subgrupo sub)? onOpenChat;

  const SubgruposView({
    super.key,
    required this.nodoId,
    this.onOpenChat,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subgruposState = ref.watch(subgruposProvider(nodoId));

    if (subgruposState.isLoading && subgruposState.subgrupos.isEmpty) {
      return Center(child: CircularProgressIndicator(color: AppColors.accentText));
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
                          Icon(Icons.groups_rounded, color: AppColors.accentText, size: 20),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Subgrupos del Nodo (${subgruposState.subgrupos.length})',
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
                        'Espacios temáticos y equipos de trabajo focalizados',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppColors.textSubtle, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentText,
                    foregroundColor: AppColors.bg,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Nuevo Subgrupo', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  onPressed: () => CreateSubgrupoDialog.show(context, nodoId),
                ),
              ],
            ),
          ),
          Divider(color: AppColors.line, height: 1),

          // Content
          Expanded(
            child: subgruposState.subgrupos.isEmpty
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
                          child: Icon(Icons.group_work_outlined, color: AppColors.textMuted, size: 40),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No hay subgrupos creados todavía',
                          style: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Organiza a tu equipo creando el primer subgrupo de trabajo.',
                          style: TextStyle(color: AppColors.textSubtle, fontSize: 12),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accentText,
                            foregroundColor: AppColors.bg,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Crear Subgrupo', style: TextStyle(fontWeight: FontWeight.w700)),
                          onPressed: () => CreateSubgrupoDialog.show(context, nodoId),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(24),
                    itemCount: subgruposState.subgrupos.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 14),
                    itemBuilder: (context, idx) {
                      final sub = subgruposState.subgrupos[idx];
                      return _SubgrupoCard(
                        sub: sub,
                        nodoId: nodoId,
                        onOpenChat: onOpenChat,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SubgrupoCard extends ConsumerWidget {
  final Subgrupo sub;
  final String nodoId;
  final void Function(Subgrupo sub)? onOpenChat;

  const _SubgrupoCard({
    required this.sub,
    required this.nodoId,
    this.onOpenChat,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void handleOpenChat() {
      if (onOpenChat != null) {
        onOpenChat!(sub);
      } else {
        ref.read(selectedSubgrupoProvider.notifier).state = sub;
      }
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: handleOpenChat,
        borderRadius: BorderRadius.circular(14),
        hoverColor: AppColors.accentText.withValues(alpha: 0.05),
        child: Container(
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
            children: [
              // Icon
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (sub.esPrivado ? AppColors.accentText : AppColors.accent).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  sub.esPrivado ? Icons.lock_rounded : Icons.groups_rounded,
                  color: sub.esPrivado ? AppColors.accentText : AppColors.accent,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),

              // Details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            sub.nombre,
                            style: TextStyle(
                              color: AppColors.text,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: (sub.esPrivado ? AppColors.accentText : AppColors.accent).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            sub.esPrivado ? 'Privado' : 'Público',
                            style: TextStyle(
                              color: sub.esPrivado ? AppColors.accentText : AppColors.accent,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (sub.unreadCount > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEF4444),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '+${sub.unreadCount}',
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (sub.descripcion != null && sub.descripcion!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        sub.descripcion!,
                        style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.people_outline_rounded, color: AppColors.textSubtle, size: 14),
                        const SizedBox(width: 6),
                        Text(
                          '${sub.miembrosCount} ${sub.miembrosCount == 1 ? "integrante" : "integrantes"}',
                          style: TextStyle(color: AppColors.textSubtle, fontSize: 11),
                        ),
                        const SizedBox(width: 16),
                        Icon(Icons.chat_bubble_outline_rounded, color: AppColors.accentText, size: 13),
                        const SizedBox(width: 4),
                        Text(
                          'Chat disponible',
                          style: TextStyle(color: AppColors.accentText, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Actions
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Abrir chat
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentText,
                      foregroundColor: AppColors.bg,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.chat_bubble_rounded, size: 15),
                    label: const Text('Abrir Chat', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                    onPressed: handleOpenChat,
                  ),
                  const SizedBox(width: 8),
                  // Asignar Miembros (Formulario modal multicheckbox)
                  IconButton(
                    icon: Icon(Icons.group_add_rounded, color: AppColors.accentText, size: 19),
                    tooltip: 'Asignar miembros al subgrupo',
                    onPressed: () => AssignMembersDialog.show(
                      context,
                      nodoId: nodoId,
                      subgrupo: sub,
                    ),
                  ),
                  // Editar Subgrupo en caliente
                  IconButton(
                    icon: Icon(Icons.edit_outlined, color: AppColors.textMuted, size: 19),
                    tooltip: 'Editar nombre y descripción en caliente',
                    onPressed: () => EditSubgrupoDialog.show(
                      context,
                      nodoId: nodoId,
                      subgrupo: sub,
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Unirse / Salir
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: sub.isMember ? const Color(0xFFEF4444) : AppColors.accentText,
                      ),
                      foregroundColor: sub.isMember ? const Color(0xFFEF4444) : AppColors.accentText,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: Icon(sub.isMember ? Icons.exit_to_app_rounded : Icons.login_rounded, size: 15),
                    label: Text(
                      sub.isMember ? 'Salir' : 'Unirse',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                    ),
                    onPressed: () async {
                      final success = await ref.read(subgruposProvider(nodoId).notifier).toggleJoin(sub);
                      if (!success && context.mounted) {
                        final err = ref.read(subgruposProvider(nodoId)).errorMessage;
                        if (err != null && err.isNotEmpty) {
                          IronNotify.show(IronNotice(kind: NoticeKind.error, title: err));
                        }
                      }
                    },
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(Icons.delete_outline_rounded, color: AppColors.textSubtle, size: 18),
                    tooltip: 'Eliminar subgrupo',
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor: AppColors.surface,
                          title: Text('¿Eliminar subgrupo?', style: TextStyle(color: AppColors.text, fontSize: 16)),
                          content: Text('Se eliminará "${sub.nombre}" de forma permanente.', style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancelar', style: TextStyle(color: AppColors.textMuted))),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
                              onPressed: () => Navigator.pop(ctx, true),
                              child: Text('Eliminar', style: TextStyle(color: AppColors.text)),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        ref.read(subgruposProvider(nodoId).notifier).deleteSubgrupo(sub.id);
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

