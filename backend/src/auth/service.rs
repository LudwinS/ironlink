use argon2::{
    Argon2,
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString, rand_core::OsRng},
};
use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::auth::verification::AppState;

// ─── DTOs ────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct RegisterUserDto {
    pub name: String,
    pub email: String,
    pub phone: String,
    pub password: String,
}

#[derive(Deserialize)]
pub struct LoginDto {
    pub email: String,
    pub password: String,
}

#[derive(Serialize, Default)]
pub struct ApiResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub field_errors: Option<HashMap<String, String>>,
}

#[derive(Serialize, Default)]
pub struct LoginResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub access_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user: Option<LoginUserInfo>,
}

#[derive(Serialize)]
pub struct LoginUserInfo {
    pub id: Uuid,
    pub name: String,
    pub email: String,
    pub role: String,
}

#[derive(Deserialize)]
pub struct ChangeRoleDto {
    pub role: String,
}

// ─── Validación de contraseña ────────────────────────────────────────────

/// Valida la contraseña para un campo específico y retorna un mapa de errores por campo.
/// Si el mapa está vacío, la contraseña cumple todos los criterios de seguridad.
pub fn validate_password_field(password: &str, field_name: &str) -> HashMap<String, String> {
    let mut errors: Vec<String> = Vec::new();

    if password.chars().count() < 8 {
        errors.push("Debe tener al menos 8 caracteres".to_string());
    }
    if !password.chars().any(|c| c.is_uppercase()) {
        errors.push("Debe contener al menos una letra mayúscula".to_string());
    }
    if !password.chars().any(|c| c.is_lowercase()) {
        errors.push("Debe contener al menos una letra minúscula".to_string());
    }
    if !password.chars().any(|c| c.is_numeric()) {
        errors.push("Debe contener al menos un número".to_string());
    }
    if !password
        .chars()
        .any(|c| c.is_ascii_punctuation() || (!c.is_alphanumeric() && !c.is_whitespace()))
    {
        errors.push("Debe contener al menos un carácter especial (ej. !@#$%^&*()_+-=)".to_string());
    }

    let mut field_errors = HashMap::new();
    if !errors.is_empty() {
        field_errors.insert(field_name.to_string(), errors.join(". "));
    }
    field_errors
}

/// Valida la contraseña por defecto con clave "password"
pub fn validate_password(password: &str) -> HashMap<String, String> {
    validate_password_field(password, "password")
}

/// Valida el teléfono con prefijo internacional (ej. +50312345678). Lo usan
/// el registro y la edición del perfil.
fn phone_error(phone: &str) -> Option<&'static str> {
    if phone.is_empty() {
        Some("El teléfono es requerido.")
    } else if !phone.starts_with('+') || !phone[1..].chars().all(|c| c.is_ascii_digit()) {
        Some("El formato del teléfono debe incluir el prefijo internacional (ej: +50312345678).")
    } else if !(8..=17).contains(&phone.chars().count()) {
        Some("Longitud de número de teléfono inválida.")
    } else {
        None
    }
}

/// Formato de correo. Compatible con el cliente (`^\S+@\S+\.\S+$`, en
/// `validateEmail`) y algo más estricto: una sola «@», sin caracteres de
/// control, dominio con punto y sin etiquetas vacías («a@b..com»), y como
/// máximo 254 caracteres (RFC 5321). Recibe el correo ya recortado.
fn is_valid_email(email: &str) -> bool {
    let Some((local, domain)) = email.split_once('@') else {
        return false;
    };
    email.chars().count() <= 254
        && !email.chars().any(|c| c.is_whitespace() || c.is_control())
        && !local.is_empty()
        && !domain.contains('@')
        && domain.contains('.')
        && domain.split('.').all(|label| !label.is_empty())
}

// ─── POST /register ──────────────────────────────────────────────────────

pub async fn register_user(
    State(state): State<AppState>,
    Json(payload): Json<RegisterUserDto>,
) -> (StatusCode, Json<ApiResponse>) {
    let mut field_errors = HashMap::new();

    // 1. Validar nombre
    let trimmed_name = payload.name.trim();
    if trimmed_name.is_empty() {
        field_errors.insert(
            "name".to_string(),
            "El nombre no puede estar vacío.".to_string(),
        );
    } else if trimmed_name.chars().count() < 2 {
        field_errors.insert(
            "name".to_string(),
            "El nombre debe tener al menos 2 caracteres.".to_string(),
        );
    }

    // 2. Validar email
    // Los correos se guardan en minúsculas: el login no distingue mayúsculas
    // y dos cuentas no deben diferir solo en eso.
    let trimmed_email = payload.email.trim().to_lowercase();
    if trimmed_email.is_empty() {
        field_errors.insert(
            "email".to_string(),
            "El correo electrónico es requerido.".to_string(),
        );
    } else if !is_valid_email(&trimmed_email) {
        field_errors.insert(
            "email".to_string(),
            "Formato de correo electrónico inválido.".to_string(),
        );
    }

    // 3. Validar teléfono (esperado con prefijo internacional, ej. +50312345678)
    let trimmed_phone = payload.phone.trim();
    if let Some(error) = phone_error(trimmed_phone) {
        field_errors.insert("phone".to_string(), error.to_string());
    }

    // 4. Validar contraseña con criterios de seguridad
    let password_errors = validate_password(&payload.password);
    if let Some(err) = password_errors.get("password") {
        field_errors.insert("password".to_string(), err.clone());
    }

    if !field_errors.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ApiResponse {
                success: false,
                message: "Datos de registro inválidos.".to_string(),
                field_errors: Some(field_errors),
            }),
        );
    }

    // 5. Buscar si ya existe el correo o teléfono en la base de datos
    let mut stale_pending: Vec<Uuid> = Vec::new();
    let existing_users = sqlx::query_as::<_, (Uuid, String, String, String, bool)>(
        "SELECT id, email, telefono, estado::TEXT, created_at < NOW() - INTERVAL '24 hours'
         FROM users WHERE LOWER(TRIM(email)) = $1 OR telefono = $2",
    )
    .bind(&trimmed_email)
    .bind(trimmed_phone)
    .fetch_all(&state.pool)
    .await;

    match existing_users {
        Ok(users) => {
            let mut conflict_errors = HashMap::new();
            for (id, email, phone, estado, abandoned) in users {
                // Un registro pendiente queda reservado 24 horas. Antes se
                // borraba al instante: cualquiera podía bloquear el registro
                // de otra persona o reemplazar su contraseña antes de que ella
                // verificara el correo. Pasado el plazo se considera abandonado.
                if estado == "PENDING" && abandoned {
                    stale_pending.push(id);
                    continue;
                }
                let pending = estado == "PENDING";
                if email.trim().to_lowercase() == trimmed_email {
                    conflict_errors.insert(
                        "email".to_string(),
                        if pending {
                            "Ya hay un registro pendiente con este correo. Revisa tu bandeja para verificarlo o usa «¿La olvidaste?» para crear una contraseña nueva."
                        } else {
                            "Este correo electrónico ya está registrado."
                        }
                        .to_string(),
                    );
                }
                if phone == trimmed_phone {
                    conflict_errors.insert(
                        "phone".to_string(),
                        if pending {
                            "Este número tiene un registro pendiente de verificación."
                        } else {
                            "Este número de teléfono ya está registrado."
                        }
                        .to_string(),
                    );
                }
            }
            if !conflict_errors.is_empty() {
                return (
                    StatusCode::CONFLICT,
                    Json(ApiResponse {
                        success: false,
                        message: "No se pudo completar el registro por datos duplicados."
                            .to_string(),
                        field_errors: Some(conflict_errors),
                    }),
                );
            }
        }
        Err(e) => {
            eprintln!("Error al verificar usuarios existentes: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                ApiResponse::failure(
                    "Error interno del servidor al validar credenciales existentes.",
                ),
            );
        }
    }

    // 6. Hashear la contraseña con Argon2
    let salt = SaltString::generate(&mut OsRng);
    let argon2 = Argon2::default();

    let password_hash = match argon2.hash_password(payload.password.as_bytes(), &salt) {
        Ok(hash) => hash.to_string(),
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                ApiResponse::failure("Error interno del servidor al procesar la contraseña."),
            );
        }
    };

    // 7. Insertar en la base de datos (estado PENDING hasta verificación)
    // Los pendientes abandonados se reemplazan en la misma transacción.
    let insert_result: Result<(), sqlx::Error> = async {
        let mut tx = state.pool.begin().await?;
        sqlx::query("DELETE FROM users WHERE id = ANY($1) AND estado = 'PENDING'")
            .bind(&stale_pending)
            .execute(&mut *tx)
            .await?;
        sqlx::query("INSERT INTO users (name, email, telefono, password) VALUES ($1, $2, $3, $4)")
            .bind(trimmed_name)
            .bind(&trimmed_email)
            .bind(trimmed_phone)
            .bind(&password_hash)
            .execute(&mut *tx)
            .await?;
        tx.commit().await
    }
    .await;

    match insert_result {
        Ok(_) => (
            StatusCode::CREATED,
            Json(ApiResponse {
                success: true,
                message: "Registro exitoso. Verifica tu correo electrónico para activar tu cuenta."
                    .to_string(),
                field_errors: None,
            }),
        ),
        Err(e) => {
            let error_string = e.to_string();
            let mut conflict_errors = HashMap::new();

            if error_string.contains("users_email_key") {
                conflict_errors.insert(
                    "email".to_string(),
                    "Este correo electrónico ya está registrado.".to_string(),
                );
            } else if error_string.contains("users_telefono_key") {
                conflict_errors.insert(
                    "phone".to_string(),
                    "Este número de teléfono ya está registrado.".to_string(),
                );
            }

            let status = if !conflict_errors.is_empty() {
                StatusCode::CONFLICT
            } else {
                StatusCode::INTERNAL_SERVER_ERROR
            };

            let message = if !conflict_errors.is_empty() {
                "No se pudo completar el registro por datos duplicados.".to_string()
            } else {
                "Error interno del servidor al registrar el usuario.".to_string()
            };

            (
                status,
                Json(ApiResponse {
                    success: false,
                    message,
                    field_errors: if conflict_errors.is_empty() {
                        None
                    } else {
                        Some(conflict_errors)
                    },
                }),
            )
        }
    }
}

// ─── POST /login ─────────────────────────────────────────────────────────

pub async fn login(
    State(state): State<AppState>,
    Json(payload): Json<LoginDto>,
) -> (StatusCode, Json<LoginResponse>) {
    // 1. Normalizar email y buscar al usuario
    let email_normalized = payload.email.trim().to_lowercase();
    let user = sqlx::query_as::<_, (Uuid, String, String, String, String, i32, Option<chrono::DateTime<chrono::Utc>>, String)>(
        "SELECT id, name, email, password, rol::TEXT, COALESCE(intentos_fallidos, 0), bloqueado_hasta, estado::TEXT FROM users WHERE LOWER(TRIM(email)) = $1"
    )
    .bind(&email_normalized)
    .fetch_optional(&state.pool)
    .await;

    let (user_id, name, email, password_hash, role, intentos_fallidos, bloqueado_hasta, status) =
        match user {
            Ok(Some(u)) => u,
            Ok(None) => {
                return (
                    StatusCode::UNAUTHORIZED,
                    LoginResponse::failure("Credenciales inválidas."),
                );
            }
            Err(e) => {
                eprintln!("Error al buscar usuario: {}", e);
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    LoginResponse::failure("Error interno del servidor."),
                );
            }
        };

    // 2. Cuenta bloqueada temporalmente por intentos fallidos
    if let Some(bloqueado) = bloqueado_hasta
        && bloqueado > Utc::now()
    {
        return (
            StatusCode::FORBIDDEN,
            LoginResponse::failure(
                "Cuenta bloqueada temporalmente por demasiados intentos fallidos. Intenta más tarde.",
            ),
        );
    }

    // 3. Verificar contraseña con Argon2 antes de revelar el estado de la cuenta
    let parsed_hash = match PasswordHash::new(&password_hash) {
        Ok(h) => h,
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                LoginResponse::failure("Error interno al procesar credenciales."),
            );
        }
    };

    if Argon2::default()
        .verify_password(payload.password.as_bytes(), &parsed_hash)
        .is_err()
    {
        // Incremento atómico: intentos simultáneos no pueden saltarse el
        // bloqueo. Si un bloqueo anterior ya venció, la cuenta empieza de nuevo.
        let intentos: i32 = sqlx::query_scalar(
            "UPDATE users u SET intentos_fallidos = n.v,
                    bloqueado_hasta = CASE WHEN n.v >= 5 THEN NOW() + INTERVAL '15 minutes' ELSE NULL END
             FROM (SELECT id, CASE WHEN bloqueado_hasta IS NOT NULL AND bloqueado_hasta <= NOW() THEN 1
                                   ELSE COALESCE(intentos_fallidos, 0) + 1 END AS v
                   FROM users WHERE id = $1 FOR UPDATE) n
             WHERE u.id = n.id RETURNING u.intentos_fallidos",
        )
        .bind(user_id)
        .fetch_one(&state.pool)
        .await
        .unwrap_or_else(|e| {
            eprintln!("Error al actualizar intentos fallidos: {}", e);
            intentos_fallidos + 1
        });
        let (status, message) = if intentos >= 5 {
            (
                StatusCode::FORBIDDEN,
                "Cuenta bloqueada por 15 minutos debido a demasiados intentos fallidos.",
            )
        } else {
            (StatusCode::UNAUTHORIZED, "Credenciales inválidas.")
        };
        return (status, LoginResponse::failure(message.to_string()));
    }

    // 4. Estado de la cuenta, solo después de comprobar la contraseña
    if status != "ACTIVE" {
        let message = if status == "SUSPENDED" {
            "Tu cuenta está suspendida. Contacta a un administrador."
        } else {
            "Tu cuenta no ha sido verificada. Revisa tu correo electrónico."
        };
        return (
            StatusCode::FORBIDDEN,
            LoginResponse::failure(message.to_string()),
        );
    }

    // 5. Login exitoso — resetear intentos fallidos
    if let Err(e) =
        sqlx::query("UPDATE users SET intentos_fallidos = 0, bloqueado_hasta = NULL WHERE id = $1")
            .bind(user_id)
            .execute(&state.pool)
            .await
    {
        eprintln!("Error al reiniciar intentos fallidos: {}", e);
    }

    // 6. Emitir acceso JWT (15 min) y refresh token (7 días, guardado en BD)
    let (access_token, refresh_token_id) =
        match super::session::issue_pair(&state.pool, &state.config.jwt_secret, user_id, &role)
            .await
        {
            Ok(pair) => pair,
            Err(e) => {
                eprintln!("Error al emitir los tokens de sesión: {}", e);
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    LoginResponse::failure("Error interno al iniciar sesión."),
                );
            }
        };

    (
        StatusCode::OK,
        Json(LoginResponse {
            success: true,
            message: "Inicio de sesión exitoso.".to_string(),
            access_token: Some(access_token),
            refresh_token: Some(refresh_token_id.to_string()),
            user: Some(LoginUserInfo {
                id: user_id,
                name,
                email,
                role,
            }),
        }),
    )
}

// ─── PUT /admin/users/:id/role ───────────────────────────────────────────

pub async fn change_user_role(
    State(state): State<AppState>,
    axum::extract::Path(target_user_id): axum::extract::Path<Uuid>,
    axum::Extension(auth_user): axum::Extension<crate::auth::middleware::AuthUser>,
    Json(payload): Json<ChangeRoleDto>,
) -> (StatusCode, Json<ApiResponse>) {
    // Verificar que no se cambie el rol a sí mismo
    if auth_user.user_id == target_user_id {
        return (
            StatusCode::BAD_REQUEST,
            ApiResponse::failure("No puedes cambiar tu propio rol."),
        );
    }

    // Validar que el rol sea válido
    // Deben coincidir con el tipo `roles` de la base de datos.
    let valid_roles = ["MEMBER", "MODERATOR", "ADMIN"];
    if !valid_roles.contains(&payload.role.as_str()) {
        return (
            StatusCode::BAD_REQUEST,
            ApiResponse::failure(format!(
                "Rol inválido. Los roles válidos son: {}",
                valid_roles.join(", ")
            )),
        );
    }

    // Actualizar el rol del usuario
    // Cambio de rol y cierre de sesiones en la misma transacción: si no se
    // pueden revocar las sesiones, el rol tampoco cambia.
    let result: Result<u64, sqlx::Error> = async {
        let mut tx = state.pool.begin().await?;
        let updated = sqlx::query("UPDATE users SET rol = $1::text::roles WHERE id = $2")
            .bind(&payload.role)
            .bind(target_user_id)
            .execute(&mut *tx)
            .await?
            .rows_affected();
        sqlx::query("DELETE FROM refresh_tokens WHERE user_id = $1")
            .bind(target_user_id)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        Ok(updated)
    }
    .await;

    match result {
        Ok(0) => (
            StatusCode::NOT_FOUND,
            ApiResponse::failure("No se encontró el usuario especificado."),
        ),
        Ok(_) => (
            StatusCode::OK,
            Json(ApiResponse {
                success: true,
                message: format!("Rol del usuario actualizado a '{}'.", payload.role),
                field_errors: None,
            }),
        ),
        Err(e) => {
            eprintln!("Error al cambiar rol: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                ApiResponse::failure("Error interno al actualizar el rol."),
            )
        }
    }
}

// ─── Sprint 2: IRL-IAM-US-05 — Perfil de Usuario y Personalización ───────

#[derive(Serialize)]
pub struct UserProfileDto {
    pub id: Uuid,
    pub name: String,
    pub email: String,
    pub telefono: String,
    pub rol: String,
    pub estado: String,
    pub bio: String,
    pub avatar_color: String,
    pub status_text: String,
    pub avatar_url: Option<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Serialize, Default)]
pub struct ProfileResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub profile: Option<UserProfileDto>,
}

#[derive(Deserialize)]
pub struct UpdateProfileDto {
    pub name: Option<String>,
    pub telefono: Option<String>,
    pub bio: Option<String>,
    pub avatar_color: Option<String>,
    pub status_text: Option<String>,
    pub avatar_url: Option<String>,
}

#[derive(Deserialize)]
pub struct ChangePasswordDto {
    pub current_password: String,
    pub new_password: String,
}

// ─── GET /users/me ───────────────────────────────────────────────────────

pub async fn get_user_profile(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
) -> (StatusCode, Json<ProfileResponse>) {
    let row = sqlx::query_as::<_, (Uuid, String, String, String, String, String, Option<String>, Option<String>, Option<String>, Option<String>, chrono::DateTime<chrono::Utc>)>(
        "SELECT id, name, email, telefono, rol::TEXT, estado::TEXT, bio, avatar_color, status_text, avatar_url, created_at 
         FROM users WHERE id = $1"
    )
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await;

    match row {
        Ok(Some((id, name, email, telefono, rol, estado, bio, color, status, url, created_at))) => {
            (
                StatusCode::OK,
                Json(ProfileResponse {
                    success: true,
                    message: "Perfil obtenido exitosamente.".to_string(),
                    profile: Some(UserProfileDto {
                        id,
                        name,
                        email,
                        telefono,
                        rol,
                        estado,
                        bio: bio.unwrap_or_default(),
                        avatar_color: color.unwrap_or_else(|| "#00E5FF".to_string()),
                        status_text: status.unwrap_or_default(),
                        avatar_url: url,
                        created_at,
                    }),
                }),
            )
        }
        Ok(None) => (
            StatusCode::NOT_FOUND,
            ProfileResponse::failure("Usuario no encontrado."),
        ),
        Err(e) => {
            eprintln!("Error al obtener perfil de usuario: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                ProfileResponse::failure("Error interno al obtener el perfil."),
            )
        }
    }
}

// ─── PUT /users/me ───────────────────────────────────────────────────────

/// Límites del perfil. Antes `PUT /users/me` aceptaba cualquier texto, incluida
/// una `avatar_url` arbitraria que esquivaba la validación de la foto.
const MAX_NAME_CHARS: usize = 100;
const MAX_BIO_CHARS: usize = 500;
const MAX_STATUS_CHARS: usize = 100;

fn profile_error(payload: &UpdateProfileDto) -> Option<&'static str> {
    if let Some(name) = payload.name.as_deref().map(str::trim) {
        let n = name.chars().count();
        if !(2..=MAX_NAME_CHARS).contains(&n) {
            return Some("El nombre debe tener entre 2 y 100 caracteres.");
        }
    }
    if let Some(phone) = payload.telefono.as_deref().map(str::trim)
        && let Some(error) = phone_error(phone)
    {
        return Some(error);
    }
    if payload
        .bio
        .as_deref()
        .is_some_and(|b| b.trim().chars().count() > MAX_BIO_CHARS)
    {
        return Some("La biografía admite como máximo 500 caracteres.");
    }
    if payload
        .status_text
        .as_deref()
        .is_some_and(|s| s.trim().chars().count() > MAX_STATUS_CHARS)
    {
        return Some("El estado admite como máximo 100 caracteres.");
    }
    if let Some(color) = payload.avatar_color.as_deref().map(str::trim) {
        let hex = color.strip_prefix('#').unwrap_or("");
        if hex.len() != 6 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return Some("El color debe tener el formato #RRGGBB.");
        }
    }
    None
}

pub async fn update_user_profile(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Json(payload): Json<UpdateProfileDto>,
) -> (StatusCode, Json<ProfileResponse>) {
    if let Some(error) = profile_error(&payload) {
        return (StatusCode::BAD_REQUEST, ProfileResponse::failure(error));
    }
    // Cadena vacía elimina la foto; cualquier otra pasa la misma validación
    // que `POST /users/me/avatar` (contenido real JPG/PNG/WEBP de hasta 2 MB).
    let should_update_avatar = payload.avatar_url.is_some();
    let avatar_val = match payload.avatar_url.as_deref().map(str::trim) {
        Some(raw) if !raw.is_empty() => match normalize_avatar(raw) {
            Ok(uri) => Some(uri),
            Err((status, message)) => return (status, ProfileResponse::failure(message)),
        },
        _ => None,
    };

    let result = sqlx::query(
        "UPDATE users 
         SET name = COALESCE($1, name),
             telefono = COALESCE($2, telefono),
             bio = COALESCE($3, bio),
             avatar_color = COALESCE($4, avatar_color),
             status_text = COALESCE($5, status_text),
             avatar_url = CASE WHEN $6::boolean THEN $7 ELSE avatar_url END,
             updated_at = NOW()
         WHERE id = $8",
    )
    .bind(payload.name.as_deref().map(str::trim))
    .bind(payload.telefono.as_deref().map(str::trim))
    .bind(payload.bio.as_deref().map(str::trim))
    .bind(payload.avatar_color.as_deref().map(str::trim))
    .bind(payload.status_text.as_deref().map(str::trim))
    .bind(should_update_avatar)
    .bind(avatar_val)
    .bind(auth_user.user_id)
    .execute(&state.pool)
    .await;

    match result {
        Ok(r) => {
            if r.rows_affected() == 0 {
                return (
                    StatusCode::NOT_FOUND,
                    ProfileResponse::failure("Usuario no encontrado."),
                );
            }

            // Retornar perfil actualizado
            get_user_profile(State(state), axum::Extension(auth_user)).await
        }
        Err(e) if e.to_string().contains("users_telefono_key") => (
            StatusCode::CONFLICT,
            ProfileResponse::failure("Este número de teléfono ya está registrado."),
        ),
        Err(e) => {
            eprintln!("Error al actualizar perfil de usuario: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                ProfileResponse::failure("Error interno al actualizar el perfil."),
            )
        }
    }
}

// ─── PUT /users/me/password ──────────────────────────────────────────────

/// Respuesta del cambio de contraseña. Las demás sesiones quedan cerradas;
/// este dispositivo recibe una pareja de tokens nueva para continuar.
#[derive(Serialize, Default)]
pub struct PasswordChangedResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub field_errors: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub access_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
}

pub async fn change_user_password(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Json(payload): Json<ChangePasswordDto>,
) -> (StatusCode, Json<PasswordChangedResponse>) {
    // 1. Obtener hash actual
    let current_hash = sqlx::query_scalar::<_, String>("SELECT password FROM users WHERE id = $1")
        .bind(auth_user.user_id)
        .fetch_optional(&state.pool)
        .await;

    let hash_str = match current_hash {
        Ok(Some(h)) => h,
        _ => {
            return (
                StatusCode::NOT_FOUND,
                PasswordChangedResponse::failure("Usuario no encontrado."),
            );
        }
    };

    // 2. Verificar contraseña actual con Argon2
    let parsed_hash = match PasswordHash::new(&hash_str) {
        Ok(h) => h,
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                PasswordChangedResponse::failure("Error al procesar el hash de contraseña."),
            );
        }
    };

    // Sin recortar espacios: el registro, el login y la recuperación usan la
    // contraseña tal cual. Recortarla aquí impedía cambiar una contraseña que
    // empezara o terminara con espacio y guardaba una distinta a la escrita.
    let current_pass = payload.current_password.as_str();
    let new_pass = payload.new_password.as_str();

    if Argon2::default()
        .verify_password(current_pass.as_bytes(), &parsed_hash)
        .is_err()
    {
        return (
            StatusCode::UNAUTHORIZED,
            PasswordChangedResponse::failure("La contraseña actual no es correcta."),
        );
    }

    // 3. Validar que la nueva contraseña sea diferente a la actual
    if current_pass == new_pass {
        let mut field_errors = HashMap::new();
        field_errors.insert(
            "new_password".to_string(),
            "La nueva contraseña debe ser diferente a la contraseña actual.".to_string(),
        );
        return (
            StatusCode::BAD_REQUEST,
            Json(PasswordChangedResponse {
                message: "La nueva contraseña debe ser diferente a la contraseña actual."
                    .to_string(),
                field_errors: Some(field_errors),
                ..Default::default()
            }),
        );
    }

    // 4. Validar política de seguridad de la nueva contraseña (longitud y complejidad)
    let field_errors = validate_password_field(new_pass, "new_password");
    if !field_errors.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(PasswordChangedResponse {
                message: "La nueva contraseña no cumple con los requisitos de seguridad."
                    .to_string(),
                field_errors: Some(field_errors),
                ..Default::default()
            }),
        );
    }

    // 5. Hashear nueva contraseña
    let salt = SaltString::generate(&mut OsRng);
    let new_hash = match Argon2::default().hash_password(new_pass.as_bytes(), &salt) {
        Ok(h) => h.to_string(),
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                PasswordChangedResponse::failure("Error al encriptar la nueva contraseña."),
            );
        }
    };

    // 6. Guardar, revocar todas las sesiones e invalidar los accesos emitidos
    if let Err(e) = super::session::update_password(&state.pool, auth_user.user_id, &new_hash).await
    {
        eprintln!("Error al actualizar contraseña: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            PasswordChangedResponse::failure("Error interno al actualizar la contraseña."),
        );
    }

    // 7. Antes este dispositivo también perdía su sesión sin aviso al
    // renovar el token (hasta 15 minutos después). Ahora recibe una nueva.
    let pair = super::session::issue_pair(
        &state.pool,
        &state.config.jwt_secret,
        auth_user.user_id,
        &auth_user.role,
    )
    .await;
    let (access_token, refresh_token) = match pair {
        Ok((access, refresh)) => (Some(access), Some(refresh.to_string())),
        Err(e) => {
            eprintln!("Contraseña cambiada, pero no se pudo emitir la sesión nueva: {e}");
            (None, None)
        }
    };

    (
        StatusCode::OK,
        Json(PasswordChangedResponse {
            success: true,
            message: if access_token.is_some() {
                "Contraseña actualizada. Se cerraron tus demás sesiones."
            } else {
                "Contraseña actualizada. Vuelve a iniciar sesión."
            }
            .to_string(),
            field_errors: None,
            access_token,
            refresh_token,
        }),
    )
}

// ─── POST /users/me/avatar ────────────────────────────────────────────────

const MAX_AVATAR_BYTES: usize = 2 * 1024 * 1024;

/// Normaliza una foto de perfil a `data:<mime>;base64,...`. El tipo se decide
/// por el contenido real (JPG, PNG o WEBP), nunca por lo que declara el
/// cliente: antes bastaba con declarar `image/jpeg` para guardar cualquier dato.
fn normalize_avatar(raw: &str) -> Result<String, (StatusCode, &'static str)> {
    use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
    let encoded = match raw.strip_prefix("data:") {
        Some(rest) => match rest.split_once(',') {
            Some((header, data)) if header.ends_with(";base64") => data,
            _ => return Err((StatusCode::BAD_REQUEST, "Formato Data URI inválido.")),
        },
        None => raw,
    };
    let clean: String = encoded.chars().filter(|c| !c.is_whitespace()).collect();
    let bytes = BASE64.decode(&clean).map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            "La imagen contiene una codificación Base64 inválida.",
        )
    })?;
    if bytes.len() > MAX_AVATAR_BYTES {
        return Err((
            StatusCode::PAYLOAD_TOO_LARGE,
            "La imagen excede el tamaño máximo permitido de 2 MB.",
        ));
    }
    let mime = if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "image/jpeg"
    } else if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        "image/png"
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        "image/webp"
    } else {
        return Err((
            StatusCode::BAD_REQUEST,
            "Formato no permitido. Solo se admiten imágenes JPG, PNG y WEBP.",
        ));
    };
    Ok(format!("data:{mime};base64,{clean}"))
}

#[derive(Deserialize)]
pub struct UploadAvatarDto {
    pub avatar_data: String,
}

#[derive(Serialize, Default)]
pub struct UploadAvatarResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
}

pub async fn upload_avatar(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Json(payload): Json<UploadAvatarDto>,
) -> (StatusCode, Json<UploadAvatarResponse>) {
    let raw_data = payload.avatar_data.trim();
    if raw_data.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            UploadAvatarResponse::failure("No se proporcionaron datos de imagen para el avatar."),
        );
    }
    let final_avatar_url = match normalize_avatar(raw_data) {
        Ok(uri) => uri,
        Err((status, message)) => return (status, UploadAvatarResponse::failure(message)),
    };

    let result = sqlx::query("UPDATE users SET avatar_url = $1, updated_at = NOW() WHERE id = $2")
        .bind(&final_avatar_url)
        .bind(auth_user.user_id)
        .execute(&state.pool)
        .await;

    match result {
        Ok(_) => (
            StatusCode::OK,
            Json(UploadAvatarResponse {
                success: true,
                message: "Avatar actualizado exitosamente.".to_string(),
                avatar_url: Some(final_avatar_url),
            }),
        ),
        Err(e) => {
            eprintln!("Error al actualizar avatar en DB: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                UploadAvatarResponse::failure("Error interno al guardar el avatar."),
            )
        }
    }
}

crate::response::failure_response!(
    ApiResponse,
    LoginResponse,
    UploadAvatarResponse,
    ProfileResponse,
    PasswordChangedResponse
);
