//! Sprint 4 (IRL-RTC-US-08): pizarra compartida durante la reunión.
//!
//! Hay una pizarra por canal (sala principal o sala de trabajo). Los trazos
//! terminados se guardan, así la pizarra se recupera al entrar, reconectarse o
//! cambiar de sala, y se reenvían en vivo a quienes están en ese canal. Dibuja
//! quien modera; puede permitir que dibujen todos.
use crate::auth::{middleware::AuthUser, verification::AppState};
use crate::rtc::server::{RoomHub, can_manage, member_allowed};
use axum::{
    Extension, Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::PgPool;
use std::sync::Arc;
use uuid::Uuid;

pub const MAX_POINTS: usize = 2000;
pub const MAX_STROKES: i64 = 5000;
/// Paleta Nocturne más colores de estado; no se aceptan colores libres.
pub const COLORS: [&str; 7] = [
    "#e9e9ed", "#9184d9", "#ef4444", "#10b981", "#fcd34d", "#38bdf8", "#161826",
];

type Reply = (StatusCode, Json<Value>);

fn reply(status: StatusCode, message: &str) -> Reply {
    (status, Json(json!({ "message": message })))
}

const UNAVAILABLE: &str = "La pizarra no está disponible.";

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct Target {
    sala_id: Option<Uuid>,
}

struct Access {
    channel: Uuid,
    moderator: bool,
    everyone: bool,
}

impl Access {
    fn can_draw(&self) -> bool {
        self.moderator || self.everyone
    }
}

/// Miembro de la reunión en curso y, si es una sala, con acceso a ella.
async fn access(
    pool: &PgPool,
    node: Uuid,
    room: Uuid,
    user: Uuid,
    sala: Option<Uuid>,
) -> Result<Option<Access>, sqlx::Error> {
    if !member_allowed(pool, room, user).await? {
        return Ok(None);
    }
    if let Some(sala) = sala
        && !crate::breakout::allowed(pool, room, sala, user).await?
    {
        return Ok(None);
    }
    let channel = sala.unwrap_or(room);
    let moderator = can_manage(pool, node, room, user).await?;
    let everyone = sqlx::query_scalar::<_, bool>(
        "SELECT todos_dibujan FROM pizarra_permisos WHERE canal_id = $1 AND reunion_id = $2",
    )
    .bind(channel)
    .bind(room)
    .fetch_optional(pool)
    .await?
    .unwrap_or(false);
    Ok(Some(Access {
        channel,
        moderator,
        everyone,
    }))
}

#[derive(Serialize, sqlx::FromRow)]
struct Stroke {
    id: Uuid,
    user_id: Uuid,
    datos: Value,
}

/// `GET /nodos/{id}/reuniones/{reunion_id}/pizarra?sala_id=` — lienzo completo.
pub async fn get(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path((node, room)): Path<(Uuid, Uuid)>,
    Query(target): Query<Target>,
) -> Reply {
    let access = match access(&state.pool, node, room, user.user_id, target.sala_id).await {
        Ok(Some(access)) => access,
        Ok(None) => return reply(StatusCode::NOT_FOUND, UNAVAILABLE),
        Err(_) => {
            return reply(
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudo cargar la pizarra.",
            );
        }
    };
    // Secuencia leída ANTES de la consulta: cualquier evento posterior tiene
    // un número mayor y el cliente lo aplica (los duplicados se ignoran por ID).
    let seq = hub.whiteboard_seq(access.channel);
    match sqlx::query_as::<_, Stroke>(
        "SELECT id, user_id, datos FROM pizarra_trazos WHERE canal_id = $1 AND reunion_id = $2
         ORDER BY created_at, id LIMIT 5000",
    )
    .bind(access.channel)
    .bind(room)
    .fetch_all(&state.pool)
    .await
    {
        Ok(strokes) => (
            StatusCode::OK,
            Json(json!({
                "trazos": strokes,
                "puede_dibujar": access.can_draw(),
                "puede_moderar": access.moderator,
                "todos_dibujan": access.everyone,
                "seq": seq,
            })),
        ),
        Err(_) => reply(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo cargar la pizarra.",
        ),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NewStroke {
    sala_id: Option<Uuid>,
    puntos: Vec<[f64; 2]>,
    color: String,
    grosor: f64,
}

/// Valida el trazo y lo devuelve normalizado (coordenadas con 4 decimales).
fn normalize(stroke: &NewStroke) -> Result<Value, &'static str> {
    if stroke.puntos.is_empty() || stroke.puntos.len() > MAX_POINTS {
        return Err("Un trazo debe tener entre 1 y 2000 puntos.");
    }
    if !COLORS.contains(&stroke.color.as_str()) {
        return Err("Color no permitido.");
    }
    if !(1.0..=24.0).contains(&stroke.grosor) {
        return Err("El grosor debe estar entre 1 y 24.");
    }
    let mut points = Vec::with_capacity(stroke.puntos.len());
    for [x, y] in &stroke.puntos {
        if !x.is_finite() || !y.is_finite() || !(0.0..=1.0).contains(x) || !(0.0..=1.0).contains(y)
        {
            return Err("Las coordenadas deben estar entre 0 y 1.");
        }
        points.push([
            (x * 10_000.0).round() / 10_000.0,
            (y * 10_000.0).round() / 10_000.0,
        ]);
    }
    Ok(json!({ "puntos": points, "color": stroke.color, "grosor": stroke.grosor.round() }))
}

fn broadcast(hub: &RoomHub, channel: Uuid, event: Value) {
    // La secuencia se asigna y se difunde bajo el mismo orden de llamadas;
    // un salto en el cliente indica un evento perdido.
    let seq = hub.next_whiteboard_seq(channel);
    let mut message = json!({ "type": "whiteboard", "version": 1, "seq": seq });
    message
        .as_object_mut()
        .unwrap()
        .extend(event.as_object().unwrap().clone());
    hub.broadcast_channel(channel, &message.to_string());
}

/// `POST /nodos/{id}/reuniones/{reunion_id}/pizarra/trazos`.
pub async fn add_stroke(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path((node, room)): Path<(Uuid, Uuid)>,
    Json(stroke): Json<NewStroke>,
) -> Reply {
    let datos = match normalize(&stroke) {
        Ok(datos) => datos,
        Err(message) => return reply(StatusCode::BAD_REQUEST, message),
    };
    let access = match access(&state.pool, node, room, user.user_id, stroke.sala_id).await {
        Ok(Some(access)) => access,
        Ok(None) => return reply(StatusCode::NOT_FOUND, UNAVAILABLE),
        Err(_) => {
            return reply(
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudo guardar el trazo.",
            );
        }
    };
    if !access.can_draw() {
        return reply(
            StatusCode::FORBIDDEN,
            "El moderador no ha habilitado la pizarra para todos.",
        );
    }
    // Hay que estar en la llamada; además limita la frecuencia (10 por segundo).
    if !hub.allow_control(room, user.user_id) {
        return reply(
            StatusCode::TOO_MANY_REQUESTS,
            "Únete a la llamada o espera un momento para seguir dibujando.",
        );
    }
    let inserted = sqlx::query_scalar::<_, Uuid>(
        "INSERT INTO pizarra_trazos (reunion_id, canal_id, user_id, datos)
         SELECT $1, $2, $3, $4
         WHERE (SELECT COUNT(*) FROM pizarra_trazos WHERE canal_id = $2) < $5
         RETURNING id",
    )
    .bind(room)
    .bind(access.channel)
    .bind(user.user_id)
    .bind(&datos)
    .bind(MAX_STROKES)
    .fetch_optional(&state.pool)
    .await;
    match inserted {
        Ok(Some(id)) => {
            let stroke = json!({ "id": id, "user_id": user.user_id, "datos": datos });
            broadcast(
                &hub,
                access.channel,
                json!({ "op": "stroke", "trazo": stroke }),
            );
            (StatusCode::CREATED, Json(json!({ "trazo": stroke })))
        }
        Ok(None) => reply(
            StatusCode::CONFLICT,
            "La pizarra está llena. Límpiala para seguir dibujando.",
        ),
        Err(_) => reply(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo guardar el trazo.",
        ),
    }
}

/// `DELETE /nodos/{id}/reuniones/{reunion_id}/pizarra/trazos/{trazo_id}` —
/// cada quien deshace lo suyo; quien modera puede borrar cualquier trazo.
pub async fn delete_stroke(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path((node, room, stroke)): Path<(Uuid, Uuid, Uuid)>,
) -> Reply {
    let owner = sqlx::query_as::<_, (Uuid, Uuid)>(
        "SELECT canal_id, user_id FROM pizarra_trazos WHERE id = $1 AND reunion_id = $2",
    )
    .bind(stroke)
    .bind(room)
    .fetch_optional(&state.pool)
    .await;
    let (channel, author) = match owner {
        Ok(Some(row)) => row,
        Ok(None) => return reply(StatusCode::NOT_FOUND, "El trazo ya no existe."),
        Err(_) => {
            return reply(
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudo borrar el trazo.",
            );
        }
    };
    let sala = (channel != room).then_some(channel);
    let access = match access(&state.pool, node, room, user.user_id, sala).await {
        Ok(Some(access)) => access,
        Ok(None) => return reply(StatusCode::NOT_FOUND, UNAVAILABLE),
        Err(_) => {
            return reply(
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudo borrar el trazo.",
            );
        }
    };
    if !(access.moderator || (author == user.user_id && access.can_draw())) {
        return reply(
            StatusCode::FORBIDDEN,
            "Solo puedes borrar tus propios trazos.",
        );
    }
    match sqlx::query("DELETE FROM pizarra_trazos WHERE id = $1")
        .bind(stroke)
        .execute(&state.pool)
        .await
    {
        Ok(_) => {
            broadcast(&hub, channel, json!({ "op": "delete", "id": stroke }));
            (StatusCode::OK, Json(json!({ "eliminado": stroke })))
        }
        Err(_) => reply(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo borrar el trazo.",
        ),
    }
}

/// `DELETE /nodos/{id}/reuniones/{reunion_id}/pizarra?sala_id=` — limpia el
/// lienzo. Solo quien modera.
pub async fn clear(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path((node, room)): Path<(Uuid, Uuid)>,
    Query(target): Query<Target>,
) -> Reply {
    let access = match access(&state.pool, node, room, user.user_id, target.sala_id).await {
        Ok(Some(access)) if access.moderator => access,
        Ok(Some(_)) => {
            return reply(
                StatusCode::FORBIDDEN,
                "Solo un moderador puede limpiar la pizarra.",
            );
        }
        Ok(None) => return reply(StatusCode::NOT_FOUND, UNAVAILABLE),
        Err(_) => {
            return reply(
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudo limpiar la pizarra.",
            );
        }
    };
    match sqlx::query("DELETE FROM pizarra_trazos WHERE canal_id = $1 AND reunion_id = $2")
        .bind(access.channel)
        .bind(room)
        .execute(&state.pool)
        .await
    {
        Ok(_) => {
            broadcast(&hub, access.channel, json!({ "op": "clear" }));
            (StatusCode::OK, Json(json!({ "limpia": true })))
        }
        Err(_) => reply(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo limpiar la pizarra.",
        ),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Permissions {
    sala_id: Option<Uuid>,
    todos_dibujan: bool,
}

/// `PUT /nodos/{id}/reuniones/{reunion_id}/pizarra/permisos` — solo moderadores.
pub async fn set_permissions(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path((node, room)): Path<(Uuid, Uuid)>,
    Json(body): Json<Permissions>,
) -> Reply {
    let access = match access(&state.pool, node, room, user.user_id, body.sala_id).await {
        Ok(Some(access)) if access.moderator => access,
        Ok(Some(_)) => {
            return reply(
                StatusCode::FORBIDDEN,
                "Solo un moderador puede cambiar quién dibuja.",
            );
        }
        Ok(None) => return reply(StatusCode::NOT_FOUND, UNAVAILABLE),
        Err(_) => {
            return reply(
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudo cambiar el permiso.",
            );
        }
    };
    match sqlx::query(
        "INSERT INTO pizarra_permisos (canal_id, reunion_id, todos_dibujan) VALUES ($1, $2, $3)
         ON CONFLICT (canal_id) DO UPDATE SET todos_dibujan = EXCLUDED.todos_dibujan, updated_at = NOW()",
    )
    .bind(access.channel)
    .bind(room)
    .bind(body.todos_dibujan)
    .execute(&state.pool)
    .await
    {
        Ok(_) => {
            broadcast(
                &hub,
                access.channel,
                json!({ "op": "permissions", "todos_dibujan": body.todos_dibujan }),
            );
            (StatusCode::OK, Json(json!({ "todos_dibujan": body.todos_dibujan })))
        }
        Err(_) => reply(StatusCode::SERVICE_UNAVAILABLE, "No se pudo cambiar el permiso."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stroke(points: Vec<[f64; 2]>, color: &str, width: f64) -> NewStroke {
        NewStroke {
            sala_id: None,
            puntos: points,
            color: color.into(),
            grosor: width,
        }
    }

    #[test]
    fn strokes_are_validated_and_compacted() {
        let ok = normalize(&stroke(vec![[0.123456, 1.0], [0.0, 0.5]], "#9184d9", 4.4)).unwrap();
        assert_eq!(ok["puntos"][0], json!([0.1235, 1.0]));
        assert_eq!(ok["grosor"], json!(4.0));
        assert!(normalize(&stroke(vec![], "#9184d9", 4.0)).is_err());
        assert!(normalize(&stroke(vec![[0.5, 0.5]; MAX_POINTS + 1], "#9184d9", 4.0)).is_err());
        assert!(normalize(&stroke(vec![[1.2, 0.5]], "#9184d9", 4.0)).is_err());
        assert!(normalize(&stroke(vec![[f64::NAN, 0.5]], "#9184d9", 4.0)).is_err());
        assert!(normalize(&stroke(vec![[0.5, 0.5]], "red", 4.0)).is_err());
        assert!(normalize(&stroke(vec![[0.5, 0.5]], "#9184d9", 40.0)).is_err());
    }
}
