import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'user_avatar.dart';
import 'avatar_image_cache.dart';
import '../../core/notify/iron_notice.dart';
import '../../core/notify/iron_notify.dart';

/// Imagen de perfil decodificada, lista para mostrarse o guardarse.
class AvatarImage {
  AvatarImage(Uint8List bytes, this.extension) : provider = MemoryImage(bytes);
  AvatarImage._(this.provider, this.extension);

  final MemoryImage provider;
  Uint8List get bytes => provider.bytes;
  final String extension;

  /// Las fotos se guardan como `data:image/...;base64,...` (auth/service.rs);
  /// también se admite una URL http(s).
  /// Devuelve null si no hay foto o si no se puede leer (base64 truncado o
  /// corrupto, URL inaccesible), sin propagar la excepción.
  static Future<AvatarImage?> load(String? url) async {
    final value = url?.trim() ?? '';
    if (value.isEmpty) return null;
    try {
      if (value.startsWith('data:image/') || value.contains(';base64,')) {
        final provider = AvatarImageCache.shared.providerFor(value);
        return provider is MemoryImage ? _verified(provider) : null;
      }
      if (value.startsWith('http://') || value.startsWith('https://')) {
        final response = await Dio().get<List<int>>(
          value,
          options: Options(
            responseType: ResponseType.bytes,
            receiveTimeout: const Duration(seconds: 10),
          ),
        );
        final data = response.data;
        if (data == null || data.isEmpty) return null;
        return _verified(MemoryImage(Uint8List.fromList(data)));
      }
    } on FormatException {
      return null;
    } on DioException {
      return null;
    }
    return null;
  }

  /// Solo acepta una imagen completa de un formato conocido: comprueba la
  /// firma inicial y el final del archivo, así un base64 truncado no se
  /// ofrece para descargar. La extensión sale del contenido, no del MIME.
  static AvatarImage? _verified(MemoryImage provider) {
    final b = provider.bytes;
    bool at(int offset, List<int> sig) =>
        offset >= 0 &&
        b.length >= offset + sig.length &&
        Iterable<int>.generate(
          sig.length,
        ).every((i) => b[offset + i] == sig[i]);
    bool endsWith(List<int> sig) => at(b.length - sig.length, sig);
    final String? ext;
    if (at(0, [0x89, 0x50, 0x4E, 0x47]) && endsWith([0xAE, 0x42, 0x60, 0x82])) {
      ext = 'png';
    } else if (at(0, [0xFF, 0xD8, 0xFF]) &&
        // Algunas cámaras dejan relleno tras el marcador de fin (FFD9).
        Iterable<int>.generate(
          64,
        ).any((k) => at(b.length - 2 - k, [0xFF, 0xD9]))) {
      ext = 'jpg';
    } else if (at(0, [0x47, 0x49, 0x46, 0x38]) && endsWith([0x3B])) {
      ext = 'gif';
    } else if (at(0, [0x52, 0x49, 0x46, 0x46]) &&
        at(8, [0x57, 0x45, 0x42, 0x50]) &&
        (b[4] | b[5] << 8 | b[6] << 16 | b[7] << 24) + 8 == b.length) {
      ext = 'webp';
    } else {
      ext = null;
    }
    return ext == null ? null : AvatarImage._(provider, ext);
  }
}

/// Visor a pantalla completa de una foto de perfil, con zoom y descarga.
class AvatarViewer extends StatefulWidget {
  const AvatarViewer({
    super.key,
    required this.name,
    this.avatarUrl,
    this.avatarColor,
  });

  final String name;
  final String? avatarUrl, avatarColor;

  static Future<void> show(
    BuildContext context, {
    required String name,
    String? avatarUrl,
    String? avatarColor,
  }) => showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .85),
    barrierLabel: 'Cerrar foto',
    builder: (_) => AvatarViewer(
      name: name,
      avatarUrl: avatarUrl,
      avatarColor: avatarColor,
    ),
  );

  @override
  State<AvatarViewer> createState() => _AvatarViewerState();
}

class _AvatarViewerState extends State<AvatarViewer> {
  late final Future<AvatarImage?> _image = AvatarImage.load(widget.avatarUrl);
  bool _saving = false;

  String get _fileBase {
    final clean = widget.name
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .replaceAll(RegExp(r'\s+'), '-');
    return 'ironlink-${clean.isEmpty ? 'perfil' : clean.toLowerCase()}';
  }

  Future<void> _download(AvatarImage image) async {
    setState(() => _saving = true);
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: 'Guardar foto de perfil',
        fileName: '$_fileBase.${image.extension}',
        type: FileType.custom,
        allowedExtensions: [image.extension],
        bytes: image.bytes,
      );
      // En web el navegador gestiona la descarga y no devuelve ruta.
      if (path != null || kIsWeb) {
        IronNotify.show(
          IronNotice(
            kind: NoticeKind.success,
            title: path == null
                ? 'Descarga iniciada.'
                : 'Foto guardada en $path',
          ),
        );
      }
    } catch (_) {
      IronNotify.show(
        IronNotice(
          kind: NoticeKind.error,
          title: 'No se pudo guardar la foto.',
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: FutureBuilder<AvatarImage?>(
        future: _image,
        builder: (context, snapshot) {
          final image = snapshot.data;
          final loading = snapshot.connectionState != ConnectionState.done;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          // Siempre sobre el velo oscuro, en cualquier tema.
                          color: Color(0xFFE9E9ED),
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (image != null)
                      OutlinedButton.icon(
                        onPressed: _saving ? null : () => _download(image),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFD2CEFD),
                          side: const BorderSide(color: Color(0xFF9184D9)),
                        ),
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.download_rounded, size: 18),
                        label: const Text('Descargar'),
                      ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Cerrar',
                      onPressed: () => Navigator.of(context).pop(),
                      color: const Color(0xFFE9E9ED),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: GestureDetector(
                  // Pulsar fuera de la foto cierra el visor.
                  onTap: () => Navigator.of(context).pop(),
                  behavior: HitTestBehavior.opaque,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      // La foto ocupa el espacio libre entre la barra y la ayuda.
                      final side = (math.min(box.maxWidth, box.maxHeight) * .9)
                          .clamp(96.0, 640.0);
                      return Center(
                        child: GestureDetector(
                          onTap: () {},
                          child: loading
                              ? const CircularProgressIndicator()
                              : image == null
                              ? _NoPhoto(
                                  widget: widget,
                                  side: side,
                                  failed:
                                      widget.avatarUrl?.trim().isNotEmpty ==
                                      true,
                                )
                              : InteractiveViewer(
                                  maxScale: 5,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(14),
                                    child: Image(
                                      image: image.provider,
                                      gaplessPlayback: true,
                                      width: side,
                                      height: side,
                                      fit: BoxFit.contain,
                                      semanticLabel:
                                          'Foto de perfil de ${widget.name}',
                                    ),
                                  ),
                                ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              if (image != null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 20),
                  child: Text(
                    'Pellizca o usa la rueda del ratón para acercar',
                    style: TextStyle(color: Color(0xFFB2B6CA), fontSize: 12.5),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _NoPhoto extends StatelessWidget {
  const _NoPhoto({
    required this.widget,
    required this.side,
    this.failed = false,
  });
  final AvatarViewer widget;
  final double side;

  /// Había una foto, pero no se pudo leer.
  final bool failed;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      UserAvatar(
        name: widget.name,
        avatarColor: widget.avatarColor,
        size: side * .5,
      ),
      const SizedBox(height: 16),
      Text(
        failed
            ? 'No se pudo cargar la foto de ${widget.name}.'
            : '${widget.name} no tiene foto de perfil.',
        style: const TextStyle(color: Color(0xFFD2CEFD)),
      ),
    ],
  );
}
