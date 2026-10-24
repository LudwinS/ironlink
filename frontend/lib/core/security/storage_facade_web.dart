// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'storage_facade.dart';

VaultStorage createVaultStorage() => WebVaultStorage();

class WebVaultStorage implements VaultStorage {
  static const _secureStorage = FlutterSecureStorage();

  bool get _hasSubtleCrypto {
    try {
      return html.window.crypto?.subtle != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> write({required String key, required String value}) async {
    if (_hasSubtleCrypto) {
      try {
        await _secureStorage.write(key: key, value: value);
        return;
      } catch (_) {}
    }
    html.window.localStorage['vault_$key'] = value;
  }

  @override
  Future<String?> read({required String key}) async {
    if (_hasSubtleCrypto) {
      try {
        final val = await _secureStorage.read(key: key);
        if (val != null) return val;
      } catch (_) {}
    }
    return html.window.localStorage['vault_$key'];
  }

  @override
  Future<void> delete({required String key}) async {
    if (_hasSubtleCrypto) {
      try {
        await _secureStorage.delete(key: key);
      } catch (_) {}
    }
    html.window.localStorage.remove('vault_$key');
  }
}
