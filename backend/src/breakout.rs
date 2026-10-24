//! Sprint 4 (IRL-RTC-US-07): salas de trabajo dentro de una reunión.
//!
//! Un moderador crea las salas y asigna participantes; el servidor avisa a
//! cada persona conectada por su canal de control y solo emite pases de
//! entrada a una sala para sus asignados o para quien modera. Las salas
//! comparten la reunión: permisos, expulsiones y asistencia siguen vigentes.
use crate::auth::{middleware::AuthUser, verification::AppState};
use crate::rtc::server::{MAX_PEERS, RoomHub, can_manage, member_allowed};
use axum::{
    Extension, Json,
    extract::{Path, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::PgPool;
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
};
use uuid::Uuid;

pub const MAX_SALAS: usize = 10;

/// ¿Puede `user` estar en la sala `sala` de la reunión `room`? Debe estar
/// abierta y la persona asignada a ella o con permiso de moderación.
pub async fn allowed(
    pool: &PgPool,
    room: Uuid,
    sala: Uuid,
    user: Uuid,
) -> Result<bool, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM reunion_salas s
         JOIN reuniones r ON r.id = s.reunion_id
         JOIN nodos n ON n.id = r.nodo_id
         JOIN nodo_miembros nm ON nm.nodo_id = n.id AND nm.user_id = $3
         WHERE s.id = $2 AND s.reunion_id = $1 AND s.closed_at IS NULL
         AND (EXISTS (SELECT 1 FROM reunion_sala_miembros sm WHERE sm.sala_id = s.id AND sm.user_id = $3)
              OR r.creado_por = $3 OR n.creador_id = $3 OR nm.rol IN ('ADMIN','MODERATOR')))",
    )
    .bind(room)
    .bind(sala)
    .bind(user)
    .fetch_one(pool)
    .await
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct SalaMember {
    user_id: Uuid,
    nombre: String,
}

#[derive(Serialize, Debug)]
pub struct Sala {
    id: Uuid,
    nombre: String,
    miembros: Vec<SalaMember>,
}

async fn open_salas(pool: &PgPool, room: Uuid) -> Result<Vec<Sala>, sqlx::Error> {
    let rows = sqlx::query_as::<_, (Uuid, String, Option<Uuid>, Option<String>)>(
        "SELECT s.id, s.nombre, sm.user_id, u.name FROM reunion_salas s
         LEFT JOIN reunion_sala_miembros sm ON sm.sala_id = s.id
         LEFT JOIN users u ON u.id = sm.user_id
         WHERE s.reunion_id = $1 AND s.closed_at IS NULL
         ORDER BY s.orden, u.name, sm.user_id",
    )
    .bind(room)
    .fetch_all(pool)
    .await?;
    let mut salas: Vec<Sala> = Vec::new();
    for (id, nombre, user, name) in rows {
        if salas.last().is_none_or(|s| s.id != id) {
            salas.push(Sala {
                id,
                nombre,
                miembros: vec![],
            });
        }
        if let (Some(user_id), Some(nombre)) = (user, name) {
            salas
                .last_mut()
                .unwrap()
                .miembros
                .push(SalaMember { user_id, nombre });
        }
    }
    Ok(salas)
}

fn assignment(salas: &[Sala], user: Uuid) -> Value {
    salas
        .iter()
        .find(|s| s.miembros.iter().any(|m| m.user_id == user))
        .map(|s| json!({"id": s.id, "nombre": s.nombre}))
        .unwrap_or(Value::Null)
}

/// Avisa a cada persona conectada de su sala (o `null` para la principal).
fn announce(hub: &RoomHub, room: Uuid, salas: &[Sala]) {
    for (user, _) in hub.channels(room) {
        let message = json!({"type":"breakout","version":1,"sala":assignment(salas, user)});
        hub.send_in_meeting(room, user, message.to_string());
    }
}

fn reply(status: StatusCode, message: &str) -> (StatusCode, Json<Value>) {
    (status, Json(json!({ "message": message })))
}

async fn state_for(
    pool: &PgPool,
    hub: &RoomHub,
    node: Uuid,
    room: Uuid,
    user: Uuid,
) -> Result<Value, sqlx::Error> {
    let salas = open_salas(pool, room).await?;
    let moderator = can_manage(pool, node, room, user).await?;
    let mut body = json!({
        "salas": salas,
        "mi_sala": assignment(&salas, user),
        "puede_moderar": moderator,
        "capacidad_por_sala": MAX_PEERS,
    });
    if moderator {
        // Quién está conectado y en qué canal, para repartir participantes.
        let channels = hub.channels(room);
        let ids: Vec<Uuid> = channels.iter().map(|(u, _)| *u).collect();
        let names: HashMap<Uuid, String> =
            sqlx::query_as::<_, (Uuid, String)>("SELECT id, name FROM users WHERE id = ANY($1)")
                .bind(&ids)
                .fetch_all(pool)
                .await?
                .into_iter()
                .collect();
        let mut connected: Vec<Value> = channels
            .into_iter()
            .map(|(user_id, channel)| {
                json!({
                    "user_id": user_id,
                    "nombre": names.get(&user_id).cloned().unwrap_or_default(),
                    "sala_id": if channel == room { None } else { Some(channel) },
                })
            })
            .collect();
        connected.sort_by(|a, b| a["nombre"].as_str().cmp(&b["nombre"].as_str()));
        body["conectados"] = Value::Array(connected);
    }
    Ok(body)
}

/// `GET /nodos/{id}/reuniones/{reunion_id}/salas` — miembros de la reunión.
pub async fn get(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path((node, room)): Path<(Uuid, Uuid)>,
) -> (StatusCode, Json<Value>) {
    match member_allowed(&state.pool, room, user.user_id).await {
        Ok(true) => {}
        Ok(false) => return reply(StatusCode::NOT_FOUND, "La reunión no está disponible."),
        Err(_) => {
            return reply(
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudieron cargar las salas.",
            );
        }
    }
    match state_for(&state.pool, &hub, node, room, user.user_id).await {
        Ok(body) => (StatusCode::OK, Json(body)),
        Err(_) => reply(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudieron cargar las salas.",
        ),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NewSala {
    nombre: String,
    #[serde(default)]
    miembros: Vec<Uuid>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SalasRequest {
    salas: Vec<NewSala>,
}

/// Valida forma y límites antes de tocar la base de datos.
fn validate(request: &SalasRequest) -> Result<(), &'static str> {
    if request.salas.is_empty() || request.salas.len() > MAX_SALAS {
        return Err("Crea entre 1 y 10 salas.");
    }
    let mut names = HashSet::new();
    let mut people = HashSet::new();
    for sala in &request.salas {
        let name = sala.nombre.trim();
        if name.is_empty() || name.chars().count() > 60 {
            return Err("Cada sala necesita un nombre de 1 a 60 caracteres.");
        }
        if !names.insert(name.to_lowercase()) {
            return Err("Los nombres de las salas deben ser distintos.");
        }
        if sala.miembros.len() > MAX_PEERS {
            return Err("Una sala supera la capacidad de la videollamada.");
        }
        for member in &sala.miembros {
            if !people.insert(*member) {
                return Err("Una persona solo puede estar en una sala.");
            }
        }
    }
    Ok(())
}

/// `PUT /nodos/{id}/reuniones/{reunion_id}/salas` — reemplaza las salas
/// abiertas por las indicadas. Solo moderadores y con la reunión en curso.
pub async fn replace(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path((node, room)): Path<(Uuid, Uuid)>,
    Json(request): Json<SalasRequest>,
) -> (StatusCode, Json<Value>) {
    if let Err(message) = validate(&request) {
        return reply(StatusCode::BAD_REQUEST, message);
    }
    match moderator_of_active(&state.pool, node, room, user.user_id).await {
        Ok(true) => {}
        Ok(false) => {
            return reply(
                StatusCode::FORBIDDEN,
                "Solo un moderador puede crear salas en una reunión en curso.",
            );
        }
        Err(_) => {
            return reply(
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudieron crear las salas.",
            );
        }
    }
    let members: Vec<Uuid> = request
        .salas
        .iter()
        .flat_map(|s| s.miembros.iter().copied())
        .collect();
    // Solo integrantes del nodo, sin baneo ni expulsión de esta reunión.
    let valid: i64 = match sqlx::query_scalar(
        "SELECT COUNT(DISTINCT nm.user_id) FROM nodo_miembros nm
         JOIN reuniones r ON r.nodo_id = nm.nodo_id AND r.id = $1
         JOIN users u ON u.id = nm.user_id AND u.estado = 'ACTIVE'
         WHERE nm.user_id = ANY($2)
         AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = nm.nodo_id AND b.user_id = nm.user_id)
         AND NOT EXISTS (SELECT 1 FROM rtc_participant_controls c WHERE c.reunion_id = r.id AND c.user_id = nm.user_id AND c.kicked)",
    )
    .bind(room)
    .bind(&members)
    .fetch_one(&state.pool)
    .await
    {
        Ok(count) => count,
        Err(_) => return reply(StatusCode::SERVICE_UNAVAILABLE, "No se pudieron crear las salas."),
    };
    if valid as usize != members.len() {
        return reply(
            StatusCode::BAD_REQUEST,
            "Alguien asignado no puede participar en esta reunión.",
        );
    }
    let saved = async {
        let mut tx = state.pool.begin().await?;
        sqlx::query("UPDATE reunion_salas SET closed_at = NOW() WHERE reunion_id = $1 AND closed_at IS NULL")
            .bind(room)
            .execute(&mut *tx)
            .await?;
        for (order, sala) in request.salas.iter().enumerate() {
            let id: Uuid = sqlx::query_scalar(
                "INSERT INTO reunion_salas (reunion_id, nombre, orden, creada_por) VALUES ($1, $2, $3, $4) RETURNING id",
            )
            .bind(room)
            .bind(sala.nombre.trim())
            .bind(order as i16)
            .bind(user.user_id)
            .fetch_one(&mut *tx)
            .await?;
            for member in &sala.miembros {
                sqlx::query("INSERT INTO reunion_sala_miembros (sala_id, user_id) VALUES ($1, $2)")
                    .bind(id)
                    .bind(member)
                    .execute(&mut *tx)
                    .await?;
            }
        }
        tx.commit().await
    }
    .await;
    if saved.is_err() {
        return reply(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudieron crear las salas.",
        );
    }
    finish(&state.pool, &hub, node, room, user.user_id).await
}

/// `DELETE /nodos/{id}/reuniones/{reunion_id}/salas` — cierra todas las salas
/// y devuelve a todos a la sala principal.
pub async fn close(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path((node, room)): Path<(Uuid, Uuid)>,
) -> (StatusCode, Json<Value>) {
    match moderator_of_active(&state.pool, node, room, user.user_id).await {
        Ok(true) => {}
        Ok(false) => {
            return reply(
                StatusCode::FORBIDDEN,
                "Solo un moderador puede cerrar las salas.",
            );
        }
        Err(_) => {
            return reply(
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudieron cerrar las salas.",
            );
        }
    }
    if close_all(&state.pool, room).await.is_err() {
        return reply(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudieron cerrar las salas.",
        );
    }
    finish(&state.pool, &hub, node, room, user.user_id).await
}

/// Al finalizar la reunión también se cierran sus salas.
pub async fn close_all(pool: &PgPool, room: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE reunion_salas SET closed_at = NOW() WHERE reunion_id = $1 AND closed_at IS NULL",
    )
    .bind(room)
    .execute(pool)
    .await
    .map(|_| ())
}

async fn moderator_of_active(
    pool: &PgPool,
    node: Uuid,
    room: Uuid,
    user: Uuid,
) -> Result<bool, sqlx::Error> {
    Ok(can_manage(pool, node, room, user).await? && member_allowed(pool, room, user).await?)
}

async fn finish(
    pool: &PgPool,
    hub: &RoomHub,
    node: Uuid,
    room: Uuid,
    user: Uuid,
) -> (StatusCode, Json<Value>) {
    match open_salas(pool, room).await {
        Ok(salas) => announce(hub, room, &salas),
        Err(_) => {
            return reply(
                StatusCode::SERVICE_UNAVAILABLE,
                "Las salas se guardaron, pero no se pudo avisar a los participantes.",
            );
        }
    }
    match state_for(pool, hub, node, room, user).await {
        Ok(body) => (StatusCode::OK, Json(body)),
        Err(_) => reply(
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudieron cargar las salas.",
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(salas: Vec<(&str, Vec<Uuid>)>) -> SalasRequest {
        SalasRequest {
            salas: salas
                .into_iter()
                .map(|(nombre, miembros)| NewSala {
                    nombre: nombre.into(),
                    miembros,
                })
                .collect(),
        }
    }

    #[test]
    fn requests_are_bounded_and_people_are_not_duplicated() {
        let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
        assert!(validate(&request(vec![("Sala 1", vec![a]), ("Sala 2", vec![b])])).is_ok());
        assert!(validate(&request(vec![])).is_err());
        assert!(validate(&request((0..11).map(|_| ("x", vec![])).collect())).is_err());
        assert!(validate(&request(vec![("  ", vec![])])).is_err());
        assert!(validate(&request(vec![("A", vec![]), ("a", vec![])])).is_err());
        assert!(validate(&request(vec![("A", vec![a]), ("B", vec![a])])).is_err());
        let crowd = (0..=MAX_PEERS).map(|_| Uuid::new_v4()).collect();
        assert!(validate(&request(vec![("A", crowd)])).is_err());
    }

    #[test]
    fn each_person_learns_only_their_own_room() {
        let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
        let salas = vec![Sala {
            id: Uuid::new_v4(),
            nombre: "Diseño".into(),
            miembros: vec![SalaMember {
                user_id: a,
                nombre: "Ana".into(),
            }],
        }];
        assert_eq!(assignment(&salas, a)["nombre"], "Diseño");
        assert_eq!(assignment(&salas, b), Value::Null);
    }
}
