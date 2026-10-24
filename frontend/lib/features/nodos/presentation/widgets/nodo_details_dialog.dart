import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/user_avatar.dart';
import '../../data/nodos_repository.dart';
import '../../providers/nodos_provider.dart';
import '../../../../core/notify/iron_notice.dart';
import '../../../../core/notify/iron_notify.dart';


class NodoDetailsDialog extends ConsumerStatefulWidget {
  final Nodo nodo;
  const NodoDetailsDialog({super.key, required this.nodo});

  @override
  ConsumerState<NodoDetailsDialog> createState() => _NodoDetailsDialogState();
}

class _NodoDetailsDialogState extends ConsumerState<NodoDetailsDialog> {
  List<NodoMiembro>? _miembros;
  List<NodoBaneo>? _baneados;
  bool _loading = true;
  bool _loadingBaneados = false;
  bool _updating = false;
  String? _error;
  Timer? _refreshTimer;
  int _activeTab = 0; // 0 = Participantes, 1 = Baneados

  @override
  void initState() {
    super.initState();
    _fetchMiembros();
    // Iniciar bucle de actualización periódica para el tab activo
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_activeTab == 0) {
        _fetchMiembros(silent: true);
      } else {
        _fetchBaneados(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchMiembros({bool silent = false}) async {
    if (!silent) {
      if (mounted) {
        setState(() {
          _loading = true;
          _error = null;
        });
      }
    }
    try {
      final repo = ref.read(nodosRepositoryProvider);
      final miembros = await repo.fetchMiembros(widget.nodo.id);
      if (mounted) {
        setState(() {
          _miembros = miembros;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceAll('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  Future<void> _fetchBaneados({bool silent = false}) async {
    if (!silent) {
      if (mounted) {
        setState(() {
          _loadingBaneados = true;
          _error = null;
        });
      }
    }
    try {
      final repo = ref.read(nodosRepositoryProvider);
      final baneados = await repo.fetchBaneados(widget.nodo.id);
      if (mounted) {
        setState(() {
          _baneados = baneados;
          _loadingBaneados = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceAll('Exception: ', '');
          _loadingBaneados = false;
        });
      }
    }
  }

  Future<void> _changeRole(String targetUserId, String newRol) async {
    setState(() {
      _updating = true;
    });
    try {
      final repo = ref.read(nodosRepositoryProvider);
      await repo.updateMiembroRol(
        nodoId: widget.nodo.id,
        userId: targetUserId,
        newRol: newRol,
      );
      // Recargar miembros
      await _fetchMiembros(silent: true);
      if (mounted) {
        IronNotify.show(IronNotice(kind: NoticeKind.success, title: 'Rol actualizado a $newRol exitosamente'));
      }
    } catch (e) {
      if (mounted) {
        IronNotify.show(IronNotice(kind: NoticeKind.error, title: e.toString().replaceAll('Exception: ', '')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _updating = false;
        });
      }
    }
  }

  Future<void> _kickMember(String targetUserId, String name) async {
    setState(() {
      _updating = true;
    });
    try {
      final repo = ref.read(nodosRepositoryProvider);
      await repo.kickMiembro(widget.nodo.id, targetUserId);
      await _fetchMiembros(silent: true);
      if (mounted) {
        IronNotify.show(IronNotice(kind: NoticeKind.success, title: 'Usuario $name expulsado exitosamente'));
      }
    } catch (e) {
      if (mounted) {
        IronNotify.show(IronNotice(kind: NoticeKind.error, title: e.toString().replaceAll('Exception: ', '')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _updating = false;
        });
      }
    }
  }

  Future<void> _banMember(String targetUserId, String name) async {
    setState(() {
      _updating = true;
    });
    try {
      final repo = ref.read(nodosRepositoryProvider);
      await repo.banMiembro(widget.nodo.id, targetUserId);
      await _fetchMiembros(silent: true);
      if (mounted) {
        IronNotify.show(IronNotice(kind: NoticeKind.success, title: 'Usuario $name baneado exitosamente'));
      }
    } catch (e) {
      if (mounted) {
        IronNotify.show(IronNotice(kind: NoticeKind.error, title: e.toString().replaceAll('Exception: ', '')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _updating = false;
        });
      }
    }
  }

  Future<void> _unbanUser(String targetUserId, String name) async {
    setState(() {
      _updating = true;
    });
    try {
      final repo = ref.read(nodosRepositoryProvider);
      await repo.unbanMiembro(widget.nodo.id, targetUserId);
      await _fetchBaneados(silent: true);
      if (mounted) {
        IronNotify.show(IronNotice(kind: NoticeKind.success, title: 'Baneo de $name revocado exitosamente'));
      }
    } catch (e) {
      if (mounted) {
        IronNotify.show(IronNotice(kind: NoticeKind.error, title: e.toString().replaceAll('Exception: ', '')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _updating = false;
        });
      }
    }
  }

  Widget _buildRoleBadge(String role) {
    Color color;
    Color bg;
    switch (role.toUpperCase()) {
      case 'OWNER':
        color = const Color(0xFFFBBF24); // Amber
        bg = const Color(0xFFFBBF24).withValues(alpha: 0.15);
        break;
      case 'ADMIN':
        color = AppColors.accentText;
        bg = AppColors.accentText.withValues(alpha: 0.15);
        break;
      default:
        color = AppColors.textMuted;
        bg = AppColors.textMuted.withValues(alpha: 0.15);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Text(
        role,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  /// Salir del nodo (POST /nodos/{id}/leave). El backend ya lo permitía,
  /// pero la interfaz no ofrecía la opción a quien no es propietario.
  Future<void> _confirmLeave(BuildContext parentContext) async {
    final notifier = ref.read(nodosProvider.notifier);
    final navigator = Navigator.of(parentContext);
    final nombre = widget.nodo.nombre;
    final confirmed = await showDialog<bool>(
      context: parentContext,
      builder: (ctx) => AlertDialog(
        title: Text('¿Salir de $nombre?'),
        content: const Text(
          'Dejarás de ver sus canales, mensajes y reuniones. Para volver '
          'necesitarás el token de acceso del nodo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Salir del nodo'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final success = await notifier.leaveNodo(widget.nodo.id);
    if (success) {
      if (mounted) navigator.pop();
      IronNotify.show(IronNotice(kind: NoticeKind.info, title: 'Saliste del nodo "$nombre".'));
    } else {
      IronNotify.show(IronNotice(kind: NoticeKind.error, title: (mounted ? ref.read(nodosProvider).errorMessage : null) ??
                'No se pudo salir del nodo.'));
    }
  }

  void _confirmDelete(BuildContext parentContext) {
    final notifier = ref.read(nodosProvider.notifier);
    final nodoId = widget.nodo.id;
    final nodoNombre = widget.nodo.nombre;

    showDialog(
      context: parentContext,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppColors.line),
        ),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444)),
            SizedBox(width: 10),
            Text('¿Eliminar nodo?', style: TextStyle(color: AppColors.text, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '¿Estás seguro de que deseas eliminar el nodo "$nodoNombre"? Esta acción no se puede deshacer y desconectará a todos los miembros.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancelar', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              if (mounted) {
                Navigator.pop(parentContext);
              }
              final success = await notifier.deleteNodo(nodoId);
              if (success) {
                IronNotify.show(IronNotice(kind: NoticeKind.success, title: 'Nodo "$nodoNombre" eliminado exitosamente'));
              } else {
                IronNotify.show(IronNotice(kind: NoticeKind.error, title: 'Error al eliminar el nodo'));
              }
            },
            child: const Text('Eliminar', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _tabButton(int index, String label) {
    final isActive = _activeTab == index;
    return InkWell(
      onTap: () {
        setState(() {
          _activeTab = index;
        });
        if (index == 1) {
          _fetchBaneados();
        } else {
          _fetchMiembros();
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? AppColors.accent.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isActive ? AppColors.accent.withValues(alpha: 0.3) : Colors.transparent),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? AppColors.accent : AppColors.textMuted,
            fontWeight: FontWeight.bold,
            fontSize: 11,
          ),
        ),
      ),
    );
  }

  Widget _buildBaneadosList() {
    if (_loadingBaneados && _baneados == null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(20.0),
          child: CircularProgressIndicator(color: AppColors.accent),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            _error!,
            style: const TextStyle(color: Color(0xFFEF4444), fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (_baneados == null || _baneados!.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(20.0),
          child: Text(
            'No hay usuarios baneados en este nodo.',
            style: TextStyle(color: AppColors.textSubtle, fontSize: 13),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _baneados!.length,
      separatorBuilder: (_, _) => Divider(color: AppColors.line, height: 1),
      itemBuilder: (context, index) {
        final baneo = _baneados![index];
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          leading: Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Color(0xFFEF4444), Color(0xFFB91C1C)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Center(
              child: Text(
                baneo.name.isNotEmpty ? baneo.name[0].toUpperCase() : 'U',
                style: TextStyle(
                  color: AppColors.text,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          title: Text(
            baneo.name,
            style: TextStyle(
              color: AppColors.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            'Por: ${baneo.creadoPorNombre ?? "Admin"}',
            style: TextStyle(
              color: AppColors.textSubtle,
              fontSize: 11,
            ),
          ),
          trailing: IconButton(
            icon: Icon(Icons.settings_backup_restore_rounded, color: AppColors.accent, size: 18),
            tooltip: 'Desbanear usuario',
            onPressed: () => _unbanUser(baneo.userId, baneo.name),
          ),
        );
      },
    );
  }

  Widget _buildMembersList(String currentUserEmail, bool isCurrentUserOwner, String currentUserNodeRole, bool isGlobalAdmin) {
    if (_loading && _miembros == null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(20.0),
          child: CircularProgressIndicator(color: AppColors.accent),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            _error!,
            style: const TextStyle(color: Color(0xFFEF4444), fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (_miembros == null || _miembros!.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(20.0),
          child: Text(
            'No hay participantes en este nodo.',
            style: TextStyle(color: AppColors.textSubtle, fontSize: 13),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _miembros!.length,
      separatorBuilder: (_, _) => Divider(color: AppColors.line, height: 1),
      itemBuilder: (context, index) {
        final member = _miembros![index];
        final isSelf = member.email == currentUserEmail;
        final nameLabel = isSelf ? '${member.name} (Tú)' : member.name;

        // Check if current user can manage this specific member
        bool canManage = false;
        if (!isSelf) {
          if (isGlobalAdmin || currentUserNodeRole == 'OWNER') {
            canManage = true;
          } else if (currentUserNodeRole == 'ADMIN') {
            canManage = member.rol.toUpperCase() == 'MEMBER';
          }
        }

        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          leading: UserAvatar(
              viewable: true,
            avatarUrl: member.avatarUrl,
            avatarColor: member.avatarColor,
            name: member.name,
            size: 34,
            showBorder: isSelf,
            borderColor: AppColors.accent,
          ),
          title: Text(
            nameLabel,
            style: TextStyle(
              color: AppColors.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            member.statusText?.isNotEmpty == true
                ? '${member.statusText} • ${member.email}'
                : member.email,
            style: TextStyle(
              color: member.statusText?.isNotEmpty == true ? AppColors.accentText : AppColors.textSubtle,
              fontSize: 11,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildRoleBadge(member.rol),
              if (canManage) ...[
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert_rounded, color: AppColors.textMuted, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  color: AppColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: AppColors.line),
                  ),
                  onSelected: (action) {
                    if (action == 'ADMIN') {
                      _changeRole(member.userId, 'ADMIN');
                    } else if (action == 'MEMBER') {
                      _changeRole(member.userId, 'MEMBER');
                    } else if (action == 'KICK') {
                      _kickMember(member.userId, member.name);
                    } else if (action == 'BAN') {
                      _banMember(member.userId, member.name);
                    }
                  },
                  itemBuilder: (ctx) => [
                    if (currentUserNodeRole == 'OWNER' || isGlobalAdmin) ...[
                      PopupMenuItem(
                        value: 'ADMIN',
                        child: Row(
                          children: [
                            Icon(Icons.shield_outlined, color: AppColors.accentText, size: 16),
                            const SizedBox(width: 8),
                            Text(
                              member.rol == 'ADMIN' ? '✓ Administrador' : 'Hacer Administrador',
                              style: TextStyle(color: AppColors.text, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'MEMBER',
                        child: Row(
                          children: [
                            Icon(Icons.person_outline_rounded, color: AppColors.textMuted, size: 16),
                            const SizedBox(width: 8),
                            Text(
                              member.rol == 'MEMBER' ? '✓ Miembro' : 'Hacer Miembro',
                              style: TextStyle(color: AppColors.text, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      const PopupMenuDivider(height: 1),
                    ],
                    PopupMenuItem(
                      value: 'KICK',
                      child: Row(
                        children: [
                          const Icon(Icons.gavel_rounded, color: Colors.orange, size: 16),
                          const SizedBox(width: 8),
                          const Text(
                            'Expulsar',
                            style: TextStyle(color: Colors.orange, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'BAN',
                      child: Row(
                        children: [
                          const Icon(Icons.block_rounded, color: Colors.red, size: 16),
                          const SizedBox(width: 8),
                          const Text(
                            'Banear',
                            style: TextStyle(color: Colors.red, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUserEmail = ref.watch(userEmailProvider);
    final globalRole = ref.watch(userRoleProvider);
    final currentUserNodeRole = widget.nodo.rol?.toUpperCase() ?? 'MEMBER';
    final isGlobalAdmin = globalRole.toUpperCase() == 'ADMIN';
    final isCurrentUserOwner = currentUserNodeRole == 'OWNER' || isGlobalAdmin;
    final isOwnerOrAdmin = currentUserNodeRole == 'OWNER' || currentUserNodeRole == 'ADMIN' || isGlobalAdmin;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: 480,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.line, width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header: Nombre del nodo + botón cerrar
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.hub_rounded, color: AppColors.accent, size: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.nodo.nombre,
                            style: TextStyle(
                              color: AppColors.text,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Token: IRL-${widget.nodo.tokenAcceso.length > 8 ? widget.nodo.tokenAcceso.substring(0, 8).toUpperCase() : widget.nodo.tokenAcceso.toUpperCase()}',
                            style: TextStyle(
                              color: AppColors.textSubtle,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close_rounded, color: AppColors.textMuted),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Descripción
                if (widget.nodo.descripcion != null && widget.nodo.descripcion!.isNotEmpty) ...[
                  Text(
                    widget.nodo.descripcion!,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 20),
                ],

                // Fila de Token y Copiar
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.nodo.tokenAcceso,
                          style: TextStyle(
                            color: AppColors.accent,
                            fontFamily: 'monospace',
                            fontSize: 12,
                            letterSpacing: 0.5,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.copy_rounded, color: AppColors.textMuted, size: 16),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'Copiar token de acceso completo',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: widget.nodo.tokenAcceso));
                          IronNotify.show(IronNotice(kind: NoticeKind.success, title: 'Token de acceso copiado'));
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Tab Selection / Lista de Participantes Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (isOwnerOrAdmin) ...[
                      Flexible(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _tabButton(0, 'Participantes (${_miembros?.length ?? widget.nodo.miembrosCount})'),
                              const SizedBox(width: 8),
                              _tabButton(1, 'Baneados (${_baneados?.length ?? 0})'),
                            ],
                          ),
                        ),
                      ),
                    ] else ...[
                      Flexible(
                        child: Text(
                          'PARTICIPANTES (${_miembros?.length ?? widget.nodo.miembrosCount})',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textSubtle,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                    ],
                    if (_updating)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                      ),
                  ],
                ),
                const SizedBox(height: 10),

                // Lista de Participantes body / Baneados body
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.bg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.line),
                    ),
                    child: _activeTab == 0
                        ? _buildMembersList(currentUserEmail, isCurrentUserOwner, currentUserNodeRole, isGlobalAdmin)
                        : _buildBaneadosList(),
                  ),
                ),
                const SizedBox(height: 20),

                // Botones del Diálogo
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.textMuted,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cerrar'),
                    ),
                    if (currentUserNodeRole != 'OWNER') ...[
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFEF4444),
                          side: const BorderSide(color: Color(0xFFEF4444)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.logout_rounded, size: 16),
                        label: const Text('Salir del nodo'),
                        onPressed: () => _confirmLeave(context),
                      ),
                    ],
                    if (isCurrentUserOwner) ...[
                      const SizedBox(width: 12),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFEF4444),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.delete_outline_rounded, size: 16),
                        label: const Text('Eliminar nodo', style: TextStyle(fontWeight: FontWeight.w700)),
                        onPressed: () => _confirmDelete(context),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
