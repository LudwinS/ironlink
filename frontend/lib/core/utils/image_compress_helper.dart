import 'dart:convert';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

class ImageCompressHelper {
  /// Tamaño máximo permitido: 2MB (2,097,152 bytes)
  static const int maxSizeBytes = 2 * 1024 * 1024;

  /// Procesa, redimensiona y comprime una imagen cruda (Uint8List)
  /// Retorna un Data URI en base64 ('data:image/jpeg;base64,...')
  /// garantizando que su peso sea muy inferior a 2MB (típicamente 50KB-300KB).
  static Future<String?> processAndCompressImage(Uint8List rawBytes) async {
    try {
      // 1. Decodificar imagen
      img.Image? decoded = img.decodeImage(rawBytes);
      if (decoded == null) return null;

      // 2. Redimensionar si supera 600x600 px (óptimo para avatares en UI y chats)
      if (decoded.width > 600 || decoded.height > 600) {
        decoded = img.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? 600 : null,
          height: decoded.height > decoded.width ? 600 : null,
          interpolation: img.Interpolation.linear,
        );
      }

      // 3. Comprimir a JPEG con calidad inicial 85
      int quality = 85;
      List<int> compressed = img.encodeJpg(decoded, quality: quality);

      // 4. Si supera 2MB (o para optimizar ancho de banda), reducir calidad progresivamente
      while (compressed.length > maxSizeBytes && quality > 20) {
        quality -= 15;
        compressed = img.encodeJpg(decoded, quality: quality);
      }

      // 5. Convertir a Data URI Base64
      final base64Str = base64Encode(compressed);
      return 'data:image/jpeg;base64,$base64Str';
    } catch (e) {
      // En caso de error en decodificación, retornar null para no corromper el estado
      return null;
    }
  }
}
