import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'avatar_viewer.dart';
import 'avatar_image_cache.dart';
import '../presence/live_presence.dart';

class UserAvatar extends StatefulWidget {
  final String? avatarUrl;
  final String? avatarColor;
  final String name;
  final String? userId;
  final double size;
  final bool showBorder;
  final Color? borderColor;
  final double borderWidth;
  final double? fontSize;

  /// Al pulsarlo abre la foto en grande con opción de descargarla.
  final bool viewable;

  const UserAvatar({
    super.key,
    this.avatarUrl,
    this.avatarColor,
    required this.name,
    this.userId,
    this.size = 36,
    this.showBorder = false,
    this.borderColor,
    this.borderWidth = 1.5,
    this.fontSize,
    this.viewable = false,
  });

  @override
  State<UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<UserAvatar> {
  ImageProvider<Object>? _imageProvider;

  @override
  void initState() {
    super.initState();
    _imageProvider = AvatarImageCache.shared.providerFor(widget.avatarUrl);
  }

  @override
  void didUpdateWidget(covariant UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.avatarUrl?.trim() != widget.avatarUrl?.trim()) {
      _imageProvider = AvatarImageCache.shared.providerFor(widget.avatarUrl);
    }
  }

  Color _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return AppColors.accentText;
    try {
      final clean = hex.replaceAll('#', '');
      return Color(int.parse('0xFF$clean'));
    } catch (_) {
      return AppColors.accentText;
    }
  }

  String _getInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : 'U';
  }

  @override
  Widget build(BuildContext context) {
    Widget avatar = _buildAvatar();
    if (widget.userId != null) {
      avatar = ValueListenableBuilder<Map<String, String>>(
        valueListenable: LivePresence.values,
        child: avatar,
        builder: (_, states, child) => Stack(
          clipBehavior: Clip.none,
          children: [
            child!,
            Positioned(
              bottom: -1,
              right: -1,
              child: Tooltip(
                message: LivePresence.label(states[widget.userId]),
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: LivePresence.color(states[widget.userId]),
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.surface, width: 2),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (!widget.viewable) return avatar;
    final hasPhoto = widget.avatarUrl?.trim().isNotEmpty == true;
    return Tooltip(
      message: hasPhoto
          ? 'Ver foto de ${widget.name}'
          : 'Ver perfil de ${widget.name}',
      child: Semantics(
        button: true,
        label: 'Ver foto de perfil de ${widget.name}',
        excludeSemantics: true,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => AvatarViewer.show(
            context,
            name: widget.name,
            avatarUrl: widget.avatarUrl,
            avatarColor: widget.avatarColor,
          ),
          child: avatar,
        ),
      ),
    );
  }

  Widget _buildAvatar() {
    final fallbackColor = _parseColor(widget.avatarColor);
    final initials = _getInitials(widget.name);
    final computedFontSize = widget.fontSize ?? (widget.size * 0.38);

    Widget fallbackWidget() {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: fallbackColor.withValues(alpha: 0.2),
          border: widget.showBorder
              ? Border.all(
                  color: widget.borderColor ?? fallbackColor,
                  width: widget.borderWidth,
                )
              : Border.all(
                  color: fallbackColor.withValues(alpha: 0.5),
                  width: 1,
                ),
        ),
        child: Center(
          child: Text(
            initials,
            style: TextStyle(
              color: fallbackColor,
              fontWeight: FontWeight.bold,
              fontSize: computedFontSize,
            ),
          ),
        ),
      );
    }

    final provider = _imageProvider;
    if (provider == null) return fallbackWidget();
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: widget.showBorder
            ? Border.all(
                color: widget.borderColor ?? AppColors.line,
                width: widget.borderWidth,
              )
            : null,
      ),
      child: ClipOval(
        child: Image(
          image: provider,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) => fallbackWidget(),
        ),
      ),
    );
  }
}
