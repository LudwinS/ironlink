import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/image_compress_helper.dart';
import '../../../../core/widgets/user_avatar.dart';
import 'camera_capture_dialog.dart';
import '../../providers/profile_provider.dart';
import '../../../../core/notify/iron_notice.dart';
import '../../../../core/notify/iron_notify.dart';

class ProfileDialog extends ConsumerStatefulWidget {
  const ProfileDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => const ProfileDialog(),
    );
  }

  @override
  ConsumerState<ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends ConsumerState<ProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _bioCtrl;
  late TextEditingController _statusCtrl;
  String _selectedColor = '#00E5FF';
  String? _customAvatarUrl;
  bool _isCompressingImage = false;
  bool _initialized = false;

  // Password change controllers
  bool _showPasswordChange = false;
  bool _obscureCurrentPass = true;
  bool _obscureNewPass = true;
  bool _obscureConfirmPass = true;
  final _currentPassCtrl = TextEditingController();
  final _newPassCtrl = TextEditingController();
  final _confirmPassCtrl = TextEditingController();

  final List<String> _avatarColors = [
    '#00E5FF', // Cyan
    '#00BFA5', // Mint
    '#8B5CF6', // Purple
    '#F59E0B', // Amber
    '#EF4444', // Red
    '#3B82F6', // Blue
    '#10B981', // Emerald
    '#EC4899', // Pink
  ];

  final List<String> _presetStatuses = [
    '🟢 En línea',
    '🟡 En reunión',
    '🔴 Ocupado',
    '📚 Estudiando',
    '⚡ Desarrollando en IronLink',
    '☕ Tomando un café',
  ];

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _phoneCtrl = TextEditingController();
    _bioCtrl = TextEditingController();
    _statusCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _bioCtrl.dispose();
    _statusCtrl.dispose();
    _currentPassCtrl.dispose();
    _newPassCtrl.dispose();
    _confirmPassCtrl.dispose();
    super.dispose();
  }

  void _populateData() {
    final profile = ref.read(profileProvider).profile;
    if (profile != null && !_initialized) {
      _nameCtrl.text = profile.name;
      _phoneCtrl.text = profile.telefono;
      _bioCtrl.text = profile.bio;
      _statusCtrl.text = profile.statusText;
      _selectedColor = profile.avatarColor.isNotEmpty
          ? profile.avatarColor
          : '#00E5FF';
      _customAvatarUrl = profile.avatarUrl;
      _initialized = true;
    }
  }

  Color _parseColor(String hex) {
    try {
      final clean = hex.replaceAll('#', '');
      return Color(int.parse('0xFF$clean'));
    } catch (_) {
      return AppColors.accentText;
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    IronNotify.show(IronNotice(kind: NoticeKind.error, title: msg));
  }

  Future<void> _showAvatarOptionsModal() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textSubtle,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Foto de Perfil',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.accentText.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.camera_alt_rounded,
                    color: AppColors.accentText,
                  ),
                ),
                title: Text(
                  'Tomar foto con la cámara',
                  style: TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  'Captura una nueva imagen con tu cámara',
                  style: TextStyle(color: AppColors.textSubtle, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _processImageSource(ImageSource.camera);
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.photo_library_rounded,
                    color: AppColors.accent,
                  ),
                ),
                title: Text(
                  'Elegir de la galería o archivos',
                  style: TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  'Formatos admitidos: JPG, PNG, WEBP (< 2 MB)',
                  style: TextStyle(color: AppColors.textSubtle, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _processImageSource(ImageSource.gallery);
                },
              ),
              if (_customAvatarUrl != null)
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.delete_outline_rounded,
                      color: Color(0xFFEF4444),
                    ),
                  ),
                  title: const Text(
                    'Eliminar foto actual',
                    style: TextStyle(
                      color: Color(0xFFEF4444),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _customAvatarUrl = "";
                    });
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _processImageSource(ImageSource source) async {
    try {
      Uint8List? rawBytes;
      String? extensionName;

      if (source == ImageSource.camera) {
        if (!kIsWeb && Platform.isMacOS) {
          rawBytes = await CameraCaptureDialog.show(context);
        } else {
          final picker = ImagePicker();
          final picked = await picker.pickImage(
            source: ImageSource.camera,
            imageQuality: 85,
            maxWidth: 1024,
            maxHeight: 1024,
          );
          if (picked != null) {
            rawBytes = await picked.readAsBytes();
          }
        }
        extensionName = 'jpg';
        if (rawBytes == null) {
          return;
        }
      } else {
        try {
          final picker = ImagePicker();
          final picked = await picker.pickImage(
            source: source,
            imageQuality: 85,
            maxWidth: 1024,
            maxHeight: 1024,
          );
          if (picked != null) {
            rawBytes = await picked.readAsBytes();
            extensionName = picked.name.split('.').last.toLowerCase();
          }
        } catch (pickerErr) {
          // Fallback en caso de plataforma desktop
          final result = await FilePicker.pickFiles(
            type: FileType.image,
            allowMultiple: false,
            withData: true,
          );
          if (result != null && result.files.isNotEmpty) {
            final f = result.files.first;
            rawBytes = f.bytes;
            if (rawBytes == null && f.path != null && !kIsWeb) {
              rawBytes = await File(f.path!).readAsBytes();
            }
            extensionName = f.extension?.toLowerCase();
          }
        }
      }

      if (rawBytes == null || rawBytes.isEmpty) return;

      // Escenario 2b: Validación de formatos de imagen permitidos
      if (extensionName != null &&
          extensionName.isNotEmpty &&
          !['jpg', 'jpeg', 'png', 'webp'].contains(extensionName)) {
        _showError(
          '⚠️ Formato no permitido. Solo se admiten imágenes JPG, JPEG, PNG y WEBP.',
        );
        return;
      }

      // Escenario 2 & Alerta en cliente si la imagen supera los 2 MB
      final sizeBytes = rawBytes.lengthInBytes;
      if (sizeBytes > 2 * 1024 * 1024 && mounted) {
        final sizeMB = (sizeBytes / (1024 * 1024)).toStringAsFixed(2);
        IronNotify.show(IronNotice(kind: NoticeKind.warning, title: 'La foto pesa $sizeMB MB (supera 2 MB). Se comprimirá automáticamente a < 2 MB.'));
      }

      setState(() => _isCompressingImage = true);
      final compressedDataUri =
          await ImageCompressHelper.processAndCompressImage(rawBytes);
      setState(() => _isCompressingImage = false);

      if (compressedDataUri != null) {
        setState(() {
          _customAvatarUrl = compressedDataUri;
        });
        if (mounted) {
          IronNotify.show(IronNotice(kind: NoticeKind.success, title: 'Foto de perfil optimizada y lista (< 2 MB)'));
        }
      } else {
        _showError('No se pudo procesar la imagen seleccionada.');
      }
    } catch (e) {
      setState(() => _isCompressingImage = false);
      _showError('Error al procesar imagen: $e');
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;

    final success = await ref
        .read(profileProvider.notifier)
        .updateProfile(
          name: _nameCtrl.text.trim(),
          telefono: _phoneCtrl.text.trim(),
          bio: _bioCtrl.text.trim(),
          avatarColor: _selectedColor,
          statusText: _statusCtrl.text.trim(),
          avatarUrl: _customAvatarUrl,
        );

    if (success && mounted) {
      IronNotify.show(IronNotice(kind: NoticeKind.success, title: 'Perfil actualizado exitosamente'));
      Navigator.of(context).pop();
    }
  }

  Future<void> _changePassword() async {
    // Sin recortar: la contraseña se compara tal como se registró.
    final current = _currentPassCtrl.text;
    final newPass = _newPassCtrl.text;
    final confirm = _confirmPassCtrl.text;

    if (current.isEmpty) {
      _showError('Ingresa tu contraseña actual.');
      return;
    }
    if (newPass.length < 8) {
      _showError('La nueva contraseña debe tener al menos 8 caracteres.');
      return;
    }
    if (!RegExp(r'[A-Z]').hasMatch(newPass)) {
      _showError(
        'La nueva contraseña debe contener al menos una letra mayúscula.',
      );
      return;
    }
    if (!RegExp(r'[a-z]').hasMatch(newPass)) {
      _showError(
        'La nueva contraseña debe contener al menos una letra minúscula.',
      );
      return;
    }
    if (!RegExp(r'[0-9]').hasMatch(newPass)) {
      _showError('La nueva contraseña debe contener al menos un número.');
      return;
    }
    if (!RegExp(
      r'''[!@#\$%^\&*()_+\-=\[\]{}|;:',.<>?/\\~`]''',
    ).hasMatch(newPass)) {
      _showError(
        'La nueva contraseña debe contener al menos un carácter especial (ej. !@#\$%^&*).',
      );
      return;
    }
    if (newPass == current) {
      _showError(
        'La nueva contraseña debe ser diferente a la contraseña actual.',
      );
      return;
    }
    if (newPass != confirm) {
      _showError('Las contraseñas nuevas no coinciden.');
      return;
    }

    final success = await ref
        .read(profileProvider.notifier)
        .changePassword(currentPassword: current, newPassword: newPass);

    if (success && mounted) {
      IronNotify.show(IronNotice(kind: NoticeKind.success, title: ref.read(profileProvider).successMessage ?? 'Contraseña cambiada correctamente.'));
      setState(() {
        _showPasswordChange = false;
        _currentPassCtrl.clear();
        _newPassCtrl.clear();
        _confirmPassCtrl.clear();
      });
    } else if (mounted) {
      final err =
          ref.read(profileProvider).errorMessage ??
          'Error al cambiar la contraseña.';
      _showError(err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileState = ref.watch(profileProvider);
    _populateData();
    final profile = profileState.profile;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        width: 520,
        constraints: const BoxConstraints(maxHeight: 700),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.person_outline_rounded,
                      color: AppColors.accent,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Mi Perfil y Personalización',
                      style: TextStyle(
                        color: AppColors.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close_rounded,
                      color: AppColors.textMuted,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: AppColors.line, height: 1),

            // Body
            Expanded(
              child: profileState.isLoading && profile == null
                  ? Center(
                      child: CircularProgressIndicator(color: AppColors.accent),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Avatar & Role preview con Foto Personalizada y Compresión
                            Center(
                              child: Column(
                                children: [
                                  Stack(
                                    alignment: Alignment.bottomRight,
                                    children: [
                                      UserAvatar(
                                        userId: profile?.id,
              viewable: true,
                                        avatarUrl: _customAvatarUrl,
                                        avatarColor: _selectedColor,
                                        name: _nameCtrl.text.isNotEmpty
                                            ? _nameCtrl.text
                                            : (profile?.name.isNotEmpty == true
                                                  ? profile!.name
                                                  : 'Usuario'),
                                        size: 78,
                                        showBorder: true,
                                        borderColor: AppColors.accentText,
                                        borderWidth: 2.5,
                                      ),
                                      if (_isCompressingImage)
                                        Positioned.fill(
                                          child: Container(
                                            decoration: const BoxDecoration(
                                              color: Colors.black54,
                                              shape: BoxShape.circle,
                                            ),
                                            child: Center(
                                              child: SizedBox(
                                                width: 24,
                                                height: 24,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color:
                                                          AppColors.accentText,
                                                    ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      Positioned(
                                        bottom: -2,
                                        right: -2,
                                        child: InkWell(
                                          onTap: _isCompressingImage
                                              ? null
                                              : _showAvatarOptionsModal,
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                              color: AppColors.accentText,
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: AppColors.surface,
                                                width: 2,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.35),
                                                  blurRadius: 4,
                                                ),
                                              ],
                                            ),
                                            child: Icon(
                                              Icons.camera_alt_rounded,
                                              color: AppColors.bg,
                                              size: 14,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TextButton.icon(
                                        style: TextButton.styleFrom(
                                          foregroundColor: AppColors.accentText,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 4,
                                          ),
                                          minimumSize: Size.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        icon: const Icon(
                                          Icons.add_a_photo_rounded,
                                          size: 14,
                                        ),
                                        label: Text(
                                          _customAvatarUrl != null
                                              ? 'Cambiar Foto'
                                              : 'Foto / Cámara (< 2MB)',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        onPressed: _isCompressingImage
                                            ? null
                                            : _showAvatarOptionsModal,
                                      ),
                                      if (_customAvatarUrl != null) ...[
                                        const SizedBox(width: 4),
                                        TextButton.icon(
                                          style: TextButton.styleFrom(
                                            foregroundColor: const Color(
                                              0xFFEF4444,
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            minimumSize: Size.zero,
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          icon: const Icon(
                                            Icons.delete_outline_rounded,
                                            size: 14,
                                          ),
                                          label: const Text(
                                            'Quitar',
                                            style: TextStyle(fontSize: 11),
                                          ),
                                          onPressed: () {
                                            setState(() {
                                              _customAvatarUrl = null;
                                            });
                                          },
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.accentText
                                              .withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: Text(
                                          profile?.rol.toUpperCase() ??
                                              'MEMBER',
                                          style: TextStyle(
                                            color: AppColors.accentText,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFF10B981,
                                          ).withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: const Text(
                                          '● ACTIVO',
                                          style: TextStyle(
                                            color: Color(0xFF10B981),
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 20),

                            // Color de Avatar
                            Text(
                              'Color de Avatar',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _avatarColors.map((hex) {
                                final isSelected =
                                    _selectedColor.toUpperCase() ==
                                    hex.toUpperCase();
                                return GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _selectedColor = hex;
                                    });
                                  },
                                  child: Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: _parseColor(hex),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isSelected
                                            ? AppColors.text
                                            : Colors.transparent,
                                        width: 2.5,
                                      ),
                                      boxShadow: isSelected
                                          ? [
                                              BoxShadow(
                                                color: _parseColor(
                                                  hex,
                                                ).withValues(alpha: 0.5),
                                                blurRadius: 8,
                                              ),
                                            ]
                                          : null,
                                    ),
                                    child: isSelected
                                        ? Icon(
                                            Icons.check,
                                            color: AppColors.bg,
                                            size: 18,
                                          )
                                        : null,
                                  ),
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 18),

                            // Estado de Presencia
                            Text(
                              'Estado de Presencia',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextFormField(
                              controller: _statusCtrl,
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 13,
                              ),
                              decoration: _inputDecoration(
                                hint: '¿En qué estás trabajando?',
                                prefixIcon: Icons.mood_rounded,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              children: _presetStatuses.map((st) {
                                return ActionChip(
                                  backgroundColor: AppColors.bg,
                                  side: BorderSide(color: AppColors.line),
                                  label: Text(
                                    st,
                                    style: TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 11,
                                    ),
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _statusCtrl.text = st;
                                    });
                                  },
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 18),

                            // Nombre Completo
                            Text(
                              'Nombre Completo',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextFormField(
                              controller: _nameCtrl,
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 13,
                              ),
                              decoration: _inputDecoration(
                                hint: 'Tu nombre',
                                prefixIcon: Icons.badge_outlined,
                              ),
                              validator: (v) => v == null || v.trim().isEmpty
                                  ? 'Ingresa tu nombre'
                                  : null,
                            ),
                            const SizedBox(height: 16),

                            // Correo electrónico (Read only)
                            Text(
                              'Correo Electrónico',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.bg,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: AppColors.line),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.email_outlined,
                                    color: AppColors.textSubtle,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      profile?.email ?? '',
                                      style: TextStyle(
                                        color: AppColors.textMuted,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  const Icon(
                                    Icons.verified_rounded,
                                    color: Color(0xFF10B981),
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Teléfono
                            Text(
                              'Teléfono',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextFormField(
                              controller: _phoneCtrl,
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 13,
                              ),
                              decoration: _inputDecoration(
                                hint: '+503 12345678',
                                prefixIcon: Icons.phone_outlined,
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Biografía
                            Text(
                              'Biografía / Acerca de mí',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextFormField(
                              controller: _bioCtrl,
                              maxLines: 3,
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 13,
                              ),
                              decoration: _inputDecoration(
                                hint:
                                    'Escribe una breve descripción sobre ti...',
                                prefixIcon: Icons.info_outline_rounded,
                              ),
                            ),
                            const SizedBox(height: 20),

                            // Sección de Contraseña
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Seguridad de la Cuenta',
                                  style: TextStyle(
                                    color: AppColors.text,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                TextButton.icon(
                                  icon: Icon(
                                    _showPasswordChange
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                    color: AppColors.accentText,
                                    size: 18,
                                  ),
                                  label: Text(
                                    _showPasswordChange
                                        ? 'Ocultar'
                                        : 'Cambiar contraseña',
                                    style: TextStyle(
                                      color: AppColors.accentText,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _showPasswordChange =
                                          !_showPasswordChange;
                                    });
                                  },
                                ),
                              ],
                            ),
                            if (_showPasswordChange) ...[
                              const SizedBox(height: 10),
                              TextFormField(
                                controller: _currentPassCtrl,
                                obscureText: _obscureCurrentPass,
                                style: TextStyle(
                                  color: AppColors.text,
                                  fontSize: 13,
                                ),
                                decoration: _inputDecoration(
                                  hint: 'Contraseña actual',
                                  prefixIcon: Icons.lock_outline_rounded,
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscureCurrentPass
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                      color: AppColors.textMuted,
                                      size: 18,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _obscureCurrentPass =
                                            !_obscureCurrentPass;
                                      });
                                    },
                                    tooltip: _obscureCurrentPass
                                        ? 'Mostrar contraseña'
                                        : 'Ocultar contraseña',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              TextFormField(
                                controller: _newPassCtrl,
                                obscureText: _obscureNewPass,
                                style: TextStyle(
                                  color: AppColors.text,
                                  fontSize: 13,
                                ),
                                decoration: _inputDecoration(
                                  hint:
                                      'Nueva contraseña (mín 8 chars, num, símb)',
                                  prefixIcon: Icons.lock_rounded,
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscureNewPass
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                      color: AppColors.textMuted,
                                      size: 18,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _obscureNewPass = !_obscureNewPass;
                                      });
                                    },
                                    tooltip: _obscureNewPass
                                        ? 'Mostrar contraseña'
                                        : 'Ocultar contraseña',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              TextFormField(
                                controller: _confirmPassCtrl,
                                obscureText: _obscureConfirmPass,
                                style: TextStyle(
                                  color: AppColors.text,
                                  fontSize: 13,
                                ),
                                decoration: _inputDecoration(
                                  hint: 'Confirmar nueva contraseña',
                                  prefixIcon: Icons.lock_rounded,
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscureConfirmPass
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                      color: AppColors.textMuted,
                                      size: 18,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _obscureConfirmPass =
                                            !_obscureConfirmPass;
                                      });
                                    },
                                    tooltip: _obscureConfirmPass
                                        ? 'Mostrar contraseña'
                                        : 'Ocultar contraseña',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.accentText,
                                  foregroundColor: AppColors.bg,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                onPressed: _changePassword,
                                child: const Center(
                                  child: Text(
                                    'Actualizar Contraseña',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
            ),

            Divider(color: AppColors.line, height: 1),

            // Footer
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Cancelar',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: AppColors.bg,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: profileState.isLoading ? null : _saveProfile,
                    child: profileState.isLoading
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.bg,
                            ),
                          )
                        : const Text(
                            'Guardar cambios',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String hint,
    required IconData prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.textSubtle, fontSize: 13),
      prefixIcon: Icon(prefixIcon, color: AppColors.textMuted, size: 18),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: AppColors.bg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: AppColors.accent),
      ),
    );
  }
}
