//! Renovación de un solo uso. Conserva el vencimiento absoluto de la sesión.
use super::{jwt::generate_access_token, verification::AppState};
use axum::{Json, extract::State, http::StatusCode};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use std::sync::LazyLock;
use tokio::sync::broadcast;
use uuid::Uuid;

/// Código con el que se cierran los WebSockets de una sesión revocada.
pub const SESSION_REVOKED_CLOSE: u16 = 4401;

/// Usuarios cuya versión de sesión acaba de cambiar (cerrar sesión, cambiar o
/// restablecer la contraseña). Los WebSockets abiertos de /live/ws y /rtc/ws
/// escuchan este canal y se cierran con [`SESSION_REVOKED_CLOSE`]; los demás
/// dispositivos se reconectan con un pase nuevo emitido con su JWT renovado.
static REVOCATIONS: LazyLock<broadcast::Sender<Uuid>> = LazyLock::new(|| broadcast::channel(256).0);

pub fn revocations() -> broadcast::Receiver<Uuid> {
    REVOCATIONS.subscribe()
}

pub fn announce_revoked(user: Uuid) {
    // Sin sockets abiertos no hay receptores: no es un error.
    let _ = REVOCATIONS.send(user);
}

/// Versión de sesión vigente, para comparar con la de un pase ya canjeado.
pub async fn current_version(pool: &PgPool, user: Uuid) -> Result<Option<i32>, sqlx::Error> {
    sqlx::query_scalar("SELECT version_sesion FROM users WHERE id = $1")
        .bind(user)
        .fetch_optional(pool)
        .await
}

#[derive(Deserialize)]
pub struct RefreshRequest {
    pub refresh_token: String,
}

#[derive(Serialize)]
pub struct RefreshResponse {
    pub success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub access_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
}

pub async fn rotate(
    pool: &PgPool,
    secret: &str,
    token: Uuid,
) -> Result<(String, Uuid), StatusCode> {
    let mut tx = pool
        .begin()
        .await
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    // Mismo orden de bloqueo que un cambio de contraseña: usuario, después tokens.
    let user = sqlx::query_as::<_, (Uuid, String, String, i32)>(
        "SELECT u.id, u.rol::TEXT, u.estado::TEXT, u.version_sesion FROM users u JOIN refresh_tokens r ON r.user_id = u.id WHERE r.token = $1 FOR UPDATE OF u"
    ).bind(token).fetch_optional(&mut *tx).await.map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    let (user_id, role, status, version) = user.ok_or(StatusCode::UNAUTHORIZED)?;
    if status != "ACTIVE" {
        return Err(StatusCode::UNAUTHORIZED);
    }
    let expiry = sqlx::query_scalar::<_, chrono::DateTime<chrono::Utc>>(
        "DELETE FROM refresh_tokens WHERE token = $1 AND expires_at > NOW() RETURNING expires_at",
    )
    .bind(token)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?
    .ok_or(StatusCode::UNAUTHORIZED)?;
    let access = generate_access_token(user_id, &role, version, secret)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let replacement = Uuid::new_v4();
    sqlx::query("INSERT INTO refresh_tokens (token, user_id, expires_at) VALUES ($1, $2, $3)")
        .bind(replacement)
        .bind(user_id)
        .bind(expiry)
        .execute(&mut *tx)
        .await
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    tx.commit()
        .await
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    Ok((access, replacement))
}

pub async fn refresh(
    State(state): State<AppState>,
    Json(body): Json<RefreshRequest>,
) -> (StatusCode, Json<RefreshResponse>) {
    let result = match Uuid::parse_str(&body.refresh_token) {
        Ok(token) => rotate(&state.pool, &state.config.jwt_secret, token).await,
        Err(_) => Err(StatusCode::UNAUTHORIZED),
    };
    match result {
        Ok((access, refresh)) => (
            StatusCode::OK,
            Json(RefreshResponse {
                success: true,
                access_token: Some(access),
                refresh_token: Some(refresh.to_string()),
            }),
        ),
        Err(status) => (
            status,
            Json(RefreshResponse {
                success: false,
                access_token: None,
                refresh_token: None,
            }),
        ),
    }
}

/// Emite una pareja nueva: acceso de 15 minutos y refresh de 7 días. El
/// acceso lleva la versión de sesión vigente, leída al guardar el refresh.
pub async fn issue_pair(
    pool: &PgPool,
    secret: &str,
    user_id: Uuid,
    role: &str,
) -> Result<(String, Uuid), sqlx::Error> {
    let refresh = Uuid::new_v4();
    let version: i32 = sqlx::query_scalar(
        "INSERT INTO refresh_tokens (token, user_id, expires_at) VALUES ($1, $2, $3)
         RETURNING (SELECT version_sesion FROM users WHERE id = $2)",
    )
    .bind(refresh)
    .bind(user_id)
    .bind(chrono::Utc::now() + chrono::Duration::days(7))
    .fetch_one(pool)
    .await?;
    let access = generate_access_token(user_id, role, version, secret)
        .map_err(|e| sqlx::Error::Protocol(e.to_string()))?;
    Ok((access, refresh))
}

/// Idempotente; el token opaco presentado solo permite revocar esa sesión.
/// Además incrementa la versión de sesión, lo que invalida los tokens de
/// acceso ya emitidos a esa cuenta: los demás dispositivos los renuevan con su
/// propio refresh token, pero quien tuviera una copia del acceso de esta
/// sesión deja de poder usarlo al instante.
pub async fn logout(State(state): State<AppState>, Json(body): Json<RefreshRequest>) -> StatusCode {
    let Ok(token) = Uuid::parse_str(&body.refresh_token) else {
        return StatusCode::NO_CONTENT;
    };
    match sqlx::query_scalar::<_, Uuid>(
        "WITH revocado AS (DELETE FROM refresh_tokens WHERE token = $1 RETURNING user_id)
         UPDATE users SET version_sesion = version_sesion + 1 WHERE id IN (SELECT user_id FROM revocado)
         RETURNING id",
    )
    .bind(token)
    .fetch_optional(&state.pool)
    .await
    {
        Ok(revoked) => {
            if let Some(user) = revoked {
                announce_revoked(user);
            }
            StatusCode::NO_CONTENT
        }
        Err(_) => StatusCode::SERVICE_UNAVAILABLE,
    }
}

/// El cambio de clave y la revocación se confirman juntos o se revierten juntos.
/// También invalida al instante los tokens de acceso emitidos antes.
pub async fn update_password(pool: &PgPool, user_id: Uuid, hash: &str) -> Result<(), sqlx::Error> {
    let mut tx = pool.begin().await?;
    sqlx::query("UPDATE users SET password = $1, intentos_fallidos = 0, bloqueado_hasta = NULL, version_sesion = version_sesion + 1, updated_at = NOW() WHERE id = $2")
        .bind(hash).bind(user_id).execute(&mut *tx).await?;
    sqlx::query("DELETE FROM refresh_tokens WHERE user_id = $1")
        .bind(user_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    announce_revoked(user_id);
    Ok(())
}

#[cfg(test)]
mod tests;
