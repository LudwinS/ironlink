import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'storage_facade.dart';

VaultStorage createVaultStorage() => IoVaultStorage();

class IoVaultStorage implements VaultStorage {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    wOptions: WindowsOptions(),
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}
