import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/security/storage_facade.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../core/widgets/user_avatar.dart';
import '../../../iam/presentation/widgets/profile_dialog.dart';
import '../../../iam/providers/auth_provider.dart';
import '../../../iam/providers/profile_provider.dart';
import '../../../../core/notify/iron_notice.dart';
import '../../../../core/notify/iron_notify.dart';

/// Fondo detrás de los mensajes; las burbujas son opacas en todos.
enum ChatBackground {
  plain('Liso'),
  mesh('Malla'),
  gradient('Degradado');

  const ChatBackground(this.label);
  final String label;

  static ChatBackground fromName(Object? name) => ChatBackground.values
      .firstWhere((b) => b.name == name, orElse: () => ChatBackground.plain);
}

class WorkspacePreferences {
  const WorkspacePreferences({
    this.scale = 1,
    this.compact = false,
    this.reduceMotion = false,
    this.chatBackground = ChatBackground.plain,
  });
  final double scale;
  final bool compact, reduceMotion;
  final ChatBackground chatBackground;
}

final workspacePreferencesProvider =
    StateNotifierProvider<WorkspacePreferencesNotifier, WorkspacePreferences>((
      ref,
    ) {
      return WorkspacePreferencesNotifier(
        ref.watch(authProvider.select((s) => s.userId)),
      );
    });

class WorkspacePreferencesNotifier extends StateNotifier<WorkspacePreferences> {
  WorkspacePreferencesNotifier(String? userId)
    : _key = 'workspace_prefs_${userId ?? 'guest'}',
      super(const WorkspacePreferences()) {
    _load();
  }
  final String _key;
  final _storage = VaultStorage.create();
  bool _edited = false;
  Future<void> _load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (!mounted || raw == null || _edited) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      state = WorkspacePreferences(
        scale: ((data['scale'] as num?)?.toDouble() ?? 1).clamp(.85, 1.3),
        compact: data['compact'] == true,
        reduceMotion: data['reduceMotion'] == true,
        chatBackground: ChatBackground.fromName(data['chatBackground']),
      );
    } catch (_) {
      /* Unavailable preference storage must not block messaging. */
    }
  }

  Future<bool> update({
    double? scale,
    bool? compact,
    bool? reduceMotion,
    ChatBackground? chatBackground,
  }) async {
    _edited = true;
    state = WorkspacePreferences(
      scale: (scale ?? state.scale).clamp(.85, 1.3),
      compact: compact ?? state.compact,
      reduceMotion: reduceMotion ?? state.reduceMotion,
      chatBackground: chatBackground ?? state.chatBackground,
    );
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode({
          'scale': state.scale,
          'compact': state.compact,
          'reduceMotion': state.reduceMotion,
          'chatBackground': state.chatBackground.name,
        }),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

class WorkspacePersonal extends ConsumerWidget {
  const WorkspacePersonal({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final profile = ref.watch(profileProvider).profile;
    final prefs = ref.watch(workspacePreferencesProvider);
    Future<void> update({
      double? scale,
      bool? compact,
      bool? reduceMotion,
      ChatBackground? chatBackground,
    }) async {
      final saved = await ref
          .read(workspacePreferencesProvider.notifier)
          .update(
            scale: scale,
            compact: compact,
            reduceMotion: reduceMotion,
            chatBackground: chatBackground,
          );
      if (!saved && context.mounted) {
        IronNotify.show(
          IronNotice(
            kind: NoticeKind.error,
            title:
                'El ajuste se aplicó, pero no se pudo guardar en este dispositivo.',
          ),
        );
      }
    }

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Tú',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: UserAvatar(
            viewable: true,
            avatarUrl: profile?.avatarUrl,
            avatarColor: profile?.avatarColor,
            name: profile?.name.isNotEmpty == true
                ? profile!.name
                : (auth.username ?? 'Tú'),
            size: 48,
          ),
          title: Text(
            profile?.name ?? auth.username ?? 'Tu perfil',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(auth.email ?? ''),
          trailing: OutlinedButton(
            onPressed: () => ProfileDialog.show(context),
            child: const Text('Editar perfil'),
          ),
        ),
        const Divider(height: 40),
        const Text(
          'Apariencia',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'Paleta Nocturne con un único acento morado. El tema se guarda en este dispositivo; el tamaño, la densidad y el movimiento, por cuenta.',
          style: TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: 16),
        const ThemePicker(),
        const SizedBox(height: 24),
        Text('Tamaño del texto · ${(prefs.scale * 100).round()}%'),
        Slider(
          value: prefs.scale,
          min: .85,
          max: 1.3,
          divisions: 9,
          label: '${(prefs.scale * 100).round()}%',
          onChanged: (v) => update(scale: v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Densidad compacta'),
          subtitle: const Text(
            'Reduce el espacio y los avatares en la lista de chats, no el texto.',
          ),
          value: prefs.compact,
          onChanged: (v) => update(compact: v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Reducir movimiento'),
          subtitle: const Text(
            'Desactiva el desplazamiento animado de las conversaciones.',
          ),
          value: prefs.reduceMotion,
          onChanged: (v) => update(reduceMotion: v),
        ),
        const SizedBox(height: 16),
        const Text(
          'Fondo del chat',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          'Se aplica a todos los chats. Las burbujas son opacas para mantener el contraste.',
          style: TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final bg in ChatBackground.values)
              _ChatBackgroundOption(
                background: bg,
                selected: prefs.chatBackground == bg,
                onTap: () => update(chatBackground: bg),
              ),
          ],
        ),
        const Divider(height: 40),
        const Text(
          'Accesibilidad y atajos',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Text(
          '⌘ / Ctrl K: buscar e ir a un nodo\nAlt 1: Chats · Alt 2: Nodos · Alt 3: Buscar · Alt 4: Tú\nMantén pulsado un mensaje directo para responder con una cita.',
          style: TextStyle(height: 1.8, color: AppColors.textMuted),
        ),
        const Divider(height: 40),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.shield_outlined),
          title: Text('Túnel VPN'),
          subtitle: Text(
            'Estado no verificado. IronLink no consulta todavía el estado del túnel del sistema.',
          ),
        ),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => ref.read(authProvider.notifier).logout(),
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Cerrar sesión'),
          ),
        ),
      ],
    );
  }
}

/// Selector de tema con muestra de colores y contraste medido, como en el
/// prototipo. Es un grupo de opciones exclusivas accesible por teclado.
class ThemePicker extends ConsumerWidget {
  const ThemePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(themeProvider);
    return Semantics(
      label: 'Tema',
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final theme in IronTheme.values)
            _ThemeOption(
              theme: theme,
              selected: theme == current,
              onTap: () async {
                final saved = await ref
                    .read(themeProvider.notifier)
                    .select(theme);
                if (!saved && context.mounted) {
                  IronNotify.show(
                    IronNotice(
                      kind: NoticeKind.error,
                      title:
                          'El tema se aplicó, pero no se pudo guardar en este dispositivo.',
                    ),
                  );
                }
              },
            ),
        ],
      ),
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final IronTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = IronPalette.of(theme);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      label: 'Tema ${theme.label}',
      child: SizedBox(
        width: 176,
        child: Material(
          color: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: selected ? AppColors.accent : AppColors.control,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            hoverColor: AppColors.surface2,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 58,
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: p.bg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: p.line),
                    ),
                    alignment: Alignment.bottomLeft,
                    child: Row(
                      children: [
                        Expanded(
                          flex: 45,
                          child: _pill(
                            theme == IronTheme.light ? p.surface : p.surface2,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(flex: 28, child: _pill(p.accent)),
                        const Spacer(flex: 27),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          theme.label,
                          style: TextStyle(
                            color: AppColors.text,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (selected)
                        Icon(
                          Icons.check_circle,
                          size: 18,
                          color: AppColors.accentText,
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    p.contrast,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.45,
                      color: AppColors.textMuted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(Color color) => Container(
    height: 16,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(8),
    ),
  );
}

class _ChatBackgroundOption extends StatelessWidget {
  const _ChatBackgroundOption({
    required this.background,
    required this.selected,
    required this.onTap,
  });

  final ChatBackground background;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      label: 'Fondo ${background.label}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Column(
            children: [
              Container(
                width: 76,
                height: 56,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected ? AppColors.accent : AppColors.control,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: ChatBackdrop(
                  background: background,
                  child: const SizedBox.expand(),
                ),
              ),
              const SizedBox(height: 6),
              Text(background.label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pinta el fondo elegido detrás de una lista de mensajes.
class ChatBackdrop extends ConsumerWidget {
  const ChatBackdrop({super.key, required this.child, this.background});

  final Widget child;

  /// Fondo fijo; si es nulo se usa la preferencia de la cuenta.
  final ChatBackground? background;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ChatBackground bg =
        background ??
        ref.watch(
          workspacePreferencesProvider.select<ChatBackground>(
            (p) => p.chatBackground,
          ),
        );
    return switch (bg) {
      ChatBackground.plain => ColoredBox(color: AppColors.bg, child: child),
      ChatBackground.gradient => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.surface3, AppColors.bg],
          ),
        ),
        child: child,
      ),
      ChatBackground.mesh => CustomPaint(
        painter: _MeshPainter(ground: AppColors.bg, dot: AppColors.line),
        child: child,
      ),
    };
  }
}

class _MeshPainter extends CustomPainter {
  const _MeshPainter({required this.ground, required this.dot});
  final Color ground, dot;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = ground);
    final paint = Paint()..color = dot;
    for (var y = 1.0; y < size.height; y += 10) {
      for (var x = 1.0; x < size.width; x += 10) {
        canvas.drawCircle(Offset(x, y), 1.2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_MeshPainter old) =>
      old.ground != ground || old.dot != dot;
}
