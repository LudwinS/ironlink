import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/user_avatar.dart';
import '../../../iam/providers/auth_provider.dart';
import '../../../iam/providers/profile_provider.dart';
import '../../data/nodos_repository.dart';

/// The same destinations are used by the desktop rail and mobile bottom bar.
enum WorkspaceDestination { chats, nodos, buscar, tu, calendario, amigos }

const workspaceLabels = ['Chats', 'Nodos', 'Buscar', 'Tú', 'Agenda', 'Amigos'];
const workspaceIcons = [
  Icons.chat_bubble_outline_rounded,
  Icons.hexagon_outlined,
  Icons.search_rounded,
  Icons.person_outline_rounded,
  Icons.calendar_month_outlined,
  Icons.people_alt_outlined,
];

/// Orden visual de los destinos en el rail y la barra móvil: «Tú» siempre al
/// final. Los índices siguen siendo los de [WorkspaceDestination].
const workspaceNavOrder = [0, 5, 1, 4, 2, 3];

/// Icono del destino con el contador de solicitudes de amistad recibidas
/// (Amigos) o de mensajes de amistad sin leer (Chats).
Widget workspaceNavIcon(
  int index, {
  int pendingFriends = 0,
  int unreadChats = 0,
}) {
  final icon = Icon(workspaceIcons[index]);
  final (count, color) = switch (index) {
    _ when index == WorkspaceDestination.amigos.index => (
      pendingFriends,
      AppColors.error,
    ),
    _ when index == WorkspaceDestination.chats.index => (
      unreadChats,
      AppColors.accent,
    ),
    _ => (0, AppColors.error),
  };
  if (count <= 0) return icon;
  return Badge(
    label: Text(count > 99 ? '99+' : '$count'),
    backgroundColor: color,
    textColor: index == WorkspaceDestination.chats.index ? AppColors.bg : null,
    child: icon,
  );
}

class WorkspaceNavigation extends StatelessWidget {
  const WorkspaceNavigation({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.nodos,
    required this.onOpenNodo,
    required this.onAddNodo,
    this.selectedNodoId,
    this.unread = const {},
    this.pendingFriends = 0,
    this.unreadChats = 0,
  });
  final int selected;
  final ValueChanged<int> onSelect;
  final List<Nodo> nodos;
  final ValueChanged<Nodo> onOpenNodo;
  final VoidCallback onAddNodo;
  final String? selectedNodoId;
  final Map<String, int> unread;

  /// Solicitudes de amistad recibidas sin responder.
  final int pendingFriends;

  /// Mensajes de amistad sin leer.
  final int unreadChats;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.bg,
          border: Border(right: BorderSide(color: AppColors.line)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            _button(0),
            _button(5),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: Divider(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final nodo in nodos)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Tooltip(
                        message: nodo.nombre,
                        child: Semantics(
                          label: nodo.nombre,
                          button: true,
                          selected: selected == 1 && selectedNodoId == nodo.id,
                          child: InkWell(
                            onTap: () => onOpenNodo(nodo),
                            borderRadius: BorderRadius.circular(12),
                            child: SizedBox(
                              height: 46,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  ClipPath(
                                    clipper: _HexagonClipper(),
                                    child: Container(
                                      width: 42,
                                      height: 42,
                                      color:
                                          selected == 1 &&
                                              selectedNodoId == nodo.id
                                          ? AppColors.accentDeep
                                          : AppColors.surface,
                                      alignment: Alignment.center,
                                      child: Text(
                                        initials(nodo.nombre),
                                        style: TextStyle(
                                          color: AppColors.text,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if ((unread[nodo.id] ?? 0) > 0)
                                    Positioned(
                                      top: 1,
                                      right: 0,
                                      child: CircleAvatar(
                                        radius: 5,
                                        backgroundColor: AppColors.accent,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: 'Crear o unirse a un nodo',
                    onPressed: onAddNodo,
                    icon: const Icon(Icons.add_rounded),
                  ),
                  _button(1),
                ],
              ),
            ),
            _button(4),
            _button(2),
            _button(3),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _button(int index) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: IconButton(
      tooltip: workspaceLabels[index],
      onPressed: () => onSelect(index),
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        backgroundColor: selected == index
            ? AppColors.accentDeep.withValues(alpha: .5)
            : Colors.transparent,
        foregroundColor: selected == index
            ? AppColors.accent
            : AppColors.textMuted,
      ),
      icon: index == 3
          ? ProfileNavIcon(selected: selected == index)
          : workspaceNavIcon(
              index,
              pendingFriends: pendingFriends,
              unreadChats: unreadChats,
            ),
    ),
  );
}

/// Foto de la cuenta en el destino «Tú», en lugar de la silueta genérica.
/// Sin foto muestra las iniciales con el color elegido en el perfil.
class ProfileNavIcon extends ConsumerWidget {
  const ProfileNavIcon({super.key, this.selected = false, this.size = 28});
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider.select((s) => s.profile));
    final username = ref.watch(authProvider.select((s) => s.username));
    final name = profile?.name.isNotEmpty == true
        ? profile!.name
        : (username ?? 'Tú');
    return UserAvatar(
      userId: profile?.id,
      avatarUrl: profile?.avatarUrl,
      avatarColor: profile?.avatarColor,
      name: name,
      size: size,
      showBorder: selected,
      borderColor: AppColors.accent,
      borderWidth: 2,
    );
  }
}

String initials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .take(2);
  return parts.isEmpty
      ? '?'
      : parts.map((p) => p.characters.first).join().toUpperCase();
}

class _HexagonClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    for (var i = 0; i < 6; i++) {
      final angle = math.pi * i / 3;
      final x = size.width / 2 + size.width / 2 * math.cos(angle);
      final y = size.height / 2 + size.height / 2 * math.sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path..close();
  }

  @override
  bool shouldReclip(_HexagonClipper oldClipper) => false;
}

class WorkspaceEmpty extends StatelessWidget {
  const WorkspaceEmpty({
    super.key,
    required this.title,
    required this.description,
    this.icon = Icons.chat_bubble_outline_rounded,
    this.action,
  });
  final String title, description;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.textMuted),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, height: 1.5),
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    ),
  );
}
