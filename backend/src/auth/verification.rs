use argon2::{
    Argon2,
    password_hash::{PasswordHasher, SaltString, rand_core::OsRng},
};
use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use rand::Rng;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

use crate::auth::mail_guard;
use crate::auth::service::ApiResponse;
use crate::config::AppConfig;
use crate::mailer;

/// Estado compartido para los endpoints de verificación
#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub config: std::sync::Arc<AppConfig>,
    pub mailer: mailer::SmtpMailer,
}

// ─── DTOs ────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct ForgotPasswordDto {
    pub email: String,
}

#[derive(Deserialize)]
pub struct ResetPasswordDto {
    pub email: String,
    pub code: String,
    pub new_password: String,
}

#[derive(Deserialize)]
pub struct RequestVerificationDto {
    pub email: String,
    pub method: String, // "code" o "link"
}

#[derive(Deserialize)]
pub struct VerifyEmailDto {
    pub email: String,
    pub code: String,
}

#[derive(Serialize, Default)]
pub struct VerifyResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user: Option<UserInfo>,
}

#[derive(Serialize)]
pub struct UserInfo {
    pub id: Uuid,
    pub name: String,
    pub email: String,
    pub role: String,
}

/// Correos por hora y propósito: verificación (`code` y `link`) o
/// recuperación (`reset_code`), cada uno con su propio cupo.
const MAX_MAILS_PER_HOUR: i64 = 3;
const VERIFICATION_METHODS: &[&str] = &["code", "link"];
const RESET_METHODS: &[&str] = &["reset_code"];
/// Vigencia de códigos y enlaces; los correos citan este mismo valor.
const TOKEN_MINUTES: i32 = 15;

/// Crea un token de [`TOKEN_MINUTES`] si el usuario no agotó el cupo por hora de
/// `methods` (los del mismo propósito que `method`). Devuelve `None` si lo
/// agotó. Los tokens vencidos de la última hora siguen contando; antes de
/// contar solo se borran los de ese propósito que ya vencieron y quedaron
/// fuera de la ventana. El bloqueo de la fila del usuario serializa
/// solicitudes simultáneas para que no se salten el límite.
async fn reserve_token(
    pool: &PgPool,
    user_id: Uuid,
    methods: &[&str],
    method: &str,
    code: &str,
    token: Option<&str>,
) -> Result<Option<Uuid>, sqlx::Error> {
    let mut tx = pool.begin().await?;
    sqlx::query("SELECT 1 FROM users WHERE id = $1 FOR NO KEY UPDATE")
        .bind(user_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "DELETE FROM verification_tokens WHERE user_id = $1 AND method = ANY($2)
         AND expires_at < NOW() AND created_at <= NOW() - INTERVAL '1 hour'",
    )
    .bind(user_id)
    .bind(methods)
    .execute(&mut *tx)
    .await?;
    let recent: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM verification_tokens WHERE user_id = $1 AND method = ANY($2)
         AND created_at > NOW() - INTERVAL '1 hour'",
    )
    .bind(user_id)
    .bind(methods)
    .fetch_one(&mut *tx)
    .await?;
    if recent >= MAX_MAILS_PER_HOUR {
        tx.commit().await?;
        return Ok(None);
    }
    let id = sqlx::query_scalar(
        "INSERT INTO verification_tokens (user_id, code, token, method, expires_at)
         VALUES ($1, $2, $3, $4, NOW() + make_interval(mins => $5)) RETURNING id",
    )
    .bind(user_id)
    .bind(code)
    .bind(token)
    .bind(method)
    .bind(TOKEN_MINUTES)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Some(id))
}

/// Comprueba que el servidor de correo responde (como mucho 5 s).
async fn smtp_reachable(mailer: &mailer::SmtpMailer) -> bool {
    matches!(
        tokio::time::timeout(std::time::Duration::from_secs(5), mailer.test_connection()).await,
        Ok(Ok(true))
    )
}

/// Respuesta cuando el correo no sale. Es la misma para una dirección
/// registrada y para una desconocida (ver `forgot_password`).
fn unsent() -> Response {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        ApiResponse::failure("No pudimos enviar el correo. Inténtalo de nuevo en unos minutos."),
    )
        .into_response()
}

/// Si el correo no sale, el token recién creado se borra: no queda vivo ni
/// cuenta para el límite por hora, y se informa del fallo en lugar de
/// asegurar que se envió. El fallo sí cuenta para el tope por dirección de
/// [`mail_guard`], para que un SMTP caído no permita reintentar sin fin.
async fn discard_unsent(pool: &PgPool, token_id: Uuid, email: &str, error: &str) -> Response {
    eprintln!("Error al enviar el correo: {}", error);
    mail_guard::record_failure(email);
    if let Err(e) = sqlx::query("DELETE FROM verification_tokens WHERE id = $1")
        .bind(token_id)
        .execute(pool)
        .await
    {
        eprintln!("No se pudo borrar el token no enviado: {}", e);
    }
    unsent()
}

// ─── POST /request-verification ──────────────────────────────────────────

pub async fn request_verification(
    State(state): State<AppState>,
    Json(payload): Json<RequestVerificationDto>,
) -> Response {
    if let Some(retry_after) = mail_guard::failures_block(&payload.email) {
        return mail_guard::too_many(retry_after);
    }

    // 1. Buscar al usuario por email
    let user = sqlx::query_as::<_, (Uuid, String, String)>(
        "SELECT id, estado::TEXT, TRIM(email) FROM users WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))",
    )
    .bind(&payload.email)
    .fetch_optional(&state.pool)
    .await;

    // Se envía a la dirección registrada, no a la escrita en la solicitud.
    let (user_id, status, email) = match user {
        Ok(Some(u)) => u,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                ApiResponse::failure("No se encontró un usuario con ese correo electrónico."),
            )
                .into_response();
        }
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                ApiResponse::failure("Error interno al buscar el usuario."),
            )
                .into_response();
        }
    };

    // Si ya está activo, no necesita verificación
    if status == "ACTIVE" {
        return (
            StatusCode::BAD_REQUEST,
            ApiResponse::failure("Esta cuenta ya está verificada."),
        )
            .into_response();
    }
    // Una cuenta suspendida no se reactiva verificando el correo.
    if status != "PENDING" {
        return (
            StatusCode::FORBIDDEN,
            ApiResponse::failure(SUSPENDED_MESSAGE),
        )
            .into_response();
    }

    // 2. Generar código de 6 dígitos o token de enlace de 64 caracteres
    // hexadecimales (32 bytes); el código no se usa para enlaces.
    let (method, code, token_hex) = if payload.method == "link" {
        let token_hex = {
            let mut rng = rand::thread_rng();
            let mut bytes = [0u8; 32];
            rng.fill(&mut bytes);
            hex::encode(bytes)
        };
        ("link", "000000".to_string(), Some(token_hex))
    } else {
        let code = {
            let mut rng = rand::thread_rng();
            format!("{:06}", rng.gen_range(0..1_000_000u32))
        };
        ("code", code, None)
    };

    // 3. Guardarlo si no se superó el límite de 3 solicitudes por hora
    let token_id = match reserve_token(
        &state.pool,
        user_id,
        VERIFICATION_METHODS,
        method,
        &code,
        token_hex.as_deref(),
    )
    .await
    {
        Ok(Some(id)) => id,
        Ok(None) => {
            return (
                StatusCode::TOO_MANY_REQUESTS,
                ApiResponse::failure(
                    "Has excedido el límite de solicitudes. Intenta de nuevo en una hora.",
                ),
            )
                .into_response();
        }
        Err(e) => {
            eprintln!("Error al generar el token de verificación: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                ApiResponse::failure("Error interno al procesar la verificación."),
            )
                .into_response();
        }
    };

    // 4. Enviar el enlace o el código por correo
    let sent = match &token_hex {
        Some(token_hex) => {
            let link = format!("{}/verify-link/{}", state.config.app_base_url, token_hex);
            mailer::send_verification_link(
                &state.mailer,
                &state.config.smtp_from,
                &email,
                &link,
                TOKEN_MINUTES.into(),
            )
            .await
        }
        None => {
            mailer::send_verification_code(
                &state.mailer,
                &state.config.smtp_from,
                &email,
                &code,
                TOKEN_MINUTES.into(),
            )
            .await
        }
    };
    if let Err(e) = sent {
        return discard_unsent(&state.pool, token_id, &email, &e).await;
    }

    (
        StatusCode::OK,
        Json(ApiResponse {
            success: true,
            message: "Se ha enviado la verificación a tu correo electrónico.".to_string(),
            field_errors: None,
        }),
    )
        .into_response()
}

const SUSPENDED_MESSAGE: &str = "Esta cuenta está suspendida. Contacta a un administrador.";

enum Activation {
    /// Estaba pendiente: lleva la dirección registrada para la bienvenida.
    Activated(String),
    /// Ya estaba activa (p. ej. dos verificaciones simultáneas).
    AlreadyActive,
    /// Suspendida por un administrador: verificar el correo no la reactiva.
    Suspended,
}

/// Activa la cuenta solo si está pendiente.
async fn activate(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    user_id: Uuid,
) -> Result<Activation, sqlx::Error> {
    // El bloqueo hace que, ante dos verificaciones simultáneas, la segunda
    // vea la cuenta ya activa y no repita la bienvenida.
    let (before, email): (String, String) =
        sqlx::query_as("SELECT estado::TEXT, TRIM(email) FROM users WHERE id = $1 FOR UPDATE")
            .bind(user_id)
            .fetch_one(&mut **tx)
            .await?;
    match before.as_str() {
        "PENDING" => {
            sqlx::query("UPDATE users SET estado = 'ACTIVE' WHERE id = $1")
                .bind(user_id)
                .execute(&mut **tx)
                .await?;
            Ok(Activation::Activated(email))
        }
        "ACTIVE" => Ok(Activation::AlreadyActive),
        _ => Ok(Activation::Suspended),
    }
}

/// Consume el código o enlace dentro de la transacción. Si dos solicitudes
/// leyeron el mismo código, el borrado de la segunda espera a la primera y no
/// encuentra la fila: solo una puede usarlo.
async fn consume_token(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    token_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let consumed: Option<Uuid> = sqlx::query_scalar(
        "DELETE FROM verification_tokens WHERE id = $1 AND expires_at > NOW() RETURNING id",
    )
    .bind(token_id)
    .fetch_optional(&mut **tx)
    .await?;
    Ok(consumed.is_some())
}

type VerifyRefusal = (StatusCode, Json<VerifyResponse>);

/// Pasos comunes al código y al enlace: consumir el token y activar la
/// cuenta. Devuelve la dirección a la que dar la bienvenida, o la respuesta
/// de rechazo (el llamador deshace la transacción).
async fn verify_in_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    token_id: Uuid,
    user_id: Uuid,
) -> Result<Result<Option<String>, VerifyRefusal>, sqlx::Error> {
    if !consume_token(tx, token_id).await? {
        return Ok(Err((
            StatusCode::BAD_REQUEST,
            VerifyResponse::failure("Código inválido o expirado."),
        )));
    }
    Ok(match activate(tx, user_id).await? {
        Activation::Activated(address) => Ok(Some(address)),
        Activation::AlreadyActive => Ok(None),
        Activation::Suspended => Err((
            StatusCode::FORBIDDEN,
            VerifyResponse::failure(SUSPENDED_MESSAGE),
        )),
    })
}

/// Correo de bienvenida tras activar la cuenta, sin hacer esperar la
/// respuesta: si falla el SMTP la verificación ya está hecha.
fn send_welcome(state: &AppState, to: String, name: String) {
    let mailer = state.mailer.clone();
    let from = state.config.smtp_from.clone();
    let app_url = state.config.app_public_url.clone();
    tokio::spawn(async move {
        if let Err(e) = mailer::send_welcome(&mailer, &from, &to, &name, app_url.as_deref()).await {
            eprintln!("No se pudo enviar el correo de bienvenida: {}", e);
        }
    });
}

// ─── POST /verify-email ──────────────────────────────────────────────────

/// Fallos permitidos por código antes de invalidarlo.
const MAX_CODE_ATTEMPTS: i16 = 5;

/// Registra un código incorrecto para los códigos vigentes del usuario y
/// método. Al llegar a [`MAX_CODE_ATTEMPTS`] los invalida. Devuelve cuántos
/// intentos quedan (0 si hubo que pedir otro código).
async fn register_failed_code(pool: &sqlx::PgPool, user_id: Uuid, method: &str) -> i16 {
    let used: Vec<i16> = sqlx::query_scalar(
        "UPDATE verification_tokens SET intentos = intentos + 1
         WHERE user_id = $1 AND method = $2 AND expires_at > NOW() RETURNING intentos",
    )
    .bind(user_id)
    .bind(method)
    .fetch_all(pool)
    .await
    .unwrap_or_default();
    let worst = used.into_iter().max().unwrap_or(MAX_CODE_ATTEMPTS);
    if worst >= MAX_CODE_ATTEMPTS {
        // Se vencen sin borrarlos: siguen contando para el límite por hora y
        // no se pueden pedir códigos nuevos sin fin para seguir probando.
        let _ = sqlx::query(
            "UPDATE verification_tokens SET expires_at = NOW() WHERE user_id = $1 AND method = $2 AND expires_at > NOW()",
        )
        .bind(user_id)
        .bind(method)
        .execute(pool)
        .await;
        0
    } else {
        MAX_CODE_ATTEMPTS - worst
    }
}

fn wrong_code_message(remaining: i16) -> String {
    if remaining > 0 {
        format!("Código incorrecto. Te quedan {remaining} intento(s).")
    } else {
        "Demasiados intentos. Solicita un código nuevo.".to_string()
    }
}

pub async fn verify_email(
    State(state): State<AppState>,
    Json(payload): Json<VerifyEmailDto>,
) -> (StatusCode, Json<VerifyResponse>) {
    // 1. Buscar al usuario
    let user = sqlx::query_as::<_, (Uuid, String, String, String)>(
        "SELECT id, name, rol::TEXT, estado::TEXT FROM users WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))",
    )
    .bind(&payload.email)
    .fetch_optional(&state.pool)
    .await;

    let (user_id, name, role, estado) = match user {
        Ok(Some(u)) => u,
        Ok(None) => {
            return (
                StatusCode::BAD_REQUEST,
                VerifyResponse::failure("Código inválido o expirado."),
            );
        }
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                VerifyResponse::failure("Error interno del servidor."),
            );
        }
    };

    // Si el usuario ya está activo (por ejemplo, verificado mediante enlace)
    if estado == "ACTIVE" {
        return (
            StatusCode::OK,
            Json(VerifyResponse {
                success: true,
                message: "Cuenta ya verificada exitosamente.".to_string(),
                user: Some(UserInfo {
                    id: user_id,
                    name,
                    email: payload.email,
                    role,
                }),
            }),
        );
    }
    if estado != "PENDING" {
        return (
            StatusCode::FORBIDDEN,
            VerifyResponse::failure(SUSPENDED_MESSAGE),
        );
    }

    // 2. Buscar token válido (no expirado, método code)
    let token_row = sqlx::query_as::<_, (Uuid,)>(
        "SELECT id FROM verification_tokens WHERE user_id = $1 AND code = $2 AND method = 'code' AND expires_at > NOW() AND intentos < $3 ORDER BY created_at DESC LIMIT 1"
    )
    .bind(user_id)
    .bind(&payload.code)
    .bind(MAX_CODE_ATTEMPTS)
    .fetch_optional(&state.pool)
    .await;

    let token_id = match token_row {
        Ok(Some(t)) => t.0,
        Ok(None) => {
            // Sin código (comprobación de «ya abrí el enlace») no cuenta como intento.
            let message = if payload.code.trim().is_empty() {
                "Código inválido o expirado.".to_string()
            } else {
                wrong_code_message(register_failed_code(&state.pool, user_id, "code").await)
            };
            return (
                StatusCode::BAD_REQUEST,
                Json(VerifyResponse {
                    success: false,
                    message,
                    user: None,
                }),
            );
        }
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                VerifyResponse::failure("Error interno al validar el código."),
            );
        }
    };

    // Iniciar transacción
    let mut tx = match state.pool.begin().await {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Error al iniciar transacción en verify_email: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                VerifyResponse::failure("Error interno al iniciar la verificación."),
            );
        }
    };

    // 3. Consumir el código (una sola vez) y activar la cuenta pendiente
    let welcome = match verify_in_tx(&mut tx, token_id, user_id).await {
        Ok(Ok(welcome)) => welcome,
        Ok(Err(refusal)) => {
            let _ = tx.rollback().await;
            return refusal;
        }
        Err(e) => {
            eprintln!("Error al verificar la cuenta: {}", e);
            let _ = tx.rollback().await;
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                VerifyResponse::failure("Error interno al activar la cuenta."),
            );
        }
    };

    if let Err(e) = tx.commit().await {
        eprintln!("Error al confirmar transacción en verify_email: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            VerifyResponse::failure("Error interno al completar la verificación."),
        );
    }
    if let Some(address) = welcome {
        send_welcome(&state, address, name.clone());
    }

    (
        StatusCode::OK,
        Json(VerifyResponse {
            success: true,
            message: "Cuenta verificada exitosamente.".to_string(),
            user: Some(UserInfo {
                id: user_id,
                name,
                email: payload.email,
                role,
            }),
        }),
    )
}

// ─── GET /verify-link/:token ─────────────────────────────────────────────

pub async fn verify_link(
    State(state): State<AppState>,
    axum::extract::Path(token): axum::extract::Path<String>,
) -> (StatusCode, Json<VerifyResponse>) {
    // 1. Buscar token válido (no expirado, método link)
    let token_row = sqlx::query_as::<_, (Uuid, Uuid)>(
        "SELECT id, user_id FROM verification_tokens WHERE token = $1 AND method = 'link' AND expires_at > NOW() LIMIT 1"
    )
    .bind(&token)
    .fetch_optional(&state.pool)
    .await;

    let (token_id, user_id) = match token_row {
        Ok(Some(t)) => t,
        Ok(None) => {
            return (
                StatusCode::BAD_REQUEST,
                VerifyResponse::failure("Enlace de verificación inválido o expirado."),
            );
        }
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                VerifyResponse::failure("Error interno al validar el enlace."),
            );
        }
    };

    // 2. Obtener datos del usuario
    let user = sqlx::query_as::<_, (String, String, String)>(
        "SELECT name, email, rol::TEXT FROM users WHERE id = $1",
    )
    .bind(user_id)
    .fetch_optional(&state.pool)
    .await;

    let (name, email, role) = match user {
        Ok(Some(u)) => u,
        _ => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                VerifyResponse::failure("Error al obtener datos del usuario."),
            );
        }
    };

    // Iniciar transacción
    let mut tx = match state.pool.begin().await {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Error al iniciar transacción en verify_link: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                VerifyResponse::failure("Error interno al iniciar la verificación."),
            );
        }
    };

    // 3. Consumir el enlace (una sola vez) y activar la cuenta pendiente
    let welcome = match verify_in_tx(&mut tx, token_id, user_id).await {
        Ok(Ok(welcome)) => welcome,
        Ok(Err(refusal)) => {
            let _ = tx.rollback().await;
            return refusal;
        }
        Err(e) => {
            eprintln!("Error al verificar la cuenta: {}", e);
            let _ = tx.rollback().await;
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                VerifyResponse::failure("Error interno al activar la cuenta."),
            );
        }
    };

    if let Err(e) = tx.commit().await {
        eprintln!("Error al confirmar transacción en verify_link: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            VerifyResponse::failure("Error interno al completar la verificación."),
        );
    }
    if let Some(address) = welcome {
        send_welcome(&state, address, name.clone());
    }

    (
        StatusCode::OK,
        Json(VerifyResponse {
            success: true,
            message: "Cuenta verificada exitosamente.".to_string(),
            user: Some(UserInfo {
                id: user_id,
                name,
                email,
                role,
            }),
        }),
    )
}

// ─── POST /forgot-password ───────────────────────────────────────────────

pub async fn forgot_password(
    State(state): State<AppState>,
    Json(payload): Json<ForgotPasswordDto>,
) -> Response {
    let email = payload.email.trim().to_lowercase();
    if email.is_empty() || !email.contains('@') {
        return (
            StatusCode::BAD_REQUEST,
            ApiResponse::failure("Por favor ingresa un correo electrónico válido."),
        )
            .into_response();
    }
    if let Some(retry_after) = mail_guard::failures_block(&email) {
        return mail_guard::too_many(retry_after);
    }

    // 1. Buscar usuario
    let user = sqlx::query_as::<_, (Uuid, String)>(
        "SELECT id, name FROM users WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))",
    )
    .bind(&email)
    .fetch_optional(&state.pool)
    .await;

    let user_id = match user {
        Ok(Some(u)) => u.0,
        // Con el SMTP caído una cuenta registrada recibe `unsent()`; una
        // dirección desconocida debe recibir lo mismo para no delatar cuáles
        // existen, así que se comprueba el servidor de correo.
        Ok(None) => {
            if !smtp_reachable(&state.mailer).await {
                mail_guard::record_failure(&email);
                return unsent();
            }
            return (
                StatusCode::OK,
                Json(ApiResponse {
                    success: true,
                    message: "Si tu correo está registrado, recibirás un código de 6 dígitos para restablecer tu contraseña.".to_string(),
                    field_errors: None,
                }),
            )
            .into_response();
        }
        Err(e) => {
            eprintln!("Error en forgot_password: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                ApiResponse::failure("Error interno del servidor."),
            )
                .into_response();
        }
    };

    // Mismo mensaje exista o no la cuenta, para no revelar qué correos existen.
    let generic = || {
        (
            StatusCode::OK,
            Json(ApiResponse {
                success: true,
                message: "Si tu correo está registrado, recibirás un código de 6 dígitos para restablecer tu contraseña.".to_string(),
                field_errors: None,
            }),
        )
            .into_response()
    };

    // 2. Generar código OTP de 6 dígitos con 15 min de vigencia. Como máximo
    // 3 por hora: evita llenar de correos a alguien.
    let code: String = {
        let mut rng = rand::thread_rng();
        format!("{:06}", rng.gen_range(0..1_000_000u32))
    };
    let token_id = match reserve_token(
        &state.pool,
        user_id,
        RESET_METHODS,
        "reset_code",
        &code,
        None,
    )
    .await
    {
        Ok(Some(id)) => id,
        Ok(None) => return generic(),
        Err(e) => {
            eprintln!("Error al insertar token de recuperación: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                ApiResponse::failure("Error al generar código de recuperación."),
            )
                .into_response();
        }
    };

    // 3. Enviar correo SMTP. La cuenta existe: si el envío falla se informa
    // (el correo desconocido ya recibió la respuesta genérica).
    if let Err(e) = mailer::send_password_reset_code(
        &state.mailer,
        &state.config.smtp_from,
        &email,
        &code,
        TOKEN_MINUTES.into(),
    )
    .await
    {
        return discard_unsent(&state.pool, token_id, &email, &e).await;
    }

    // 4. Ya enviado, los códigos anteriores dejan de valer, pero se conservan
    // para el límite. Si el envío falla, el último código recibido sigue vivo.
    let _ = sqlx::query(
        "UPDATE verification_tokens SET expires_at = NOW() WHERE user_id = $1 AND method = 'reset_code' AND expires_at > NOW()
         AND created_at < (SELECT created_at FROM verification_tokens WHERE id = $2)",
    )
    .bind(user_id)
    .bind(token_id)
    .execute(&state.pool)
    .await;

    generic()
}

// ─── POST /reset-password ────────────────────────────────────────────────

pub async fn reset_password(
    State(state): State<AppState>,
    Json(payload): Json<ResetPasswordDto>,
) -> (StatusCode, Json<ApiResponse>) {
    let email = payload.email.trim().to_lowercase();
    let code = payload.code.trim().to_string();

    // 1. Validar política de contraseña
    let field_errors =
        crate::auth::service::validate_password_field(&payload.new_password, "new_password");
    if !field_errors.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(ApiResponse {
                success: false,
                message: "La nueva contraseña no cumple con los requisitos de seguridad."
                    .to_string(),
                field_errors: Some(field_errors),
            }),
        );
    }

    // 2. Buscar usuario
    let user = sqlx::query_as::<_, (Uuid,)>(
        "SELECT id FROM users WHERE LOWER(TRIM(email)) = LOWER(TRIM($1))",
    )
    .bind(&email)
    .fetch_optional(&state.pool)
    .await;

    let user_id = match user {
        Ok(Some(u)) => u.0,
        Ok(None) => {
            return (
                StatusCode::BAD_REQUEST,
                ApiResponse::failure(
                    "Código de recuperación inválido o expirado. Solicita uno nuevo.",
                ),
            );
        }
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                ApiResponse::failure("Error interno al buscar usuario."),
            );
        }
    };

    // 3. Verificar código no expirado
    let token = sqlx::query_as::<_, (Uuid,)>(
        "SELECT id FROM verification_tokens WHERE user_id = $1 AND code = $2 AND method = 'reset_code' AND expires_at > NOW() AND intentos < $3 ORDER BY created_at DESC LIMIT 1"
    )
    .bind(user_id)
    .bind(&code)
    .bind(MAX_CODE_ATTEMPTS)
    .fetch_optional(&state.pool)
    .await;

    let token_id = match token {
        Ok(Some(t)) => t.0,
        Ok(None) => {
            let remaining = register_failed_code(&state.pool, user_id, "reset_code").await;
            return (
                StatusCode::BAD_REQUEST,
                Json(ApiResponse {
                    success: false,
                    message: wrong_code_message(remaining),
                    field_errors: None,
                }),
            );
        }
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                ApiResponse::failure("Error al validar token de recuperación."),
            );
        }
    };

    // 4. Hashear nueva contraseña con Argon2id
    let salt = SaltString::generate(&mut OsRng);
    let argon2 = Argon2::default();
    let new_hash = match argon2.hash_password(payload.new_password.as_bytes(), &salt) {
        Ok(h) => h.to_string(),
        Err(e) => {
            eprintln!("Error al hashear contraseña en reset_password: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                ApiResponse::failure("Error al proteger la nueva contraseña."),
            );
        }
    };

    // 5. Iniciar transacción: actualizar contraseña, activar cuenta si estaba pendiente y limpiar tokens
    let mut tx = match state.pool.begin().await {
        Ok(t) => t,
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                ApiResponse::failure("Error interno al iniciar actualización."),
            );
        }
    };

    // El código se consume primero: si dos solicitudes lo leyeron a la vez,
    // solo una cambia la contraseña.
    match consume_token(&mut tx, token_id).await {
        Ok(true) => {}
        Ok(false) => {
            let _ = tx.rollback().await;
            return (
                StatusCode::BAD_REQUEST,
                ApiResponse::failure(
                    "Código de recuperación inválido o expirado. Solicita uno nuevo.",
                ),
            );
        }
        Err(_) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                ApiResponse::failure("Error al consumir el código."),
            );
        }
    }

    if let Err(e) = sqlx::query(
        // Recuperar la contraseña prueba el correo y activa una cuenta pendiente,
        // pero nunca reactiva una cuenta suspendida por un administrador.
        // También invalida al instante los accesos emitidos antes del cambio.
        "UPDATE users SET password = $1, estado = CASE WHEN estado = 'PENDING' THEN 'ACTIVE'::estados ELSE estado END, intentos_fallidos = 0, bloqueado_hasta = NULL, version_sesion = version_sesion + 1, updated_at = NOW() WHERE id = $2"
    )
    .bind(&new_hash)
    .bind(user_id)
    .execute(&mut *tx)
    .await {
        eprintln!("Error al actualizar password en reset_password: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            ApiResponse::failure("Error al guardar la nueva contraseña."),
        );
    }

    if sqlx::query("DELETE FROM refresh_tokens WHERE user_id = $1")
        .bind(user_id)
        .execute(&mut *tx)
        .await
        .is_err()
    {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            ApiResponse::failure("Error al revocar las sesiones."),
        );
    }
    if let Err(e) = tx.commit().await {
        eprintln!("Error al confirmar commit en reset_password: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            ApiResponse::failure("Error al completar el restablecimiento de contraseña."),
        );
    }
    crate::auth::session::announce_revoked(user_id);

    (
        StatusCode::OK,
        Json(ApiResponse {
            success: true,
            message: "¡Contraseña restablecida exitosamente! Ya puedes iniciar sesión con tu nueva contraseña.".to_string(),
            field_errors: None,
        }),
    )
}

crate::response::failure_response!(VerifyResponse);
