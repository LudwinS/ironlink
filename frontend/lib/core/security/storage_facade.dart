import 'storage_facade_io.dart'
    if (dart.library.html) 'storage_facade_web.dart';

abstract class VaultStorage {
  Future<void> write({required String key, required String value});
  Future<String?> read({required String key});
  Future<void> delete({required String key});

  static VaultStorage create() => createVaultStorage();
}
