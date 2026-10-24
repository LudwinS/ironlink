//! Mensajes privados e invitaciones visibles solo para dos miembros del nodo.
use axum::{
    Extension, Json,
    extract::{Path, State},
    http::StatusCode,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::auth::{middleware::AuthUser, verification::AppState};

type ApiResult = (StatusCode, Json<Value>);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SendDirect {
    pub content: Option<String>,
    pub reunion_id: Option<Uuid>,
}

#[derive(Serialize, sqlx::FromRow)]
struct DirectMessage {
    id: Uuid,
    nodo_id: Uuid,
    sender_id: Uuid,
    recipient_id: Uuid,
    content: String,
    kind: String,
    reunion_id: Option<Uuid>,
    created_at: DateTime<Utc>,
    read_at: Option<DateTime<Utc>>,
}

fn response(status: StatusCode, message: &str) -> ApiResult {
    (status, Json(json!({"success":false,"message":message})))
}

async fn allowed(state: &AppState, node: Uuid, user: Uuid) -> Result<bool, sqlx::Error> {
    sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM nodo_miembros nm \
         JOIN nodos n ON n.id = nm.nodo_id AND n.estado = 'active' \
         JOIN users u ON u.id = nm.user_id AND u.estado = 'ACTIVE' \
         WHERE nm.nodo_id = $1 AND nm.user_id = $2 \
         AND NOT EXISTS (SELECT 1 FROM nodo_baneos b \
                         WHERE b.nodo_id = $1 AND b.user_id = $2))",
    )
    .bind(node)
    .bind(user)
    .fetch_one(&state.pool)
    .await
}

async fn check_pair(state: &AppState, node: Uuid, own: Uuid, peer: Uuid) -> Result<(), ApiResult> {
    if own == peer {
        return Err(response(
            StatusCode::BAD_REQUEST,
            "No puedes escribirte a ti mismo.",
        ));
    }
    match (
        allowed(state, node, own).await,
        allowed(state, node, peer).await,
    ) {
        (Ok(true), Ok(true)) => Ok(()),
        (Ok(_), Ok(_)) => Err(response(
            StatusCode::FORBIDDEN,
            "Ambos usuarios deben pertenecer al nodo activo.",
        )),
        _ => Err(response(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo verificar la membresía.",
        )),
    }
}

pub async fn send(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Path((node, peer)): Path<(Uuid, Uuid)>,
    Json(payload): Json<SendDirect>,
) -> ApiResult {
    if let Err(error) = check_pair(&state, node, auth.user_id, peer).await {
        return error;
    }
    // Un bloqueo en cualquier sentido impide escribir también en el chat del
    // nodo. Respuesta genérica: no revela quién bloqueó a quién.
    match crate::amigos::hay_bloqueo(&state.pool, auth.user_id, peer).await {
        Ok(false) => {}
        Ok(true) => {
            return response(StatusCode::FORBIDDEN, "No se pudo enviar el mensaje.");
        }
        Err(_) => {
            return response(
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudo enviar el mensaje.",
            );
        }
    }
    let (content, kind, reunion) =
        if let Some(room) = payload.reunion_id {
            let title = sqlx::query_scalar::<_, String>(
            "SELECT titulo FROM reuniones WHERE id = $1 AND nodo_id = $2 AND rtc_estado = 'active'",
        ).bind(room).bind(node).fetch_optional(&state.pool).await;
            match title {
                Ok(Some(title)) => (
                    format!("Invitación a la videollamada: {title}"),
                    "call_invite",
                    Some(room),
                ),
                Ok(None) => {
                    return response(StatusCode::NOT_FOUND, "La videollamada ya no está activa.");
                }
                Err(_) => {
                    return response(
                        StatusCode::SERVICE_UNAVAILABLE,
                        "No se pudo verificar la videollamada.",
                    );
                }
            }
        } else {
            (
                payload.content.unwrap_or_default().trim().to_string(),
                "text",
                None,
            )
        };
    if content.is_empty() || content.chars().count() > 2000 {
        return response(
            StatusCode::BAD_REQUEST,
            "El mensaje debe tener entre 1 y 2000 caracteres.",
        );
    }
    let recent = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM direct_messages WHERE nodo_id = $1 AND sender_id = $2 \
         AND created_at > NOW() - INTERVAL '1 minute'",
    )
    .bind(node)
    .bind(auth.user_id)
    .fetch_one(&state.pool)
    .await;
    match recent {
        Ok(count) if count >= 60 => {
            return response(
                StatusCode::TOO_MANY_REQUESTS,
                "Espera un momento antes de enviar más mensajes.",
            );
        }
        Err(_) => {
            return response(
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudo enviar el mensaje.",
            );
        }
        _ => {}
    }
    let result = sqlx::query_as::<_, DirectMessage>(
        "INSERT INTO direct_messages (nodo_id, sender_id, recipient_id, content, kind, reunion_id) \
         VALUES ($1, $2, $3, $4, $5, $6) \
         RETURNING id, nodo_id, sender_id, recipient_id, content, kind, reunion_id, created_at, read_at",
    )
    .bind(node).bind(auth.user_id).bind(peer).bind(content).bind(kind).bind(reunion)
    .fetch_one(&state.pool).await;
    match result {
        Ok(message) => (
            StatusCode::CREATED,
            Json(json!({"success":true,"message":message})),
        ),
        Err(_) => response(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo enviar el mensaje.",
        ),
    }
}

pub async fn history(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Path((node, peer)): Path<(Uuid, Uuid)>,
) -> ApiResult {
    if let Err(error) = check_pair(&state, node, auth.user_id, peer).await {
        return error;
    }
    let messages = sqlx::query_as::<_, DirectMessage>(
        "SELECT id, nodo_id, sender_id, recipient_id, content, kind, reunion_id, created_at, read_at \
         FROM (SELECT * FROM direct_messages WHERE nodo_id = $1 \
          AND ((sender_id = $2 AND recipient_id = $3) OR (sender_id = $3 AND recipient_id = $2)) \
          ORDER BY created_at DESC, id DESC LIMIT 100) recent ORDER BY created_at, id",
    ).bind(node).bind(auth.user_id).bind(peer).fetch_all(&state.pool).await;
    let Ok(messages) = messages else {
        return response(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo cargar la conversación.",
        );
    };
    // Solo hasta el último mensaje devuelto: uno que llegue mientras tanto
    // sigue sin leer hasta que la persona lo vea en la siguiente consulta.
    let Some(newest) = messages.last().map(|m| m.created_at) else {
        return (
            StatusCode::OK,
            Json(json!({"success":true,"messages":messages})),
        );
    };
    if sqlx::query(
        "UPDATE direct_messages SET read_at = NOW() WHERE nodo_id = $1 \
       AND sender_id = $2 AND recipient_id = $3 AND read_at IS NULL AND created_at <= $4",
    )
    .bind(node)
    .bind(peer)
    .bind(auth.user_id)
    .bind(newest)
    .execute(&state.pool)
    .await
    .is_err()
    {
        return response(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo actualizar el estado de lectura.",
        );
    }
    (
        StatusCode::OK,
        Json(json!({"success":true,"messages":messages})),
    )
}

pub async fn inbox(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Path(node): Path<Uuid>,
) -> ApiResult {
    match allowed(&state, node, auth.user_id).await {
        Ok(true) => {}
        Ok(false) => return response(StatusCode::FORBIDDEN, "No perteneces a este nodo."),
        Err(_) => {
            return response(
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudo verificar la membresía.",
            );
        }
    }
    let messages = sqlx::query_as::<_, DirectMessage>(
        "SELECT id, nodo_id, sender_id, recipient_id, content, kind, reunion_id, created_at, read_at \
         FROM direct_messages WHERE nodo_id = $1 AND (sender_id = $2 OR recipient_id = $2) \
         ORDER BY created_at DESC, id DESC LIMIT 200",
    ).bind(node).bind(auth.user_id).fetch_all(&state.pool).await;
    match messages {
        Ok(messages) => (
            StatusCode::OK,
            Json(json!({"success":true,"messages":messages})),
        ),
        Err(_) => response(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo cargar la bandeja.",
        ),
    }
}
