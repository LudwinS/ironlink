import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera_macos/camera_macos.dart';
import '../../../../core/theme/app_colors.dart';

class CameraCaptureDialog extends StatefulWidget {
  const CameraCaptureDialog({super.key});

  static Future<Uint8List?> show(BuildContext context) {
    return showDialog<Uint8List?>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.8),
      builder: (_) => const CameraCaptureDialog(),
    );
  }

  @override
  State<CameraCaptureDialog> createState() => _CameraCaptureDialogState();
}

class _CameraCaptureDialogState extends State<CameraCaptureDialog> {
  CameraMacOSController? _controller;
  bool _isTakingPhoto = false;
  String? _errorMessage;

  @override
  void dispose() {
    _controller?.destroy();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_controller == null || _isTakingPhoto) return;
    setState(() => _isTakingPhoto = true);

    try {
      final file = await _controller!.takePicture();
      if (file != null && file.bytes != null && file.bytes!.isNotEmpty) {
        if (mounted) {
          Navigator.of(context).pop(file.bytes);
        }
      } else {
        setState(() {
          _isTakingPhoto = false;
          _errorMessage = 'No se recibieron datos de la cámara.';
        });
      }
    } catch (e) {
      setState(() {
        _isTakingPhoto = false;
        _errorMessage = 'Error al capturar foto: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppColors.line, width: 1.5),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 580),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.camera_alt_rounded,
                        color: AppColors.accentText,
                        size: 22,
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Cámara Web',
                        style: TextStyle(
                          color: AppColors.text,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, color: AppColors.textMuted),
                    onPressed: () => Navigator.of(context).pop(null),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Camera Viewport
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        color: Colors.black,
                        width: double.infinity,
                        height: double.infinity,
                        child: CameraMacOSView(
                          key: const ValueKey('camera_macos_preview'),
                          fit: BoxFit.cover,
                          cameraMode: CameraMacOSMode.photo,
                          resolution: PictureResolution.high,
                          isVideoMirrored: true,
                          onCameraLoading: (_) => Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(
                                  color: AppColors.accentText,
                                ),
                                SizedBox(height: 12),
                                Text(
                                  'Activando cámara web...',
                                  style: TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          onCameraInizialized: (controller) {
                            setState(() {
                              _controller = controller;
                            });
                          },
                          onCameraDestroyed: () => Center(
                            child: Text(
                              'Cámara apagada',
                              style: TextStyle(color: AppColors.textSubtle),
                            ),
                          ),
                        ),
                      ),

                      // Overlay circular de encuadre de rostro
                      IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: AppColors.accentText.withValues(
                                alpha: 0.4,
                              ),
                              width: 2,
                            ),
                            shape: BoxShape.circle,
                          ),
                          width: 220,
                          height: 220,
                        ),
                      ),

                      if (_isTakingPhoto)
                        Container(
                          color: Colors.black54,
                          child: Center(
                            child: CircularProgressIndicator(
                              color: AppColors.accent,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              if (_errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  _errorMessage!,
                  style: const TextStyle(
                    color: Color(0xFFEF4444),
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],

              const SizedBox(height: 20),

              // Controls
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textMuted,
                      side: BorderSide(color: AppColors.line),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentText,
                      foregroundColor: AppColors.bg,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: _isTakingPhoto
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.bg,
                            ),
                          )
                        : const Icon(Icons.camera_rounded, size: 20),
                    label: const Text(
                      'Tomar Foto',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    onPressed: _controller != null && !_isTakingPhoto
                        ? _capture
                        : null,
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
