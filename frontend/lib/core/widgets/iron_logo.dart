import 'package:flutter/material.dart';

/// Logo de IronLink. Los recursos están pensados para fondo oscuro: en el
/// tema claro se oscurecen los grises (que si no se perderían sobre el fondo)
/// manteniendo el morado cercano al acento del tema claro.
class IronLogo extends StatelessWidget {
  const IronLogo.full({super.key, this.width = 220, this.semanticLabel})
    : asset = 'assets/logo-nocturne.png',
      height = null;

  const IronLogo.mark({super.key, double size = 32, this.semanticLabel})
    : asset = 'assets/logo-mark.png',
      width = size,
      height = size;

  final String asset;
  final double? width, height;
  final String? semanticLabel;

  // out = in − 0.767·(r+g+b) + 1.28 por canal: el gris claro (≈0.91) pasa a
  // ≈0.10 y el morado #9184D9 a ≈#5C4DA1, sin tocar la transparencia.
  static const _forLightGround = ColorFilter.matrix([
    0.233, -0.767, -0.767, 0, 326, //
    -0.767, 0.233, -0.767, 0, 326, //
    -0.767, -0.767, 0.233, 0, 326, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      asset,
      width: width,
      height: height,
      fit: BoxFit.contain,
      semanticLabel: semanticLabel,
      excludeFromSemantics: semanticLabel == null,
    );
    // La dependencia del Theme también actualiza las instancias const cuando
    // cambia el tema, incluidos los logos de los avisos superpuestos.
    if (Theme.of(context).brightness == Brightness.dark) return image;
    return ColorFiltered(colorFilter: _forLightGround, child: image);
  }
}
