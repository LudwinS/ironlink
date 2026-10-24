import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';
import '../../../core/security/secure_vault.dart';

/// Excepción personalizada para errores de validación con errores por campo.
class FieldValidationException implements Exception {
  final String message;
  final Map<String, String> fieldErrors;

  FieldValidationException({required this.message, required this.fieldErrors});

  @override
  String toString() => message;
}

class IamRepository {
  final Dio _client = ApiClient.instance;

  /// Envía petición de registro al backend de Rust.
  Future<String> register({
    required String name,
    required String email,
    required String phone,
    required String password,
  }) async {
    try {
      final response = await _client.post(
        '/register',
        data: {
          'name': name,
          'email': email,
          'phone': phone,
          'password': password,
        },
      );

      final data = response.data;
      if (data is Map<String, dynamic>) {
        return data['message'] ?? 'Registro exitoso.';
      }
      return response.data.toString();
    } on DioException catch (e) {
      final responseData = e.response?.data;

      // Parsear respuesta JSON estructurada del backend
      if (responseData is Map<String, dynamic>) {
        final fieldErrors = <String, String>{};
        if (responseData['field_errors'] != null && responseData['field_errors'] is Map) {
          (responseData['field_errors'] as Map).forEach((key, value) {
            fieldErrors[key.toString()] = value.toString();
          });
        }

        if (fieldErrors.isNotEmpty) {
          throw FieldValidationException(
            message: responseData['message'] ?? 'Error de validación',
            fieldErrors: fieldErrors,
          );
        }

        throw Exception(responseData['message'] ?? 'Error en el registro');
      }

      throw Exception(e.response?.data?.toString() ?? 'Fallo al conectar con el servidor de registro');
    }
  }

  /// Envía petición de inicio de sesión.
  /// Parsea la respuesta JWT: { access_token, refresh_token, user: { id, name, email, role } }
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    bool rememberMe = false,
  }) async {
    try {
      final response = await _client.post(
        '/login',
        data: {
          'email': email,
          'password': password,
        },
      );

      final data = response.data as Map<String, dynamic>;

      // Extraer tokens
      final accessToken = data['access_token'] as String? ?? '';
      final refreshToken = data['refresh_token'] as String? ?? '';

      // Extraer datos de usuario del objeto anidado 'user'
      final user = data['user'] as Map<String, dynamic>? ?? {};
      final username = user['name'] as String? ?? 'User';
      final userEmail = user['email'] as String? ?? email;
      final role = user['role'] as String? ?? 'Miembro';
      final userId = user['id'] as String? ?? '';

      // Guardar en SecureVault
      await SecureVault.saveAuthData(
        accessToken: accessToken,
        refreshToken: refreshToken,
        username: username,
        email: userEmail,
        role: role,
        userId: userId,
        rememberMe: rememberMe,
      );

      return {
        'username': username,
        'email': userEmail,
        'role': role,
        'userId': userId,
      };
    } on DioException catch (e) {
      final responseData = e.response?.data;
      if (responseData is Map<String, dynamic>) {
        throw Exception(responseData['message'] ?? 'Credenciales incorrectas');
      }
      throw Exception(responseData?.toString() ?? 'Fallo de autenticación de red');
    }
  }

  /// Solicita el envío de verificación (código o enlace).
  /// [method] puede ser 'code' o 'link'.
  Future<String> requestVerification({
    required String email,
    required String method,
  }) async {
    try {
      final response = await _client.post(
        '/request-verification',
        data: {
          'email': email,
          'method': method,
        },
      );

      final data = response.data;
      if (data is Map<String, dynamic>) {
        return data['message'] ?? 'Verificación enviada.';
      }
      return response.data.toString();
    } on DioException catch (e) {
      final responseData = e.response?.data;
      if (responseData is Map<String, dynamic>) {
        throw Exception(responseData['message'] ?? 'Error al solicitar verificación');
      }
      throw Exception(responseData?.toString() ?? 'Error al solicitar verificación');
    }
  }

  /// Verifica el correo con un código OTP de 6 dígitos.
  /// Retorna datos del usuario verificado.
  Future<Map<String, dynamic>> verifyEmail({
    required String email,
    required String code,
  }) async {
    try {
      final response = await _client.post(
        '/verify-email',
        data: {
          'email': email,
          'code': code,
        },
      );

      final data = response.data as Map<String, dynamic>;
      return {
        'name': data['name'] ?? data['user']?['name'] ?? '',
        'email': data['email'] ?? data['user']?['email'] ?? email,
        'carnet': data['carnet'] ?? data['user']?['carnet'] ?? '',
        'status': data['status'] ?? data['user']?['status'] ?? 'Activo',
        'message': data['message'] ?? 'Cuenta verificada exitosamente.',
      };
    } on DioException catch (e) {
      final responseData = e.response?.data;
      if (responseData is Map<String, dynamic>) {
        throw Exception(responseData['message'] ?? 'Código de verificación inválido');
      }
      throw Exception(responseData?.toString() ?? 'Error al verificar el correo');
    }
  }

  /// Verifica el correo mediante un token de enlace.
  /// Retorna datos del usuario verificado.
  Future<Map<String, dynamic>> verifyLink(String token) async {
    try {
      final response = await _client.get('/verify-link/$token');

      final data = response.data as Map<String, dynamic>;
      return {
        'name': data['name'] ?? data['user']?['name'] ?? '',
        'email': data['email'] ?? data['user']?['email'] ?? '',
        'carnet': data['carnet'] ?? data['user']?['carnet'] ?? '',
        'status': data['status'] ?? data['user']?['status'] ?? 'Activo',
        'message': data['message'] ?? 'Cuenta verificada exitosamente.',
      };
    } on DioException catch (e) {
      final responseData = e.response?.data;
      if (responseData is Map<String, dynamic>) {
        throw Exception(responseData['message'] ?? 'Enlace de verificación inválido o expirado');
      }
      throw Exception(responseData?.toString() ?? 'Error al verificar el enlace');
    }
  }

  // ── Sprint 2: IRL-IAM-US-05 (Perfil de Usuario) ─────────────────────────

  /// Obtiene el perfil completo del usuario autenticado
  Future<Map<String, dynamic>> fetchProfile() async {
    try {
      final response = await _client.get('/users/me');
      final data = response.data as Map<String, dynamic>;
      if (data['profile'] != null) {
        return data['profile'] as Map<String, dynamic>;
      }
      throw Exception(data['message'] ?? 'Error al obtener perfil');
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] ?? 'Error de conexión al cargar perfil';
      throw Exception(msg);
    }
  }

  /// Actualiza los datos y personalización del perfil
  Future<Map<String, dynamic>> updateProfile({
    String? name,
    String? telefono,
    String? bio,
    String? avatarColor,
    String? statusText,
    String? avatarUrl,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (name != null) body['name'] = name;
      if (telefono != null) body['telefono'] = telefono;
      if (bio != null) body['bio'] = bio;
      if (avatarColor != null) body['avatar_color'] = avatarColor;
      if (statusText != null) body['status_text'] = statusText;
      if (avatarUrl != null) body['avatar_url'] = avatarUrl;

      final response = await _client.put(
        '/users/me',
        data: body,
      );
      final data = response.data as Map<String, dynamic>;
      if (data['profile'] != null) {
        return data['profile'] as Map<String, dynamic>;
      }
      throw Exception(data['message'] ?? 'Error al actualizar perfil');
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] ?? 'Error al guardar cambios de perfil';
      throw Exception(msg);
    }
  }

  /// Sube la foto de perfil al endpoint dedicado con validación MIME y tamaño (IRL-IAM-US-05)
  Future<String> uploadAvatar({
    required String avatarData,
    String contentType = 'image/jpeg',
  }) async {
    try {
      final response = await _client.post(
        '/users/me/avatar',
        data: {
          'avatar_data': avatarData,
          'content_type': contentType,
        },
      );
      final data = response.data as Map<String, dynamic>;
      return data['avatar_url'] ?? avatarData;
    } on DioException catch (e) {
      final msg = e.response?.data?['message'] ?? 'Error al subir la foto de perfil';
      throw Exception(msg);
    }
  }

  /// Cambia la contraseña del usuario autenticado
  Future<String> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    try {
      final response = await _client.put(
        '/users/me/password',
        data: {
          'current_password': currentPassword,
          'new_password': newPassword,
        },
      );
      final data = response.data as Map<String, dynamic>;
      // El servidor cierra todas las sesiones y entrega una pareja nueva para
      // este dispositivo. Sin guardarla, la sesión terminaba sin aviso en la
      // siguiente renovación (hasta 15 minutos después).
      final access = data['access_token'];
      final refresh = data['refresh_token'];
      final current = await SecureVault.getRefreshToken();
      if (access is String && refresh is String && current != null) {
        await SecureVault.replaceTokens(current, access, refresh);
      }
      return data['message'] ?? 'Contraseña actualizada exitosamente.';
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map<String, dynamic>) {
        if (data['field_errors'] != null && data['field_errors'] is Map) {
          final errs = (data['field_errors'] as Map).values.join('. ');
          throw Exception(errs);
        }
        throw Exception(data['message'] ?? 'Error al cambiar contraseña');
      }
      throw Exception('Error de conexión al cambiar contraseña');
    }
  }

  /// Solicita un código de recuperación de contraseña para un correo
  Future<String> forgotPassword({required String email}) async {
    try {
      final response = await _client.post(
        '/forgot-password',
        data: {
          'email': email,
        },
      );
      final data = response.data as Map<String, dynamic>;
      return data['message'] ?? 'Código de recuperación enviado.';
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map<String, dynamic>) {
        throw Exception(data['message'] ?? 'Error al solicitar código de recuperación');
      }
      throw Exception('Fallo al conectar con el servidor de recuperación');
    }
  }

  /// Restablece la contraseña con el código OTP recibido
  Future<String> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    try {
      final response = await _client.post(
        '/reset-password',
        data: {
          'email': email,
          'code': code,
          'new_password': newPassword,
        },
      );
      final data = response.data as Map<String, dynamic>;
      return data['message'] ?? 'Contraseña restablecida exitosamente.';
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map<String, dynamic>) {
        if (data['field_errors'] != null && data['field_errors'] is Map) {
          final errs = (data['field_errors'] as Map).values.join('. ');
          throw Exception(errs);
        }
        throw Exception(data['message'] ?? 'Código de recuperación inválido o error al restablecer contraseña');
      }
      throw Exception('Fallo al conectar con el servidor para restablecer contraseña');
    }
  }
}
