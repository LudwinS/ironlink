//! Chat entre amigos, como los mensajes directos de Discord: no depende de
//! compartir un nodo. Convive con el chat directo de nodo
//! ([`crate::chat::direct`]), que sigue siendo el canal de trabajo entre
//! integrantes de un nodo (y el que lleva invitaciones a videollamadas).
//!
//! Solo se puede leer y escribir mientras ambas personas son amigas y no hay
//! un bloqueo en ningún sentido. Si dejan de serlo, los mensajes se
//! conservan y vuelven a verse si renuevan la amistad.
use axum::{
    Extension, Json,
    extract::{Path, State},
    http::StatusCode,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use std::sync::Arc;

use crate::{
    auth::{middleware::AuthUser, verification::AppState},
    rtc::server::RoomHub,
};

type ApiResult = (StatusCode, Json<Value>);

/// Mensajes por minuto que una cuenta puede enviar entre todos sus chats de
/// amistad.
pub const MAX_MENSAJES_POR_MINUTO: i64 = 60;
pub const MAX_CARACTERES: usize = 2000;
const HISTORIAL: i64 = 100;

/// Igual para «no son amigos» y «hay un bloqueo»: no se revela el bloqueo.
const SOLO_AMIGOS: &str = "Solo puedes chatear con tus amigos.";

fn failure(status: StatusCode, message: &str) -> ApiResult {
    (status, Json(json!({"success": false, "message": message})))
}

/// Mismo formato que los mensajes directos de nodo (`kind` siempre `text`).
#[derive(Serialize, sqlx::FromRow)]
struct MensajeAmistad {
    id: Uuid,
    sender_id: Uuid,
    recipient_id: Uuid,
    content: String,
    kind: String,
    reunion_id: Option<Uuid>,
    created_at: DateTime<Utc>,
    read_at: Option<DateTime<Utc>>,
}

/// Amistad aceptada con una cuenta activa y sin bloqueo en ningún sentido.
pub async fn pueden_chatear(
    pool: &sqlx::PgPool,
    own: Uuid,
    peer: Uuid,
) -> Result<bool, sqlx::Error> {
    sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM amistades a JOIN users u ON u.id = $2 AND u.estado = 'ACTIVE' \
                        WHERE a.estado = 'aceptada' \
                        AND ((a.solicitante = $1 AND a.destinatario = $2) \
                          OR (a.solicitante = $2 AND a.destinatario = $1))) \
            AND NOT EXISTS (SELECT 1 FROM bloqueos b WHERE (b.bloqueador = $1 AND b.bloqueado = $2) \
                            OR (b.bloqueador = $2 AND b.bloqueado = $1))",
    )
    .bind(own)
    .bind(peer)
    .fetch_one(pool)
    .await
}

async fn check(state: &AppState, own: Uuid, peer: Uuid) -> Result<(), ApiResult> {
    if own == peer {
        return Err(failure(
            StatusCode::BAD_REQUEST,
            "No puedes escribirte a ti mismo.",
        ));
    }
    match pueden_chatear(&state.pool, own, peer).await {
        Ok(true) => Ok(()),
        Ok(false) => Err(failure(StatusCode::FORBIDDEN, SOLO_AMIGOS)),
        Err(_) => Err(failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo verificar la amistad.",
        )),
    }
}

/// `GET /amigos/{user_id}/mensajes`: últimos 100 mensajes. La conversación
/// existe siempre (vacía si nunca se escribieron) y se marca como leída solo
/// hasta el último mensaje devuelto.
pub async fn historial(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Path(peer): Path<Uuid>,
) -> ApiResult {
    if let Err(error) = check(&state, auth.user_id, peer).await {
        return error;
    }
    let messages = sqlx::query_as::<_, MensajeAmistad>(
        "SELECT id, sender_id, recipient_id, content, 'text' AS kind, NULL::uuid AS reunion_id, \
                created_at, read_at \
         FROM (SELECT * FROM mensajes_amistad \
               WHERE LEAST(sender_id, recipient_id) = LEAST($1::uuid, $2::uuid) \
                 AND GREATEST(sender_id, recipient_id) = GREATEST($1::uuid, $2::uuid) \
               ORDER BY created_at DESC, id DESC LIMIT $3) recientes \
         ORDER BY created_at, id",
    )
    .bind(auth.user_id)
    .bind(peer)
    .bind(HISTORIAL)
    .fetch_all(&state.pool)
    .await;
    let Ok(messages) = messages else {
        return failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo cargar la conversación.",
        );
    };
    if let Some(newest) = messages.last().map(|m| m.created_at)
        && sqlx::query(
            "UPDATE mensajes_amistad SET read_at = NOW() WHERE sender_id = $1 \
             AND recipient_id = $2 AND read_at IS NULL AND created_at <= $3",
        )
        .bind(peer)
        .bind(auth.user_id)
        .bind(newest)
        .execute(&state.pool)
        .await
        .is_err()
    {
        return failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo actualizar el estado de lectura.",
        );
    }
    (
        StatusCode::OK,
        Json(json!({"success": true, "messages": messages})),
    )
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnviarMensaje {
    content: Option<String>,
}

/// `POST /amigos/{user_id}/mensajes` `{content}`.
pub async fn enviar(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path(peer): Path<Uuid>,
    Json(payload): Json<EnviarMensaje>,
) -> ApiResult {
    if let Err(error) = check(&state, auth.user_id, peer).await {
        return error;
    }
    let content = payload.content.unwrap_or_default().trim().to_string();
    if content.is_empty() || content.chars().count() > MAX_CARACTERES {
        return failure(
            StatusCode::BAD_REQUEST,
            "El mensaje debe tener entre 1 y 2000 caracteres.",
        );
    }
    let recent = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM mensajes_amistad WHERE sender_id = $1 \
         AND created_at > NOW() - INTERVAL '1 minute'",
    )
    .bind(auth.user_id)
    .fetch_one(&state.pool)
    .await;
    match recent {
        Ok(count) if count >= MAX_MENSAJES_POR_MINUTO => {
            return failure(
                StatusCode::TOO_MANY_REQUESTS,
                "Espera un momento antes de enviar más mensajes.",
            );
        }
        Ok(_) => {}
        Err(_) => {
            return failure(
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudo enviar el mensaje.",
            );
        }
    }
    let result = sqlx::query_as::<_, MensajeAmistad>(
        "INSERT INTO mensajes_amistad (sender_id, recipient_id, content) VALUES ($1, $2, $3) \
         RETURNING id, sender_id, recipient_id, content, 'text' AS kind, NULL::uuid AS reunion_id, \
                   created_at, read_at",
    )
    .bind(auth.user_id)
    .bind(peer)
    .bind(content)
    .fetch_one(&state.pool)
    .await;
    match result {
        Ok(message) => {
            // Despierta el canal en vivo: el contador de no leídos cambia.
            hub.changed();
            (
                StatusCode::CREATED,
                Json(json!({"success": true, "message": message})),
            )
        }
        Err(_) => failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo enviar el mensaje.",
        ),
    }
}

#[derive(sqlx::FromRow)]
struct FilaConversacion {
    user_id: Uuid,
    nombre: String,
    avatar_url: Option<String>,
    avatar_color: Option<String>,
    no_leidos: i64,
    #[sqlx(flatten)]
    ultimo: MensajeAmistad,
}

/// `GET /amigos/conversaciones`: bandeja de chats de amistad (amigos
/// actuales con al menos un mensaje), del más reciente al más antiguo.
pub async fn conversaciones(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
) -> ApiResult {
    let rows = sqlx::query_as::<_, FilaConversacion>(
        "SELECT u.id AS user_id, u.name AS nombre, u.avatar_url, u.avatar_color, \
                (SELECT COUNT(*) FROM mensajes_amistad x WHERE x.sender_id = u.id \
                 AND x.recipient_id = $1 AND x.read_at IS NULL) AS no_leidos, \
                m.id, m.sender_id, m.recipient_id, m.content, 'text' AS kind, \
                NULL::uuid AS reunion_id, m.created_at, m.read_at \
         FROM amistades a \
         JOIN users u ON u.id = CASE WHEN a.solicitante = $1 THEN a.destinatario ELSE a.solicitante END \
                     AND u.estado = 'ACTIVE' \
         JOIN LATERAL (SELECT * FROM mensajes_amistad m \
                       WHERE LEAST(m.sender_id, m.recipient_id) = LEAST($1::uuid, u.id) \
                         AND GREATEST(m.sender_id, m.recipient_id) = GREATEST($1::uuid, u.id) \
                       ORDER BY m.created_at DESC, m.id DESC LIMIT 1) m ON TRUE \
         WHERE a.estado = 'aceptada' AND $1 IN (a.solicitante, a.destinatario) \
           AND NOT EXISTS (SELECT 1 FROM bloqueos b WHERE (b.bloqueador = $1 AND b.bloqueado = u.id) \
                           OR (b.bloqueador = u.id AND b.bloqueado = $1)) \
         ORDER BY m.created_at DESC, u.id LIMIT 200",
    )
    .bind(auth.user_id)
    .fetch_all(&state.pool)
    .await;
    let Ok(rows) = rows else {
        return failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudieron cargar los chats de amigos.",
        );
    };
    let list: Vec<Value> = rows
        .into_iter()
        .map(|row| {
            json!({
                "user_id": row.user_id,
                "nombre": row.nombre,
                "avatar_url": row.avatar_url,
                "avatar_color": row.avatar_color,
                "no_leidos": row.no_leidos,
                "ultimo": row.ultimo,
            })
        })
        .collect();
    (
        StatusCode::OK,
        Json(json!({"success": true, "conversaciones": list})),
    )
}

/// Mensajes de amistad sin leer, para el canal en vivo.
pub async fn no_leidos(pool: &sqlx::PgPool, user: Uuid) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM mensajes_amistad m \
         JOIN amistades a ON a.estado = 'aceptada' \
              AND ((a.solicitante = m.sender_id AND a.destinatario = m.recipient_id) \
                OR (a.solicitante = m.recipient_id AND a.destinatario = m.sender_id)) \
         WHERE m.recipient_id = $1 AND m.read_at IS NULL",
    )
    .bind(user)
    .fetch_one(pool)
    .await
}
