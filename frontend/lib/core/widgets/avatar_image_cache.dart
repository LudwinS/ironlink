import 'dart:convert';

import 'package:flutter/painting.dart';

/// Conserva bytes y proveedores entre avatares; expulsa el menos usado.
class AvatarImageCache {
  AvatarImageCache({this.capacity = 64}) : assert(capacity > 0);

  static final shared = AvatarImageCache();
  final int capacity;
  final _entries = <String, ImageProvider<Object>?>{};

  ImageProvider<Object>? providerFor(String? url) {
    final value = url?.trim() ?? '';
    if (value.isEmpty) return null;
    if (_entries.containsKey(value)) {
      final provider = _entries.remove(value);
      _entries[value] = provider;
      return provider;
    }

    ImageProvider<Object>? provider;
    if (value.startsWith('data:image/') || value.contains(';base64,')) {
      try {
        final data = value.contains(',') ? value.split(',').last : value;
        provider = MemoryImage(
          base64Decode(data.replaceAll(RegExp(r'\s'), '')),
        );
      } on FormatException {
        // También recordamos datos inválidos para no decodificarlos otra vez.
      }
    } else if (value.startsWith('http://') || value.startsWith('https://')) {
      provider = NetworkImage(value);
    }
    _entries[value] = provider;
    if (_entries.length > capacity) _entries.remove(_entries.keys.first);
    return provider;
  }
}
