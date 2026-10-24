use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
    time::Duration,
};

use crate::attendance::Exit;
use axum::{
    Extension, Json,
    extract::{
        Path, Query, State,
        ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade},
    },
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::sync::{broadcast, mpsc};
use uuid::Uuid;

use crate::{
    auth::{middleware::AuthUser, session, verification::AppState},
    rtc::protocol::PeerSignal,
    rtc::protocol::{MAX_MESSAGE_BYTES, PARTICIPATION_CAPABILITIES, parse_client_signal},
};

/// (canal, usuario). El canal es la sala principal (ID de la reunión) o una
/// sala de trabajo (IRL-RTC-US-07). Cada persona ocupa un solo canal por reunión.
type RoomKey = (Uuid, Uuid);
pub(crate) const MAX_PEERS: usize = 3; // Mesh P2P acotada a tres dispositivos.
const MAX_EVENTS_PER_SECOND: u32 = 40;

enum HubEvent {
    Text(String),
    Close,
    /// La misma persona abrió otra conexión a la reunión (otro dispositivo o
    /// cambio de sala): esta no debe reconectarse automáticamente.
    Replaced,
    Kicked,
}

struct Peer {
    meeting: Uuid,
    connection_id: Uuid,
    sender: mpsc::Sender<HubEvent>,
    control_window: std::time::Instant,
    control_count: u8,
}

pub struct RoomHub {
    peers: Mutex<HashMap<RoomKey, Peer>>,
    online: Mutex<HashMap<Uuid, HashSet<Uuid>>>,
    changes: tokio::sync::watch::Sender<()>,
    /// IRL-RTC-US-08: secuencia de eventos de pizarra por canal. Los envíos
    /// usan `try_send` y pueden descartarse si la cola de alguien se llena; el
    /// cliente detecta el salto de secuencia y recarga el lienzo completo.
    whiteboard_seq: Mutex<HashMap<Uuid, u64>>,
}

impl Default for RoomHub {
    fn default() -> Self {
        let (changes, _) = tokio::sync::watch::channel(());
        Self {
            peers: Mutex::new(HashMap::new()),
            online: Mutex::new(HashMap::new()),
            changes,
            whiteboard_seq: Mutex::new(HashMap::new()),
        }
    }
}

impl RoomHub {
    pub fn changed(&self) {
        self.changes.send_replace(());
    }
    pub fn subscribe(&self) -> tokio::sync::watch::Receiver<()> {
        self.changes.subscribe()
    }
    pub fn presence(&self, user: Uuid) -> &'static str {
        if self.peers.lock().unwrap().keys().any(|(_, u)| *u == user) {
            "in_call"
        } else if self
            .online
            .lock()
            .unwrap()
            .get(&user)
            .is_some_and(|sessions| !sessions.is_empty())
        {
            "available"
        } else {
            "offline"
        }
    }
    pub fn live_join(&self, user: Uuid) -> Option<Uuid> {
        let mut online = self.online.lock().unwrap();
        let sessions = online.entry(user).or_default();
        if sessions.len() >= 4 {
            return None;
        }
        let id = Uuid::new_v4();
        sessions.insert(id);
        drop(online);
        self.changed();
        Some(id)
    }
    pub fn live_leave(&self, user: Uuid, id: Uuid) {
        let mut online = self.online.lock().unwrap();
        if let Some(sessions) = online.get_mut(&user) {
            sessions.remove(&id);
            if sessions.is_empty() {
                online.remove(&user);
            }
        }
        drop(online);
        self.changed();
    }
    /// Clave del canal donde está `user` dentro de la reunión, si está conectado.
    fn locate(peers: &HashMap<RoomKey, Peer>, meeting: Uuid, user: Uuid) -> Option<RoomKey> {
        peers
            .iter()
            .find(|((_, u), p)| *u == user && p.meeting == meeting)
            .map(|(key, _)| *key)
    }
    pub(crate) fn allow_control(&self, meeting: Uuid, actor: Uuid) -> bool {
        let mut peers = self.peers.lock().unwrap();
        let Some(key) = Self::locate(&peers, meeting, actor) else {
            return false;
        };
        let peer = peers.get_mut(&key).unwrap();
        if peer.control_window.elapsed() >= Duration::from_secs(1) {
            peer.control_window = std::time::Instant::now();
            peer.control_count = 0;
        }
        peer.control_count = peer.control_count.saturating_add(1);
        peer.control_count <= 10
    }
    /// Personas conectadas a la reunión, en cualquiera de sus canales.
    pub(crate) fn users(&self, meeting: Uuid) -> Vec<Uuid> {
        self.peers
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, p)| p.meeting == meeting)
            .map(|((_, user), _)| *user)
            .collect()
    }
    /// Siguiente número de secuencia de la pizarra del canal.
    pub(crate) fn next_whiteboard_seq(&self, channel: Uuid) -> u64 {
        let mut seqs = self.whiteboard_seq.lock().unwrap();
        let seq = seqs.entry(channel).or_insert(0);
        *seq += 1;
        *seq
    }
    /// Último número de secuencia emitido para la pizarra del canal.
    pub(crate) fn whiteboard_seq(&self, channel: Uuid) -> u64 {
        self.whiteboard_seq
            .lock()
            .unwrap()
            .get(&channel)
            .copied()
            .unwrap_or(0)
    }
    /// Envía un mensaje de control a todas las personas de un canal.
    pub(crate) fn broadcast_channel(&self, channel: Uuid, message: &str) {
        for ((c, _), peer) in self.peers.lock().unwrap().iter() {
            if *c == channel {
                let _ = peer.sender.try_send(HubEvent::Text(message.to_string()));
            }
        }
    }
    /// Canal actual de cada persona conectada a la reunión.
    pub(crate) fn channels(&self, meeting: Uuid) -> Vec<(Uuid, Uuid)> {
        self.peers
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, p)| p.meeting == meeting)
            .map(|((channel, user), _)| (*user, *channel))
            .collect()
    }

    fn evict(&self, meeting: Uuid, user: Uuid) {
        let mut peers = self.peers.lock().unwrap();
        let Some((channel, _)) = Self::locate(&peers, meeting, user) else {
            drop(peers);
            self.changed();
            return;
        };
        if let Some(peer) = peers.remove(&(channel, user)) {
            let _ = peer.sender.try_send(HubEvent::Kicked);
            let left = json!({"type":"peer_left","version":1,"user_id":user}).to_string();
            let mut failed = false;
            for ((r, _), other) in peers.iter() {
                if *r == channel {
                    failed |= other.sender.try_send(HubEvent::Text(left.clone())).is_err();
                }
            }
            if failed {
                // Never retain a receiver that could not learn of an expulsion.
                peers.retain(|(r, _), other| {
                    if *r == channel {
                        let _ = other.sender.try_send(HubEvent::Close);
                        false
                    } else {
                        true
                    }
                });
            }
        }
        self.changed();
    }
    /// Admite a `user` en `channel`. Si estaba en otro canal de la misma
    /// reunión (cambio de sala) o con otra conexión, la anterior se cierra.
    fn join(
        &self,
        meeting: Uuid,
        channel: Uuid,
        user: Uuid,
        sender: mpsc::Sender<HubEvent>,
    ) -> Result<(Uuid, Vec<Uuid>), ()> {
        let mut peers = self.peers.lock().unwrap();
        let others: Vec<_> = peers
            .keys()
            .filter(|(r, u)| *r == channel && *u != user)
            .map(|(_, u)| *u)
            .collect();
        if others.len() >= MAX_PEERS {
            return Err(());
        }
        if let Some(previous) = Self::locate(&peers, meeting, user).filter(|(c, _)| *c != channel) {
            if let Some(old) = peers.remove(&previous) {
                let _ = old.sender.try_send(HubEvent::Replaced);
            }
            let left = json!({"type":"peer_left","version":1,"user_id":user}).to_string();
            for ((r, _), other) in peers.iter() {
                if *r == previous.0 {
                    let _ = other.sender.try_send(HubEvent::Text(left.clone()));
                }
            }
        }
        let connection_id = Uuid::new_v4();
        if let Some(previous) = peers.insert(
            (channel, user),
            Peer {
                meeting,
                connection_id,
                sender,
                control_window: std::time::Instant::now(),
                control_count: 0,
            },
        ) {
            let _ = previous.sender.try_send(HubEvent::Replaced);
        }
        let joined = json!({"type":"peer_joined","version":1,"user_id":user}).to_string();
        for other in &others {
            if let Some(peer) = peers.get(&(channel, *other)) {
                let _ = peer.sender.try_send(HubEvent::Text(joined.clone()));
            }
        }
        self.changed();
        Ok((connection_id, others))
    }

    fn current(&self, room: Uuid, user: Uuid, connection_id: Uuid) -> bool {
        self.peers
            .lock()
            .unwrap()
            .get(&(room, user))
            .is_some_and(|p| p.connection_id == connection_id)
    }

    /// Señalización WebRTC: solo entre personas del mismo canal.
    fn relay(&self, channel: Uuid, recipient: Uuid, message: String) -> bool {
        self.peers
            .lock()
            .unwrap()
            .get(&(channel, recipient))
            .is_some_and(|peer| peer.sender.try_send(HubEvent::Text(message)).is_ok())
    }
    /// Mensaje de control para alguien de la reunión, esté en el canal que esté.
    pub(crate) fn send_in_meeting(&self, meeting: Uuid, recipient: Uuid, message: String) -> bool {
        let peers = self.peers.lock().unwrap();
        Self::locate(&peers, meeting, recipient)
            .and_then(|key| peers.get(&key))
            .is_some_and(|peer| peer.sender.try_send(HubEvent::Text(message)).is_ok())
    }

    fn leave(&self, room: Uuid, user: Uuid, connection_id: Uuid) {
        let mut peers = self.peers.lock().unwrap();
        if peers
            .get(&(room, user))
            .is_none_or(|p| p.connection_id != connection_id)
        {
            return;
        }
        peers.remove(&(room, user));
        self.changed();
        let left = json!({"type":"peer_left","version":1,"user_id":user}).to_string();
        for ((r, _), peer) in peers.iter() {
            if *r == room {
                let _ = peer.sender.try_send(HubEvent::Text(left.clone()));
            }
        }
    }

    /// Cierra la reunión entera: sala principal y salas de trabajo.
    fn close_room(&self, meeting: Uuid) {
        let mut peers = self.peers.lock().unwrap();
        peers.retain(|_, peer| {
            if peer.meeting == meeting {
                let _ = peer.sender.try_send(HubEvent::Close);
                false
            } else {
                true
            }
        });
        self.changed();
    }
}

type ApiResult = (StatusCode, Json<Value>);
fn answer(status: StatusCode, code: &str) -> ApiResult {
    (
        status,
        Json(json!({"success": status.is_success(), "code": code})),
    )
}

pub(crate) async fn member_allowed(
    pool: &PgPool,
    room: Uuid,
    user: Uuid,
) -> Result<bool, sqlx::Error> {
    sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM reuniones r
         JOIN nodos n ON n.id = r.nodo_id AND n.estado = 'active'
         JOIN nodo_miembros nm ON nm.nodo_id = n.id AND nm.user_id = $2
         JOIN users u ON u.id = $2 AND u.estado = 'ACTIVE'
         WHERE r.id = $1 AND r.rtc_estado = 'active'
         AND (NOT r.privada OR r.creado_por = $2 OR EXISTS (SELECT 1 FROM reunion_invitados i WHERE i.reunion_id = r.id AND i.user_id = $2))
         AND NOT EXISTS (SELECT 1 FROM rtc_participant_controls c WHERE c.reunion_id = r.id AND c.user_id = $2 AND c.kicked)
         AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = n.id AND b.user_id = $2))",
    )
    .bind(room)
    .bind(user)
    .fetch_one(pool)
    .await
}

#[derive(Debug, Clone, Serialize)]
struct Permissions {
    microphone_allowed: bool,
    camera_allowed: bool,
    kicked: bool,
}

async fn permissions(pool: &PgPool, room: Uuid, user: Uuid) -> Result<Permissions, sqlx::Error> {
    let value = sqlx::query_as::<_, (bool, bool, bool)>("SELECT microphone_allowed, camera_allowed, kicked FROM rtc_participant_controls WHERE reunion_id = $1 AND user_id = $2")
        .bind(room).bind(user).fetch_optional(pool).await?.unwrap_or((true, true, false));
    Ok(Permissions {
        microphone_allowed: value.0,
        camera_allowed: value.1,
        kicked: value.2,
    })
}

#[derive(Debug, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum ModerationRequest {
    MuteAll,
    Microphone { target: Uuid, allowed: bool },
    Camera { target: Uuid, allowed: bool },
    Kick { target: Uuid },
}

pub async fn moderate(
    State(state): State<AppState>,
    Extension(actor): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path((node, room)): Path<(Uuid, Uuid)>,
    Json(request): Json<ModerationRequest>,
) -> ApiResult {
    match can_manage(&state.pool, node, room, actor.user_id).await {
        Ok(true) => {}
        Ok(false) => return answer(StatusCode::FORBIDDEN, "not_moderator"),
        Err(_) => return answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable"),
    }
    match member_allowed(&state.pool, room, actor.user_id).await {
        Ok(true) => {}
        Ok(false) => return answer(StatusCode::CONFLICT, "meeting_unavailable"),
        Err(_) => return answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable"),
    }
    let connected = hub.users(room);
    if !connected.contains(&actor.user_id) {
        return answer(StatusCode::CONFLICT, "join_before_moderating");
    }
    if !hub.allow_control(room, actor.user_id) {
        return answer(StatusCode::TOO_MANY_REQUESTS, "moderation_rate_limit");
    }
    let targets = match request {
        ModerationRequest::MuteAll => connected
            .iter()
            .copied()
            .filter(|u| *u != actor.user_id)
            .collect(),
        ModerationRequest::Microphone { target, .. }
        | ModerationRequest::Camera { target, .. }
        | ModerationRequest::Kick { target } => vec![target],
    };
    let mut changes = Vec::new();
    for target in targets {
        if target == actor.user_id || !connected.contains(&target) {
            return answer(StatusCode::BAD_REQUEST, "invalid_target");
        }
        match member_allowed(&state.pool, room, target).await {
            Ok(true) => {}
            Ok(false) => return answer(StatusCode::FORBIDDEN, "invalid_target"),
            Err(_) => return answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable"),
        }
        match can_manage(&state.pool, node, room, target).await {
            Ok(true) if matches!(request, ModerationRequest::MuteAll) => continue,
            Ok(true) => return answer(StatusCode::FORBIDDEN, "protected_moderator"),
            Ok(false) => changes.push(target),
            Err(_) => return answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable"),
        }
    }
    let Ok(mut tx) = state.pool.begin().await else {
        return answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable");
    };
    let mut updates = Vec::new();
    for target in changes {
        let (query, allowed) = match request {
            ModerationRequest::MuteAll | ModerationRequest::Microphone { .. } => (
                "INSERT INTO rtc_participant_controls (reunion_id, user_id, microphone_allowed) VALUES ($1, $2, $3) ON CONFLICT (reunion_id, user_id) DO UPDATE SET microphone_allowed = EXCLUDED.microphone_allowed, updated_at = NOW() RETURNING microphone_allowed, camera_allowed, kicked",
                match request {
                    ModerationRequest::Microphone { allowed, .. } => allowed,
                    _ => false,
                },
            ),
            ModerationRequest::Camera { allowed, .. } => (
                "INSERT INTO rtc_participant_controls (reunion_id, user_id, camera_allowed) VALUES ($1, $2, $3) ON CONFLICT (reunion_id, user_id) DO UPDATE SET camera_allowed = EXCLUDED.camera_allowed, updated_at = NOW() RETURNING microphone_allowed, camera_allowed, kicked",
                allowed,
            ),
            ModerationRequest::Kick { .. } => (
                "INSERT INTO rtc_participant_controls (reunion_id, user_id, kicked) VALUES ($1, $2, $3) ON CONFLICT (reunion_id, user_id) DO UPDATE SET kicked = EXCLUDED.kicked, updated_at = NOW() RETURNING microphone_allowed, camera_allowed, kicked",
                true,
            ),
        };
        let result = sqlx::query_as::<_, (bool, bool, bool)>(query)
            .bind(room)
            .bind(target)
            .bind(allowed)
            .fetch_one(&mut *tx)
            .await;
        let Ok((microphone_allowed, camera_allowed, kicked)) = result else {
            return answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable");
        };
        if kicked
            && sqlx::query("DELETE FROM rtc_tickets WHERE reunion_id = $1 AND user_id = $2")
                .bind(room)
                .bind(target)
                .execute(&mut *tx)
                .await
                .is_err()
        {
            return answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable");
        }
        updates.push((
            target,
            Permissions {
                microphone_allowed,
                camera_allowed,
                kicked,
            },
        ));
    }
    if tx.commit().await.is_err() {
        return answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable");
    }
    for (target, controls) in &updates {
        if controls.kicked
            || !hub.send_in_meeting(
                room,
                *target,
                json!({"type":"permissions","data":controls}).to_string(),
            )
        {
            hub.evict(room, *target);
        }
        if !controls.kicked {
            for receiver in hub.users(room).into_iter().filter(|u| u != target) {
                if !hub.send_in_meeting(
                    room,
                    receiver,
                    json!({"type":"participant_permissions","user_id":target,"data":controls})
                        .to_string(),
                ) {
                    hub.evict(room, receiver);
                }
            }
        }
    }
    (
        StatusCode::OK,
        Json(json!({"success":true,"affected":updates.len()})),
    )
}

pub(crate) async fn can_manage(
    pool: &PgPool,
    node: Uuid,
    room: Uuid,
    user: Uuid,
) -> Result<bool, sqlx::Error> {
    sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM reuniones r
         JOIN nodos n ON n.id = r.nodo_id AND n.estado = 'active'
         JOIN nodo_miembros nm ON nm.nodo_id = n.id AND nm.user_id = $3
         JOIN users u ON u.id = $3 AND u.estado = 'ACTIVE'
         WHERE r.id = $2 AND n.id = $1
         AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = n.id AND b.user_id = $3)
         AND (r.creado_por = $3 OR n.creador_id = $3 OR nm.rol IN ('ADMIN','MODERATOR')))",
    )
    .bind(node)
    .bind(room)
    .bind(user)
    .fetch_one(pool)
    .await
}

pub async fn start_meeting(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path((node, room)): Path<(Uuid, Uuid)>,
) -> ApiResult {
    match can_manage(&state.pool, node, room, user.user_id).await {
        Ok(true) => {}
        Ok(false) => return answer(StatusCode::FORBIDDEN, "not_moderator"),
        Err(_) => return answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable"),
    }
    match sqlx::query(
        "UPDATE reuniones SET rtc_estado = 'active', rtc_started_at = NOW(), rtc_ended_at = NULL
        WHERE id = $1 AND nodo_id = $2 AND rtc_estado = 'scheduled'",
    )
    .bind(room)
    .bind(node)
    .execute(&state.pool)
    .await
    {
        Ok(result) if result.rows_affected() == 1 => {
            crate::notifications::meeting_started(&state.pool, room, user.user_id).await;
            hub.changed();
            answer(StatusCode::OK, "meeting_started")
        }
        Ok(_) => answer(StatusCode::CONFLICT, "meeting_not_scheduled"),
        Err(_) => answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable"),
    }
}

pub async fn end_meeting(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path((node, room)): Path<(Uuid, Uuid)>,
) -> ApiResult {
    match can_manage(&state.pool, node, room, user.user_id).await {
        Ok(true) => {}
        Ok(false) => return answer(StatusCode::FORBIDDEN, "not_moderator"),
        Err(_) => return answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable"),
    }
    match sqlx::query(
        "UPDATE reuniones SET rtc_estado = 'ended', rtc_ended_at = NOW()
        WHERE id = $1 AND nodo_id = $2 AND rtc_estado = 'active'",
    )
    .bind(room)
    .bind(node)
    .execute(&state.pool)
    .await
    {
        Ok(result) if result.rows_affected() == 1 => {
            crate::attendance::close_meeting(&state.pool, room).await;
            let _ = crate::breakout::close_all(&state.pool, room).await;
            hub.close_room(room);
            answer(StatusCode::OK, "meeting_ended")
        }
        Ok(_) => answer(StatusCode::CONFLICT, "meeting_not_active"),
        Err(_) => answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable"),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TicketTarget {
    /// Sala de trabajo a la que conectarse; sin valor, la sala principal.
    sala_id: Option<Uuid>,
}

pub async fn issue_ticket(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Path((node, room)): Path<(Uuid, Uuid)>,
    Query(target): Query<TicketTarget>,
) -> ApiResult {
    // El INSERT es condicional; no se emiten pases para no miembros o salas inactivas.
    let ticket = Uuid::new_v4();
    let inserted = sqlx::query(
        "INSERT INTO rtc_tickets (id, reunion_id, user_id, expires_at, sala_id, version_sesion)
        SELECT $1, r.id, $2, NOW() + INTERVAL '60 seconds', $5, $6 FROM reuniones r
        JOIN nodos n ON n.id = r.nodo_id AND n.estado = 'active'
        JOIN nodo_miembros nm ON nm.nodo_id = n.id AND nm.user_id = $2
        JOIN users u ON u.id = $2 AND u.estado = 'ACTIVE' AND u.version_sesion = $6
        WHERE r.id = $3 AND n.id = $4 AND r.rtc_estado = 'active'
        AND (NOT r.privada OR r.creado_por = $2 OR EXISTS (SELECT 1 FROM reunion_invitados i WHERE i.reunion_id = r.id AND i.user_id = $2))
        AND NOT EXISTS (SELECT 1 FROM rtc_participant_controls c WHERE c.reunion_id = r.id AND c.user_id = $2 AND c.kicked)
        AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = n.id AND b.user_id = $2)
        AND ($5::uuid IS NULL OR EXISTS (SELECT 1 FROM reunion_salas s WHERE s.id = $5 AND s.reunion_id = r.id AND s.closed_at IS NULL
             AND (EXISTS (SELECT 1 FROM reunion_sala_miembros sm WHERE sm.sala_id = s.id AND sm.user_id = $2)
                  OR r.creado_por = $2 OR n.creador_id = $2 OR nm.rol IN ('ADMIN','MODERATOR'))))",
    )
    .bind(ticket)
    .bind(user.user_id)
    .bind(room)
    .bind(node)
    .bind(target.sala_id)
    .bind(user.session_version)
    .execute(&state.pool)
    .await;
    match inserted {
        Ok(result) if result.rows_affected() == 1 => (
            StatusCode::OK,
            Json(json!({
                "success": true, "ticket": ticket, "expires_in_seconds": 60,
            })),
        ),
        Ok(_) => answer(StatusCode::FORBIDDEN, "meeting_unavailable"),
        Err(_) => answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable"),
    }
}

#[derive(Deserialize)]
pub struct TicketQuery {
    ticket: String,
}

/// Devuelve reunión, usuario, sala y la versión de sesión del pase.
async fn consume_ticket(
    pool: &PgPool,
    ticket: Uuid,
) -> Result<Option<(Uuid, Uuid, Option<Uuid>, i32)>, sqlx::Error> {
    sqlx::query_as::<_, (Uuid, Uuid, Option<Uuid>, i32)>(
        "DELETE FROM rtc_tickets t USING reuniones r, nodos n, nodo_miembros nm, users u
         WHERE t.id = $1 AND t.expires_at > NOW()
         AND r.id = t.reunion_id AND r.rtc_estado = 'active'
         AND n.id = r.nodo_id AND n.estado = 'active'
         AND nm.nodo_id = n.id AND nm.user_id = t.user_id
         AND u.id = t.user_id AND u.estado = 'ACTIVE' AND u.version_sesion = t.version_sesion
         AND (NOT r.privada OR r.creado_por = t.user_id OR EXISTS (SELECT 1 FROM reunion_invitados i WHERE i.reunion_id = r.id AND i.user_id = t.user_id))
         AND NOT EXISTS (SELECT 1 FROM rtc_participant_controls c WHERE c.reunion_id = r.id AND c.user_id = t.user_id AND c.kicked)
         AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = n.id AND b.user_id = t.user_id)
         AND (t.sala_id IS NULL OR EXISTS (SELECT 1 FROM reunion_salas s WHERE s.id = t.sala_id AND s.closed_at IS NULL))
         RETURNING t.reunion_id, t.user_id, t.sala_id, t.version_sesion"
    ).bind(ticket).fetch_optional(pool).await
}

pub async fn websocket(
    ws: WebSocketUpgrade,
    Query(query): Query<TicketQuery>,
    State(state): State<AppState>,
    Extension(hub): Extension<Arc<RoomHub>>,
) -> Response {
    let Ok(ticket) = Uuid::parse_str(&query.ticket) else {
        return answer(StatusCode::UNAUTHORIZED, "invalid_ticket").into_response();
    };
    // DELETE RETURNING consume el pase exactamente una vez, incluso ante carreras.
    let admitted = consume_ticket(&state.pool, ticket).await;
    match admitted {
        Ok(Some((room, user, sala, version))) => ws
            .max_message_size(MAX_MESSAGE_BYTES)
            .max_frame_size(MAX_MESSAGE_BYTES)
            .on_upgrade(move |socket| {
                handle_socket(socket, state.pool, hub, room, user, sala, version)
            }),
        Ok(None) => answer(StatusCode::UNAUTHORIZED, "invalid_ticket").into_response(),
        Err(_) => answer(StatusCode::SERVICE_UNAVAILABLE, "database_unavailable").into_response(),
    }
}

async fn handle_socket(
    mut socket: WebSocket,
    pool: PgPool,
    hub: Arc<RoomHub>,
    room: Uuid,
    user: Uuid,
    sala: Option<Uuid>,
    version: i32,
) {
    // Una revocación entre el canje del pase y la suscripción no se pierde:
    // se compara la versión ya suscritos.
    let mut revocations = session::revocations();
    if !matches!(session::current_version(&pool, user).await, Ok(Some(v)) if v == version) {
        let _ = socket.send(revoked_close()).await;
        return;
    }
    // Canal de medios: la sala principal (la reunión) o una sala de trabajo.
    // Permisos, moderación y asistencia siguen siendo de la reunión.
    let channel = sala.unwrap_or(room);
    let Ok(controls) = permissions(&pool, room, user).await else {
        return;
    };
    if controls.kicked || !matches!(member_allowed(&pool, room, user).await, Ok(true)) {
        return;
    }
    let node = sqlx::query_scalar::<_, Uuid>("SELECT nodo_id FROM reuniones WHERE id = $1")
        .bind(room)
        .fetch_one(&pool)
        .await;
    let Ok(node) = node else {
        return;
    };
    let Ok(can_moderate) = can_manage(&pool, node, room, user).await else {
        return;
    };
    let (tx, mut rx) = mpsc::channel::<HubEvent>(64);
    let Ok((connection_id, others)) = hub.join(room, channel, user, tx) else {
        let _ = socket
            .send(Message::Text(
                json!({"type":"error","code":"room_full"})
                    .to_string()
                    .into(),
            ))
            .await;
        let _ = socket.send(Message::Close(None)).await;
        return;
    };
    // Revalidate after insertion: an expulsion may have raced with admission.
    let Ok(controls) = permissions(&pool, room, user).await else {
        hub.leave(channel, user, connection_id);
        return;
    };
    if controls.kicked || !matches!(member_allowed(&pool, room, user).await, Ok(true)) {
        hub.leave(channel, user, connection_id);
        return;
    }
    let mut last_permissions = serde_json::to_value(&controls).unwrap();
    let mut peer_permissions = serde_json::Map::new();
    for other in &others {
        let Ok(policy) = permissions(&pool, room, *other).await else {
            hub.leave(channel, user, connection_id);
            return;
        };
        peer_permissions.insert(other.to_string(), serde_json::to_value(policy).unwrap());
        if !hub.relay(
            channel,
            *other,
            json!({"type":"participant_permissions","user_id":user,"data":controls}).to_string(),
        ) {
            hub.evict(room, *other);
        }
    }
    let welcome =
        json!({"type":"room_state","version":1,"user_id":user,"peers":others,"sala_id":sala,
            "capabilities":([PARTICIPATION_CAPABILITIES.as_slice(), &["moderation"]].concat()),
            "permissions":controls,"can_moderate":can_moderate,"peer_permissions":peer_permissions})
        .to_string();
    if socket.send(Message::Text(welcome.into())).await.is_err() {
        hub.leave(channel, user, connection_id);
        return;
    }
    // IRL-SEC-US-01: la asistencia empieza cuando la sala admitió la conexión.
    crate::attendance::open(&pool, room, user, connection_id, sala).await;
    let mut exit = Exit::Lost;
    let mut close = Message::Close(None);
    let started = tokio::time::Instant::now();
    let mut heartbeat = tokio::time::interval(Duration::from_secs(5));
    let mut window = tokio::time::Instant::now();
    let mut count = 0u32;
    loop {
        tokio::select! {
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Text(raw))) => {
                    if !hub.current(channel, user, connection_id) { exit = Exit::Replaced; break; }
                    if window.elapsed() >= Duration::from_secs(1) { window = tokio::time::Instant::now(); count = 0; }
                    count += 1;
                    if count > MAX_EVENTS_PER_SECOND { eprintln!("RTC límite de eventos excedido"); break; }
                    let signal = match parse_client_signal(raw.as_bytes(), user) {
                        Ok(signal) => signal,
                        Err(reason) => { eprintln!("RTC señal rechazada: {reason:?}"); break; }
                    };
                    let recipient = signal.recipient;
                    // La pertenencia se revalida para emisor y destinatario EN CADA evento.
                    let (source_ok, target_ok) = tokio::join!(
                        member_allowed(&pool, room, user), member_allowed(&pool, room, recipient)
                    );
                    if !matches!(source_ok, Ok(true)) { eprintln!("RTC emisor sin autorización activa"); exit = Exit::Unauthorized; break; }
                    if !matches!(target_ok, Ok(true)) { continue; }
                    let Ok(controls) = permissions(&pool, room, user).await else { break; };
                    let blocked = match &signal.signal {
                        PeerSignal::MicrophoneState(payload) => payload.enabled && !controls.microphone_allowed,
                        PeerSignal::CameraState(payload) | PeerSignal::ScreenState(payload) => payload.enabled && !controls.camera_allowed,
                        _ => false,
                    };
                    if blocked {
                        if socket.send(Message::Text(json!({"type":"permissions","data":controls}).to_string().into())).await.is_err() { break; }
                        continue;
                    }
                    let relay = json!({"type":"signal","data":signal.into_server(user)}).to_string();
                    if !hub.relay(channel, recipient, relay) {
                        let error = json!({"type":"error","code":"recipient_unavailable"}).to_string();
                        if socket.send(Message::Text(error.into())).await.is_err() { break; }
                    }
                }
                Some(Ok(Message::Close(_))) => { eprintln!("RTC par cerró socket"); exit = Exit::Left; break; },
                None => { eprintln!("RTC socket terminó"); break; },
                Some(Err(error)) => { eprintln!("RTC error de socket: {error}"); break; },
                Some(Ok(_)) => {},
            },
            outbound = rx.recv() => match outbound {
                Some(HubEvent::Text(text)) => {
                    if !hub.current(channel, user, connection_id) {
                        exit = Exit::Replaced;
                        if permissions(&pool, room, user).await.is_ok_and(|policy| policy.kicked) {
                            let _ = socket.send(Message::Text(json!({"type":"removed"}).to_string().into())).await;
                            exit = Exit::Kicked;
                        }
                        break;
                    }
                    if socket.send(Message::Text(text.into())).await.is_err() { break; }
                },
                // Si la sala se finalizó, end_meeting ya cerró la sesión con ese motivo.
                Some(HubEvent::Close) => { eprintln!("RTC sala finalizada o cerrada"); exit = Exit::Replaced; break; },
                Some(HubEvent::Replaced) => {
                    let _ = socket.send(Message::Text(json!({"type":"replaced"}).to_string().into())).await;
                    exit = Exit::Replaced;
                    break;
                },
                Some(HubEvent::Kicked) => {
                    let _ = socket.send(Message::Text(json!({"type":"removed"}).to_string().into())).await;
                    exit = Exit::Kicked;
                    break;
                },
                None => { eprintln!("RTC canal interno terminó"); break; },
            },
            revocation = revocations.recv() => {
                let revoked = match revocation {
                    Ok(id) => id == user,
                    // Se perdieron avisos: se comprueba la versión directamente.
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        !matches!(session::current_version(&pool, user).await, Ok(Some(v)) if v == version)
                    }
                    Err(broadcast::error::RecvError::Closed) => false,
                };
                if revoked {
                    // Los medios siguen por P2P; el cliente renueva el pase con
                    // su JWT renovado, como al cumplirse los 15 minutos.
                    let _ = socket.send(Message::Text(json!({"type":"session_renew"}).to_string().into())).await;
                    exit = Exit::SessionLimit;
                    close = revoked_close();
                    break;
                }
            },
            _ = heartbeat.tick() => {
                if started.elapsed() >= Duration::from_secs(15 * 60) {
                    // El pase se renueva cada 15 min para revalidar el acceso; el
                    // cliente se reconecta solo al recibir este aviso.
                    let _ = socket.send(Message::Text(json!({"type":"session_renew"}).to_string().into())).await;
                    exit = Exit::SessionLimit;
                    break;
                }
                if !hub.current(channel, user, connection_id) { exit = Exit::Replaced; break; }
                if !matches!(member_allowed(&pool, room, user).await, Ok(true)) { eprintln!("RTC conexión sin autorización en heartbeat"); exit = Exit::Unauthorized; break; }
                if let Some(sala) = sala
                    && !matches!(crate::breakout::allowed(&pool, room, sala, user).await, Ok(true))
                {
                    // La sala se cerró o la persona fue reasignada.
                    exit = Exit::Unauthorized;
                    break;
                }
                if socket.send(Message::Ping(Vec::new().into())).await.is_err() { break; }
                crate::attendance::touch(&pool, connection_id).await;
                let Ok(controls) = permissions(&pool, room, user).await else { break; };
                let latest = serde_json::to_value(&controls).unwrap();
                if latest != last_permissions {
                    if socket.send(Message::Text(json!({"type":"permissions","data":controls}).to_string().into())).await.is_err() { break; }
                    last_permissions = latest;
                }
            },
        }
    }
    hub.leave(channel, user, connection_id);
    crate::attendance::close(&pool, connection_id, exit).await;
    let _ = socket.send(close).await;
}

/// Cierre por sesión revocada (ver `auth::session::SESSION_REVOKED_CLOSE`).
fn revoked_close() -> Message {
    Message::Close(Some(CloseFrame {
        code: session::SESSION_REVOKED_CLOSE,
        reason: "session_revoked".into(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::{SinkExt, StreamExt};
    use sqlx::postgres::PgPoolOptions;
    use tokio_tungstenite::{
        MaybeTlsStream, WebSocketStream, connect_async, tungstenite::Message as ClientMessage,
    };

    async fn next_json(ws: &mut WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>) -> Value {
        loop {
            let message = tokio::time::timeout(Duration::from_secs(2), ws.next())
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            if let ClientMessage::Text(text) = message {
                let value: Value = serde_json::from_str(&text).unwrap();
                if value["type"] == "participant_permissions" {
                    assert!(value["user_id"].is_string());
                    assert!(value["data"]["microphone_allowed"].is_boolean());
                    assert!(value["data"]["camera_allowed"].is_boolean());
                    continue;
                }
                return value;
            }
        }
    }

    #[test]
    fn moderation_payloads_are_strict_and_control_budget_is_bounded() {
        let target = Uuid::new_v4();
        for value in [
            json!({"action":"kick","target":target,"role":"ADMIN"}),
            json!({"action":"camera","target":target,"allowed":"true"}),
            json!({"action":"grant_admin","target":target}),
        ] {
            assert!(serde_json::from_value::<ModerationRequest>(value).is_err());
        }
        assert!(
            serde_json::from_value::<ModerationRequest>(
                json!({"action":"microphone","target":target,"allowed":false})
            )
            .is_ok()
        );
        let hub = RoomHub::default();
        let room = Uuid::new_v4();
        let (tx, _) = mpsc::channel(64);
        hub.join(room, room, target, tx).unwrap();
        for _ in 0..10 {
            assert!(hub.allow_control(room, target));
        }
        for _ in 0..300 {
            assert!(!hub.allow_control(room, target));
        }
        assert!(!hub.allow_control(Uuid::new_v4(), target));
    }

    #[test]
    fn eviction_removes_identity_and_notifies_peers_immediately() {
        let hub = RoomHub::default();
        let room = Uuid::new_v4();
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let (ta, mut ra) = mpsc::channel(8);
        hub.join(room, room, a, ta).unwrap();
        let (tb, mut rb) = mpsc::channel(8);
        let (connection, _) = hub.join(room, room, b, tb).unwrap();
        let _ = ra.try_recv();
        hub.evict(room, b);
        assert!(!hub.current(room, b, connection));
        assert!(matches!(rb.try_recv(), Ok(HubEvent::Kicked)));
        let Ok(HubEvent::Text(left)) = ra.try_recv() else {
            panic!("missing departure");
        };
        assert_eq!(
            serde_json::from_str::<Value>(&left).unwrap()["user_id"],
            b.to_string()
        );
        // A full departure queue closes only the affected room, not other rooms.
        let overloaded = RoomHub::default();
        let (ta, _ra) = mpsc::channel(1);
        let (a_connection, _) = overloaded.join(room, room, a, ta).unwrap();
        let (tb, _rb) = mpsc::channel(1);
        overloaded.join(room, room, b, tb).unwrap(); // Fills a's only slot.
        let other_room = Uuid::new_v4();
        let (tc, _rc) = mpsc::channel(1);
        let (c_connection, _) = overloaded.join(other_room, other_room, a, tc).unwrap();
        overloaded.evict(room, b);
        assert!(!overloaded.current(room, a, a_connection));
        assert!(overloaded.users(room).is_empty());
        assert!(overloaded.current(other_room, a, c_connection));
    }

    #[test]
    fn room_limits_participants_and_disconnects_replaced_connection() {
        let hub = RoomHub::default();
        let room = Uuid::new_v4();
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let c = Uuid::new_v4();
        let d = Uuid::new_v4();
        let (tx_a, mut rx_a) = mpsc::channel(4);
        let (first, peers) = hub.join(room, room, a, tx_a).unwrap();
        let app_session = hub.live_join(a).unwrap();
        assert_eq!(hub.presence(a), "in_call");
        assert!(peers.is_empty());
        let (tx_b, _) = mpsc::channel(4);
        let (second, peers) = hub.join(room, room, b, tx_b).unwrap();
        assert_eq!(peers, vec![a]);
        assert!(matches!(rx_a.try_recv(), Ok(HubEvent::Text(_))));
        let (tx_c, _) = mpsc::channel(4);
        let (third, peers) = hub.join(room, room, c, tx_c).unwrap();
        assert_eq!(peers.len(), 2);
        assert!(peers.contains(&a) && peers.contains(&b));
        let (tx_d, _) = mpsc::channel(4);
        assert!(hub.join(room, room, d, tx_d).is_err());
        let (replacement, _) = mpsc::channel(4);
        let (current, _) = hub.join(room, room, a, replacement).unwrap();
        assert!(!hub.current(room, a, first));
        assert!(hub.current(room, a, current));
        hub.leave(room, a, first);
        assert!(hub.current(room, a, current));
        hub.leave(room, b, second);
        assert!(!hub.current(room, b, second));
        hub.leave(room, c, third);
        hub.leave(room, a, current);
        assert_eq!(hub.presence(a), "available");
        hub.live_leave(a, app_session);
        assert_eq!(hub.presence(a), "offline");
    }

    #[tokio::test]
    #[ignore = "Requires a disposable database in IRONLINK_TEST_DATABASE_URL"]
    async fn isolated_membership_ticket_replay_and_latency() {
        let url =
            std::env::var("IRONLINK_TEST_DATABASE_URL").expect("disposable database required");
        let pool = PgPoolOptions::new()
            .max_connections(5)
            .connect(&url)
            .await
            .unwrap();
        for file in [
            include_str!("../../migrations/001_sprint1_complete.sql"),
            include_str!("../../migrations/002_sprint2_fixes.sql"),
            include_str!("../../migrations/003_sprint3_rtc.sql"),
            include_str!("../../migrations/004_direct_messages.sql"),
            include_str!("../../migrations/005_rtc_moderation.sql"),
            include_str!("../../migrations/006_live_updates.sql"),
            include_str!("../../migrations/007_calendar_index.sql"),
            include_str!("../../migrations/008_attendance.sql"),
            include_str!("../../migrations/009_notifications.sql"),
            include_str!("../../migrations/010_breakout_rooms.sql"),
            include_str!("../../migrations/011_whiteboard.sql"),
            include_str!("../../migrations/012_security_fixes.sql"),
            include_str!("../../migrations/013_orphan_subgroup_members.sql"),
            include_str!("../../migrations/014_session_cutoff.sql"),
            include_str!("../../migrations/015_meeting_scheduling.sql"),
            include_str!("../../migrations/016_friendships.sql"),
            include_str!("../../migrations/017_calendar_details.sql"),
            include_str!("../../migrations/018_social_privacy.sql"),
            include_str!("../../migrations/019_session_version.sql"),
            include_str!("../../migrations/020_ticket_session.sql"),
        ] {
            sqlx::raw_sql(sqlx::AssertSqlSafe(file))
                .execute(&pool)
                .await
                .unwrap();
        }
        let owner = Uuid::new_v4();
        let member = Uuid::new_v4();
        let third_user = Uuid::new_v4();
        let fourth_user = Uuid::new_v4();
        let outsider = Uuid::new_v4();
        let node = Uuid::new_v4();
        let room = Uuid::new_v4();
        for user in [owner, member, third_user, fourth_user, outsider] {
            sqlx::query("INSERT INTO users (id, name, email, password, telefono, estado) VALUES ($1, 'RTC Test', $2, 'test-only', $3, 'ACTIVE')")
                .bind(user).bind(format!("{user}@example.invalid")).bind(user.to_string())
                .execute(&pool).await.unwrap();
        }
        sqlx::query("INSERT INTO nodos (id, nombre, token_acceso, creador_id) VALUES ($1, 'RTC Test', $2, $3)")
            .bind(node).bind(node.to_string()[..32].to_string()).bind(owner).execute(&pool).await.unwrap();
        for user in [owner, member, third_user, fourth_user] {
            sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id) VALUES ($1, $2)")
                .bind(node)
                .bind(user)
                .execute(&pool)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO reuniones (id, nodo_id, titulo, enlace, fecha_inicio, creado_por) VALUES ($1, $2, 'RTC Test', '', NOW(), $3)")
            .bind(room).bind(node).bind(owner).execute(&pool).await.unwrap();
        let state = AppState {
            pool: pool.clone(),
            config: Arc::new(crate::config::AppConfig {
                jwt_secret: "test-only".into(),
                smtp_username: String::new(),
                smtp_password: String::new(),
                smtp_from: "test@example.invalid".into(),
                app_base_url: "http://localhost".into(),
                app_public_url: None,
                server_host: "127.0.0.1".into(),
                server_port: 0,
            }),
            mailer: lettre::AsyncSmtpTransport::<lettre::Tokio1Executor>::builder_dangerous(
                "localhost",
            )
            .build(),
        };
        let auth = |user_id| AuthUser {
            user_id,
            role: "MEMBER".into(),
            session_version: 0,
        };
        assert_eq!(
            issue_ticket(
                State(state.clone()),
                Extension(auth(member)),
                Path((node, room)),
                Query(TicketTarget { sala_id: None })
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            start_meeting(
                State(state.clone()),
                Extension(auth(member)),
                Extension(Arc::new(RoomHub::default())),
                Path((node, room))
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            start_meeting(
                State(state.clone()),
                Extension(auth(owner)),
                Extension(Arc::new(RoomHub::default())),
                Path((node, room))
            )
            .await
            .0,
            StatusCode::OK
        );
        assert_eq!(
            issue_ticket(
                State(state.clone()),
                Extension(auth(outsider)),
                Path((node, room)),
                Query(TicketTarget { sala_id: None })
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        use crate::chat::direct::{SendDirect, history, inbox, send};
        assert_eq!(
            send(
                State(state.clone()),
                Extension(auth(outsider)),
                Path((node, member)),
                Json(SendDirect {
                    content: Some("No autorizado".into()),
                    reunion_id: None
                })
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            send(
                State(state.clone()),
                Extension(auth(owner)),
                Path((node, member)),
                Json(SendDirect {
                    content: Some("Hola en privado".into()),
                    reunion_id: None
                })
            )
            .await
            .0,
            StatusCode::CREATED
        );
        assert_eq!(
            send(
                State(state.clone()),
                Extension(auth(owner)),
                Path((node, member)),
                Json(SendDirect {
                    content: None,
                    reunion_id: Some(room)
                })
            )
            .await
            .0,
            StatusCode::CREATED
        );
        let (_, Json(dm_history)) = history(
            State(state.clone()),
            Extension(auth(member)),
            Path((node, owner)),
        )
        .await;
        assert_eq!(dm_history["messages"].as_array().unwrap().len(), 2);
        assert_eq!(dm_history["messages"][1]["kind"], "call_invite");
        let (_, Json(dm_inbox)) =
            inbox(State(state.clone()), Extension(auth(member)), Path(node)).await;
        assert_eq!(dm_inbox["messages"].as_array().unwrap().len(), 2);
        assert!(dm_inbox["messages"][0]["read_at"].is_string());
        let (_, Json(body)) = issue_ticket(
            State(state.clone()),
            Extension(auth(member)),
            Path((node, room)),
            Query(TicketTarget { sala_id: None }),
        )
        .await;
        let ticket = Uuid::parse_str(body["ticket"].as_str().unwrap()).unwrap();
        assert_eq!(
            consume_ticket(&pool, ticket).await.unwrap(),
            Some((room, member, None, 0))
        );
        assert_eq!(
            consume_ticket(&pool, ticket).await.unwrap(),
            None,
            "ticket must be single-use"
        );

        let (_, Json(body)) = issue_ticket(
            State(state.clone()),
            Extension(auth(member)),
            Path((node, room)),
            Query(TicketTarget { sala_id: None }),
        )
        .await;
        let ticket = Uuid::parse_str(body["ticket"].as_str().unwrap()).unwrap();
        sqlx::query(
            "UPDATE rtc_tickets SET expires_at = NOW() - INTERVAL '1 second' WHERE id = $1",
        )
        .bind(ticket)
        .execute(&pool)
        .await
        .unwrap();
        assert_eq!(consume_ticket(&pool, ticket).await.unwrap(), None);
        sqlx::query("INSERT INTO nodo_baneos (nodo_id, user_id) VALUES ($1, $2)")
            .bind(node)
            .bind(member)
            .execute(&pool)
            .await
            .unwrap();
        assert_eq!(
            issue_ticket(
                State(state.clone()),
                Extension(auth(member)),
                Path((node, room)),
                Query(TicketTarget { sala_id: None })
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        assert!(!member_allowed(&pool, room, member).await.unwrap());
        sqlx::query("DELETE FROM nodo_baneos WHERE nodo_id = $1 AND user_id = $2")
            .bind(node)
            .bind(member)
            .execute(&pool)
            .await
            .unwrap();

        let mut timings = Vec::with_capacity(50);
        for _ in 0..50 {
            let start = std::time::Instant::now();
            let (_, Json(body)) = issue_ticket(
                State(state.clone()),
                Extension(auth(member)),
                Path((node, room)),
                Query(TicketTarget { sala_id: None }),
            )
            .await;
            let ticket = Uuid::parse_str(body["ticket"].as_str().unwrap()).unwrap();
            assert_eq!(
                consume_ticket(&pool, ticket).await.unwrap(),
                Some((room, member, None, 0))
            );
            timings.push(start.elapsed().as_micros());
        }
        timings.sort_unstable();
        eprintln!(
            "RTC localhost ticket+consume, 50 samples: median={}us p95={}us",
            timings[24], timings[47]
        );

        // Prueba HTTP/WebSocket real: conexión, pase de un solo uso y relay.
        let hub = Arc::new(RoomHub::default());
        let app = axum::Router::new()
            .route("/rtc/ws", axum::routing::get(websocket))
            .layer(Extension(hub.clone()))
            .with_state(state.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let (_, Json(body)) = issue_ticket(
            State(state.clone()),
            Extension(auth(owner)),
            Path((node, room)),
            Query(TicketTarget { sala_id: None }),
        )
        .await;
        let owner_ticket = body["ticket"].as_str().unwrap();
        let (mut owner_ws, _) =
            connect_async(format!("ws://{address}/rtc/ws?ticket={owner_ticket}"))
                .await
                .unwrap();
        let welcome = next_json(&mut owner_ws).await;
        assert_eq!(welcome["type"], "room_state");
        assert_eq!(
            welcome["capabilities"],
            json!(([PARTICIPATION_CAPABILITIES.as_slice(), &["moderation"]].concat()))
        );
        assert!(matches!(
            connect_async(format!("ws://{address}/rtc/ws?ticket={owner_ticket}")).await,
            Err(tokio_tungstenite::tungstenite::Error::Http(response)) if response.status() == 401
        ));
        let (_, Json(body)) = issue_ticket(
            State(state.clone()),
            Extension(auth(member)),
            Path((node, room)),
            Query(TicketTarget { sala_id: None }),
        )
        .await;
        let member_ticket = body["ticket"].as_str().unwrap();
        let (mut member_ws, _) =
            connect_async(format!("ws://{address}/rtc/ws?ticket={member_ticket}"))
                .await
                .unwrap();
        assert_eq!(
            next_json(&mut member_ws).await["peers"][0],
            owner.to_string()
        );
        assert_eq!(next_json(&mut owner_ws).await["type"], "peer_joined");
        let (_, Json(body)) = issue_ticket(
            State(state.clone()),
            Extension(auth(third_user)),
            Path((node, room)),
            Query(TicketTarget { sala_id: None }),
        )
        .await;
        let third_ticket = body["ticket"].as_str().unwrap();
        let (mut third_ws, _) =
            connect_async(format!("ws://{address}/rtc/ws?ticket={third_ticket}"))
                .await
                .unwrap();
        assert_eq!(
            next_json(&mut third_ws).await["peers"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert_eq!(next_json(&mut owner_ws).await["type"], "peer_joined");
        assert_eq!(next_json(&mut member_ws).await["type"], "peer_joined");
        for recipient in [owner, member] {
            let signal = json!({
                "version": 1, "event_id": Uuid::new_v4(), "recipient": recipient,
                "signal": {"type": "offer", "payload": {"sdp": "v=0\r\n"}}
            });
            third_ws
                .send(ClientMessage::Text(signal.to_string().into()))
                .await
                .unwrap();
            let target = if recipient == owner {
                &mut owner_ws
            } else {
                &mut member_ws
            };
            assert_eq!(
                next_json(target).await["data"]["sender"],
                third_user.to_string()
            );
        }
        let (_, Json(body)) = issue_ticket(
            State(state.clone()),
            Extension(auth(fourth_user)),
            Path((node, room)),
            Query(TicketTarget { sala_id: None }),
        )
        .await;
        let fourth_ticket = body["ticket"].as_str().unwrap();
        let (mut fourth_ws, _) =
            connect_async(format!("ws://{address}/rtc/ws?ticket={fourth_ticket}"))
                .await
                .unwrap();
        assert_eq!(next_json(&mut fourth_ws).await["code"], "room_full");
        let _ = fourth_ws.close(None).await;

        // Estados/reacciones de un integrante se retransmiten a ambos pares,
        // conservando la identidad autenticada y los mismos controles de acceso.
        for peer_signal in [
            json!({"type":"hand_state","payload":{"raised":true}}),
            json!({"type":"hand_state","payload":{"raised":false}}),
            json!({"type":"microphone_state","payload":{"enabled":false}}),
            json!({"type":"microphone_state","payload":{"enabled":true}}),
            json!({"type":"screen_state","payload":{"enabled":true}}),
            json!({"type":"screen_state","payload":{"enabled":false}}),
            json!({"type":"reaction","payload":{"emoji":"👏"}}),
        ] {
            for recipient in [owner, member] {
                let event_id = Uuid::new_v4();
                let signal = json!({"version":1,"event_id":event_id,"recipient":recipient,"signal":peer_signal});
                third_ws
                    .send(ClientMessage::Text(signal.to_string().into()))
                    .await
                    .unwrap();
                let target = if recipient == owner {
                    &mut owner_ws
                } else {
                    &mut member_ws
                };
                let received = next_json(target).await;
                assert_eq!(received["data"]["sender"], third_user.to_string());
                assert_eq!(received["data"]["event_id"], event_id.to_string());
                assert_eq!(received["data"]["signal"], peer_signal);
            }
        }

        let mut signal_timings = Vec::with_capacity(30);
        for _ in 0..30 {
            let signal = json!({
                "version": 1, "event_id": Uuid::new_v4(), "recipient": owner,
                "signal": {"type": "offer", "payload": {"sdp": "v=0\r\n".repeat(200)}}
            });
            let start = std::time::Instant::now();
            member_ws
                .send(ClientMessage::Text(signal.to_string().into()))
                .await
                .unwrap();
            let received = next_json(&mut owner_ws).await;
            assert_eq!(received["type"], "signal");
            assert_eq!(received["data"]["sender"], member.to_string());
            signal_timings.push(start.elapsed().as_micros());
        }
        signal_timings.sort_unstable();
        eprintln!(
            "RTC localhost WS signal 1.2KiB, 30 samples: median={}us p95={}us",
            signal_timings[14], signal_timings[28]
        );

        let control = |actor, request| {
            moderate(
                State(state.clone()),
                Extension(auth(actor)),
                Extension(hub.clone()),
                Path((node, room)),
                Json(request),
            )
        };
        assert_eq!(
            control(member, ModerationRequest::MuteAll).await.0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            control(
                owner,
                ModerationRequest::Microphone {
                    target: owner,
                    allowed: false
                }
            )
            .await
            .0,
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            control(owner, ModerationRequest::MuteAll).await.0,
            StatusCode::OK
        );
        assert_eq!(
            next_json(&mut member_ws).await["data"]["microphone_allowed"],
            false
        );
        assert_eq!(
            next_json(&mut third_ws).await["data"]["microphone_allowed"],
            false
        );
        assert!(
            !permissions(&pool, room, member)
                .await
                .unwrap()
                .microphone_allowed
        );
        assert!(
            permissions(&pool, room, owner)
                .await
                .unwrap()
                .microphone_allowed
        );
        // A restricted client cannot announce that it has enabled audio.
        member_ws.send(ClientMessage::Text(json!({"version":1,"event_id":Uuid::new_v4(),"recipient":owner,"signal":{"type":"microphone_state","payload":{"enabled":true}}}).to_string().into())).await.unwrap();
        assert_eq!(next_json(&mut member_ws).await["type"], "permissions");
        assert_eq!(
            control(
                owner,
                ModerationRequest::Microphone {
                    target: member,
                    allowed: true
                }
            )
            .await
            .0,
            StatusCode::OK
        );
        assert_eq!(
            next_json(&mut member_ws).await["data"]["microphone_allowed"],
            true
        );
        assert_eq!(
            control(
                owner,
                ModerationRequest::Camera {
                    target: member,
                    allowed: false
                }
            )
            .await
            .0,
            StatusCode::OK
        );
        assert_eq!(
            next_json(&mut member_ws).await["data"]["camera_allowed"],
            false
        );
        member_ws.send(ClientMessage::Text(json!({"version":1,"event_id":Uuid::new_v4(),"recipient":owner,"signal":{"type":"screen_state","payload":{"enabled":true}}}).to_string().into())).await.unwrap();
        assert_eq!(next_json(&mut member_ws).await["type"], "permissions");
        assert_eq!(
            control(
                owner,
                ModerationRequest::Camera {
                    target: member,
                    allowed: true
                }
            )
            .await
            .0,
            StatusCode::OK
        );
        assert_eq!(
            next_json(&mut member_ws).await["data"]["camera_allowed"],
            true
        );
        sqlx::query(
            "UPDATE nodo_miembros SET rol = 'MODERATOR' WHERE nodo_id = $1 AND user_id = $2",
        )
        .bind(node)
        .bind(member)
        .execute(&pool)
        .await
        .unwrap();
        assert_eq!(
            control(owner, ModerationRequest::Kick { target: member })
                .await
                .0,
            StatusCode::FORBIDDEN
        );
        sqlx::query("UPDATE nodo_miembros SET rol = 'MEMBER' WHERE nodo_id = $1 AND user_id = $2")
            .bind(node)
            .bind(member)
            .execute(&pool)
            .await
            .unwrap();
        let (_, Json(pending)) = issue_ticket(
            State(state.clone()),
            Extension(auth(third_user)),
            Path((node, room)),
            Query(TicketTarget { sala_id: None }),
        )
        .await;
        let pending_ticket = Uuid::parse_str(pending["ticket"].as_str().unwrap()).unwrap();
        assert_eq!(
            control(owner, ModerationRequest::Kick { target: third_user })
                .await
                .0,
            StatusCode::OK
        );
        assert_eq!(next_json(&mut owner_ws).await["type"], "peer_left");
        assert_eq!(next_json(&mut member_ws).await["type"], "peer_left");
        assert_eq!(next_json(&mut third_ws).await["type"], "removed");
        assert_eq!(consume_ticket(&pool, pending_ticket).await.unwrap(), None);
        assert_eq!(
            issue_ticket(
                State(state.clone()),
                Extension(auth(third_user)),
                Path((node, room)),
                Query(TicketTarget { sala_id: None })
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        // A room kick leaves the node membership unchanged.
        assert!(
            sqlx::query_scalar::<_, bool>(
                "SELECT EXISTS(SELECT 1 FROM nodo_miembros WHERE nodo_id=$1 AND user_id=$2)"
            )
            .bind(node)
            .bind(third_user)
            .fetch_one(&pool)
            .await
            .unwrap()
        );

        // Una expulsión/baneo debe invalidar también la conexión ya abierta.
        sqlx::query("INSERT INTO nodo_baneos (nodo_id, user_id) VALUES ($1, $2)")
            .bind(node)
            .bind(member)
            .execute(&pool)
            .await
            .unwrap();
        let signal = json!({
            "version": 1, "event_id": Uuid::new_v4(), "recipient": owner,
            "signal": {"type": "hand_state", "payload": {"raised": true}}
        });
        member_ws
            .send(ClientMessage::Text(signal.to_string().into()))
            .await
            .unwrap();
        assert_eq!(next_json(&mut owner_ws).await["type"], "peer_left");

        // Cerrar sesión (aquí, cambiar la contraseña) corta la señalización
        // abierta con `session_renew` y cierre 4401, y los pases previos ya no
        // se canjean.
        let (_, Json(body)) = issue_ticket(
            State(state.clone()),
            Extension(auth(owner)),
            Path((node, room)),
            Query(TicketTarget { sala_id: None }),
        )
        .await;
        let stale = Uuid::parse_str(body["ticket"].as_str().unwrap()).unwrap();
        crate::auth::session::update_password(&pool, owner, "test-only-2")
            .await
            .unwrap();
        while next_json(&mut owner_ws).await["type"] != "session_renew" {}
        let close = loop {
            match tokio::time::timeout(Duration::from_secs(2), owner_ws.next())
                .await
                .unwrap()
            {
                Some(Ok(ClientMessage::Close(frame))) => break frame.map(|f| u16::from(f.code)),
                Some(Ok(_)) => continue,
                other => panic!("se esperaba un cierre: {other:?}"),
            }
        };
        assert_eq!(close, Some(session::SESSION_REVOKED_CLOSE));
        assert_eq!(consume_ticket(&pool, stale).await.unwrap(), None);
        // El JWT anterior (versión 0) ya no obtiene pases.
        assert_eq!(
            issue_ticket(
                State(state.clone()),
                Extension(auth(owner)),
                Path((node, room)),
                Query(TicketTarget { sala_id: None }),
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        // El resto de la prueba sigue con el organizador y JWT de versión 0.
        sqlx::query("UPDATE users SET version_sesion = 0 WHERE id = $1")
            .bind(owner)
            .execute(&pool)
            .await
            .unwrap();

        let _ = member_ws.close(None).await;
        let _ = third_ws.close(None).await;
        server.abort();

        let hub = Arc::new(RoomHub::default());
        assert_eq!(
            end_meeting(
                State(state.clone()),
                Extension(auth(owner)),
                Extension(hub),
                Path((node, room))
            )
            .await
            .0,
            StatusCode::OK
        );
        // IRL-SEC-US-01: cada conexión admitida dejó su entrada y, al finalizar
        // la reunión, ninguna sesión queda abierta.
        let (sessions, people, open, kicked): (i64, i64, i64, i64) = sqlx::query_as(
            "SELECT COUNT(*), COUNT(DISTINCT user_id), COUNT(*) FILTER (WHERE left_at IS NULL),
                    COUNT(*) FILTER (WHERE salida = 'expulsado')
             FROM reunion_asistencia WHERE reunion_id = $1",
        )
        .bind(room)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!(
            sessions >= 3 && people >= 3,
            "{sessions} sesiones, {people} personas"
        );
        assert_eq!(open, 0);
        assert!(kicked >= 1);
        assert_eq!(
            issue_ticket(
                State(state),
                Extension(auth(member)),
                Path((node, room)),
                Query(TicketTarget { sala_id: None })
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        assert!(!member_allowed(&pool, room, member).await.unwrap());
        sqlx::query("DELETE FROM users WHERE id = ANY($1)")
            .bind(vec![owner, member, third_user, fourth_user, outsider])
            .execute(&pool)
            .await
            .unwrap();
        pool.close().await;
    }

    /// IRL-RTC-US-07: las salas aíslan la señalización, siguen la asignación
    /// del moderador y la moderación sigue alcanzando a toda la reunión.
    #[tokio::test]
    #[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
    async fn breakout_rooms_isolate_media_and_follow_assignment() {
        let url =
            std::env::var("IRONLINK_TEST_DATABASE_URL").expect("disposable database required");
        let pool = PgPoolOptions::new()
            .max_connections(5)
            .connect(&url)
            .await
            .unwrap();
        for file in [
            include_str!("../../migrations/001_sprint1_complete.sql"),
            include_str!("../../migrations/002_sprint2_fixes.sql"),
            include_str!("../../migrations/003_sprint3_rtc.sql"),
            include_str!("../../migrations/004_direct_messages.sql"),
            include_str!("../../migrations/005_rtc_moderation.sql"),
            include_str!("../../migrations/006_live_updates.sql"),
            include_str!("../../migrations/007_calendar_index.sql"),
            include_str!("../../migrations/008_attendance.sql"),
            include_str!("../../migrations/009_notifications.sql"),
            include_str!("../../migrations/010_breakout_rooms.sql"),
            include_str!("../../migrations/011_whiteboard.sql"),
            include_str!("../../migrations/012_security_fixes.sql"),
            include_str!("../../migrations/013_orphan_subgroup_members.sql"),
            include_str!("../../migrations/014_session_cutoff.sql"),
            include_str!("../../migrations/015_meeting_scheduling.sql"),
            include_str!("../../migrations/016_friendships.sql"),
            include_str!("../../migrations/017_calendar_details.sql"),
            include_str!("../../migrations/018_social_privacy.sql"),
            include_str!("../../migrations/019_session_version.sql"),
            include_str!("../../migrations/020_ticket_session.sql"),
        ] {
            sqlx::raw_sql(sqlx::AssertSqlSafe(file))
                .execute(&pool)
                .await
                .unwrap();
        }
        let (owner, ana, beto, carla) = (
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
        );
        let (node, room) = (Uuid::new_v4(), Uuid::new_v4());
        for (user, name) in [
            (owner, "Owner"),
            (ana, "Ana"),
            (beto, "Beto"),
            (carla, "Carla"),
        ] {
            sqlx::query("INSERT INTO users (id, name, email, password, telefono, estado) VALUES ($1, $2, $3, 'test-only', $4, 'ACTIVE')")
                .bind(user).bind(name).bind(format!("{user}@example.invalid")).bind(user.to_string())
                .execute(&pool).await.unwrap();
        }
        sqlx::query(
            "INSERT INTO nodos (id, nombre, token_acceso, creador_id) VALUES ($1, 'Salas', $2, $3)",
        )
        .bind(node)
        .bind(node.to_string()[..32].to_string())
        .bind(owner)
        .execute(&pool)
        .await
        .unwrap();
        for user in [owner, ana, beto, carla] {
            sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id) VALUES ($1, $2)")
                .bind(node)
                .bind(user)
                .execute(&pool)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO reuniones (id, nodo_id, titulo, enlace, fecha_inicio, creado_por) VALUES ($1, $2, 'Salas', '', NOW(), $3)")
            .bind(room).bind(node).bind(owner).execute(&pool).await.unwrap();
        let state = AppState {
            pool: pool.clone(),
            config: Arc::new(crate::config::AppConfig {
                jwt_secret: "test-only".into(),
                smtp_username: String::new(),
                smtp_password: String::new(),
                smtp_from: "test@example.invalid".into(),
                app_base_url: "http://localhost".into(),
                app_public_url: None,
                server_host: "127.0.0.1".into(),
                server_port: 0,
            }),
            mailer: lettre::AsyncSmtpTransport::<lettre::Tokio1Executor>::builder_dangerous(
                "localhost",
            )
            .build(),
        };
        let auth = |user_id| AuthUser {
            user_id,
            role: "MEMBER".into(),
            session_version: 0,
        };
        let hub = Arc::new(RoomHub::default());
        assert_eq!(
            start_meeting(
                State(state.clone()),
                Extension(auth(owner)),
                Extension(hub.clone()),
                Path((node, room))
            )
            .await
            .0,
            StatusCode::OK
        );
        let app = axum::Router::new()
            .route("/rtc/ws", axum::routing::get(websocket))
            .layer(Extension(hub.clone()))
            .with_state(state.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        let ticket = |user: Uuid, sala: Option<Uuid>| {
            let state = state.clone();
            async move {
                issue_ticket(
                    State(state),
                    Extension(auth(user)),
                    Path((node, room)),
                    Query(TicketTarget { sala_id: sala }),
                )
                .await
            }
        };
        let connect = |user: Uuid, sala: Option<Uuid>| {
            let ticket = ticket(user, sala);
            async move {
                let (status, Json(body)) = ticket.await;
                assert_eq!(status, StatusCode::OK, "{body}");
                let id = body["ticket"].as_str().unwrap().to_string();
                connect_async(format!("ws://{address}/rtc/ws?ticket={id}"))
                    .await
                    .unwrap()
                    .0
            }
        };
        async fn until(
            ws: &mut WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>,
            kind: &str,
        ) -> Value {
            loop {
                let value = next_json(ws).await;
                if value["type"] == kind {
                    return value;
                }
            }
        }

        let mut owner_ws = connect(owner, None).await;
        until(&mut owner_ws, "room_state").await;
        let mut ana_main = connect(ana, None).await;
        until(&mut ana_main, "room_state").await;
        let mut beto_main = connect(beto, None).await;
        until(&mut beto_main, "room_state").await;

        // Asignación: Ana a «Diseño», Beto a «Backend»; Carla sin sala.
        let request: crate::breakout::SalasRequest = serde_json::from_value(json!({"salas": [
            {"nombre": "Diseño", "miembros": [ana]},
            {"nombre": "Backend", "miembros": [beto]},
        ]}))
        .unwrap();
        let (status, Json(created)) = crate::breakout::replace(
            State(state.clone()),
            Extension(auth(ana)),
            Extension(hub.clone()),
            Path((node, room)),
            Json(serde_json::from_value(json!({"salas":[{"nombre":"X","miembros":[]}]})).unwrap()),
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN, "solo moderadores: {created}");
        let (status, Json(created)) = crate::breakout::replace(
            State(state.clone()),
            Extension(auth(owner)),
            Extension(hub.clone()),
            Path((node, room)),
            Json(request),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{created}");
        let sala_a: Uuid = serde_json::from_value(created["salas"][0]["id"].clone()).unwrap();
        let sala_b: Uuid = serde_json::from_value(created["salas"][1]["id"].clone()).unwrap();
        assert_eq!(
            until(&mut ana_main, "breakout").await["sala"]["nombre"],
            "Diseño"
        );
        assert_eq!(
            until(&mut beto_main, "breakout").await["sala"]["nombre"],
            "Backend"
        );
        assert_eq!(until(&mut owner_ws, "breakout").await["sala"], Value::Null);

        // Solo se entra a la sala asignada; el moderador puede visitar cualquiera.
        assert_eq!(ticket(ana, Some(sala_b)).await.0, StatusCode::FORBIDDEN);
        assert_eq!(ticket(carla, Some(sala_a)).await.0, StatusCode::FORBIDDEN);

        let mut ana_sala = connect(ana, Some(sala_a)).await;
        let welcome = until(&mut ana_sala, "room_state").await;
        assert_eq!(welcome["sala_id"], json!(sala_a));
        assert_eq!(welcome["peers"], json!([]), "la sala no ve a la principal");
        // Al cambiar de canal, la principal se entera de su salida.
        assert_eq!(
            until(&mut owner_ws, "peer_left").await["user_id"],
            json!(ana)
        );

        let mut beto_sala = connect(beto, Some(sala_b)).await;
        until(&mut beto_sala, "room_state").await;
        let mut owner_visit = connect(owner, Some(sala_b)).await;
        let visit = until(&mut owner_visit, "room_state").await;
        assert_eq!(visit["peers"], json!([beto]));

        // La señalización no cruza salas.
        let signal = json!({"version":1,"event_id":Uuid::new_v4(),"recipient":ana,"signal":{"type":"hand_state","payload":{"raised":true}}});
        owner_visit
            .send(ClientMessage::Text(signal.to_string().into()))
            .await
            .unwrap();
        assert_eq!(
            until(&mut owner_visit, "error").await["code"],
            "recipient_unavailable"
        );

        // La moderación alcanza a quien está en otra sala.
        assert_eq!(
            moderate(
                State(state.clone()),
                Extension(auth(owner)),
                Extension(hub.clone()),
                Path((node, room)),
                Json(ModerationRequest::Kick { target: ana })
            )
            .await
            .0,
            StatusCode::OK
        );
        assert_eq!(until(&mut ana_sala, "removed").await["type"], "removed");

        // Cerrar las salas devuelve a todos a la principal y retira el acceso.
        let (status, _) = crate::breakout::close(
            State(state.clone()),
            Extension(auth(owner)),
            Extension(hub.clone()),
            Path((node, room)),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(until(&mut beto_sala, "breakout").await["sala"], Value::Null);
        assert_eq!(ticket(beto, Some(sala_b)).await.0, StatusCode::FORBIDDEN);
        assert!(
            !crate::breakout::allowed(&pool, room, sala_b, beto)
                .await
                .unwrap()
        );

        // La asistencia registró la sala de cada conexión.
        let in_rooms: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM reunion_asistencia WHERE reunion_id = $1 AND sala_id IS NOT NULL",
        )
        .bind(room)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!(in_rooms >= 3, "{in_rooms}");

        for mut ws in [
            owner_ws,
            ana_main,
            beto_main,
            beto_sala,
            owner_visit,
            ana_sala,
        ] {
            let _ = ws.close(None).await;
        }
        server.abort();
        sqlx::query("DELETE FROM users WHERE id = ANY($1)")
            .bind(vec![owner, ana, beto, carla])
            .execute(&pool)
            .await
            .unwrap();
        pool.close().await;
    }

    /// IRL-RTC-US-08: la pizarra se sincroniza en vivo por canal, respeta
    /// quién puede dibujar y se recupera desde la base de datos.
    #[tokio::test]
    #[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
    async fn whiteboard_syncs_per_channel_and_enforces_permissions() {
        use crate::whiteboard;
        let url =
            std::env::var("IRONLINK_TEST_DATABASE_URL").expect("disposable database required");
        let pool = PgPoolOptions::new()
            .max_connections(5)
            .connect(&url)
            .await
            .unwrap();
        for file in [
            include_str!("../../migrations/001_sprint1_complete.sql"),
            include_str!("../../migrations/002_sprint2_fixes.sql"),
            include_str!("../../migrations/003_sprint3_rtc.sql"),
            include_str!("../../migrations/004_direct_messages.sql"),
            include_str!("../../migrations/005_rtc_moderation.sql"),
            include_str!("../../migrations/006_live_updates.sql"),
            include_str!("../../migrations/007_calendar_index.sql"),
            include_str!("../../migrations/008_attendance.sql"),
            include_str!("../../migrations/009_notifications.sql"),
            include_str!("../../migrations/010_breakout_rooms.sql"),
            include_str!("../../migrations/011_whiteboard.sql"),
            include_str!("../../migrations/012_security_fixes.sql"),
            include_str!("../../migrations/013_orphan_subgroup_members.sql"),
            include_str!("../../migrations/014_session_cutoff.sql"),
            include_str!("../../migrations/015_meeting_scheduling.sql"),
            include_str!("../../migrations/016_friendships.sql"),
            include_str!("../../migrations/017_calendar_details.sql"),
            include_str!("../../migrations/018_social_privacy.sql"),
            include_str!("../../migrations/019_session_version.sql"),
            include_str!("../../migrations/020_ticket_session.sql"),
        ] {
            sqlx::raw_sql(sqlx::AssertSqlSafe(file))
                .execute(&pool)
                .await
                .unwrap();
        }
        let (owner, ana, beto) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
        let (node, room) = (Uuid::new_v4(), Uuid::new_v4());
        for user in [owner, ana, beto] {
            sqlx::query("INSERT INTO users (id, name, email, password, telefono, estado) VALUES ($1, 'Pizarra', $2, 'test-only', $3, 'ACTIVE')")
                .bind(user).bind(format!("{user}@example.invalid")).bind(user.to_string())
                .execute(&pool).await.unwrap();
        }
        sqlx::query("INSERT INTO nodos (id, nombre, token_acceso, creador_id) VALUES ($1, 'Pizarra', $2, $3)")
            .bind(node).bind(node.to_string()[..32].to_string()).bind(owner).execute(&pool).await.unwrap();
        for user in [owner, ana, beto] {
            sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id) VALUES ($1, $2)")
                .bind(node)
                .bind(user)
                .execute(&pool)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO reuniones (id, nodo_id, titulo, enlace, fecha_inicio, creado_por) VALUES ($1, $2, 'Pizarra', '', NOW(), $3)")
            .bind(room).bind(node).bind(owner).execute(&pool).await.unwrap();
        let state = AppState {
            pool: pool.clone(),
            config: Arc::new(crate::config::AppConfig {
                jwt_secret: "test-only".into(),
                smtp_username: String::new(),
                smtp_password: String::new(),
                smtp_from: "test@example.invalid".into(),
                app_base_url: "http://localhost".into(),
                app_public_url: None,
                server_host: "127.0.0.1".into(),
                server_port: 0,
            }),
            mailer: lettre::AsyncSmtpTransport::<lettre::Tokio1Executor>::builder_dangerous(
                "localhost",
            )
            .build(),
        };
        let auth = |user_id| AuthUser {
            user_id,
            role: "MEMBER".into(),
            session_version: 0,
        };
        let hub = Arc::new(RoomHub::default());
        assert_eq!(
            start_meeting(
                State(state.clone()),
                Extension(auth(owner)),
                Extension(hub.clone()),
                Path((node, room)),
            )
            .await
            .0,
            StatusCode::OK
        );
        let app = axum::Router::new()
            .route("/rtc/ws", axum::routing::get(websocket))
            .layer(Extension(hub.clone()))
            .with_state(state.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let connect = |user: Uuid, sala: Option<Uuid>| {
            let state = state.clone();
            async move {
                let (_, Json(body)) = issue_ticket(
                    State(state),
                    Extension(auth(user)),
                    Path((node, room)),
                    Query(TicketTarget { sala_id: sala }),
                )
                .await;
                let id = body["ticket"].as_str().unwrap().to_string();
                connect_async(format!("ws://{address}/rtc/ws?ticket={id}"))
                    .await
                    .unwrap()
                    .0
            }
        };
        async fn board(ws: &mut WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>) -> Value {
            loop {
                let value = next_json(ws).await;
                if value["type"] == "whiteboard" {
                    return value;
                }
            }
        }
        let draw = |user: Uuid, sala: Option<Uuid>| {
            let (state, hub) = (state.clone(), hub.clone());
            async move {
                let stroke: whiteboard::NewStroke = serde_json::from_value(json!({
                    "sala_id": sala, "puntos": [[0.1, 0.1], [0.5, 0.5]], "color": "#9184d9", "grosor": 4
                })).unwrap();
                whiteboard::add_stroke(
                    State(state),
                    Extension(auth(user)),
                    Extension(hub),
                    Path((node, room)),
                    Json(stroke),
                )
                .await
            }
        };
        let read = |user: Uuid, sala: Option<Uuid>| {
            let (state, hub) = (state.clone(), hub.clone());
            async move {
                whiteboard::get(
                    State(state),
                    Extension(auth(user)),
                    Extension(hub),
                    Path((node, room)),
                    Query(serde_json::from_value(json!({"sala_id": sala})).unwrap()),
                )
                .await
                .1
                .0
            }
        };

        let mut owner_ws = connect(owner, None).await;
        let mut ana_ws = connect(ana, None).await;
        // Esperar a que la sala admita ambas conexiones antes de dibujar: si no,
        // el primer trazo podía difundirse antes de que Ana estuviera registrada.
        until_room_state(&mut owner_ws).await;
        until_room_state(&mut ana_ws).await;

        // Por defecto solo dibuja quien modera, y el trazo llega en vivo.
        assert_eq!(draw(ana, None).await.0, StatusCode::FORBIDDEN);
        let (status, Json(created)) = draw(owner, None).await;
        assert_eq!(status, StatusCode::CREATED);
        let first = created["trazo"]["id"].clone();
        let live = board(&mut ana_ws).await;
        assert_eq!(
            (live["op"].clone(), live["trazo"]["id"].clone()),
            (json!("stroke"), first.clone())
        );
        // Cada evento lleva una secuencia; la carga completa informa la última.
        assert_eq!(live["seq"], 1);
        let canvas = read(ana, None).await;
        assert_eq!(canvas["seq"], 1);
        assert_eq!(canvas["trazos"].as_array().unwrap().len(), 1);
        assert_eq!(canvas["puede_dibujar"], false);

        // Permitir a todos: Ana dibuja; solo deshace lo suyo.
        let everyone: whiteboard::Permissions =
            serde_json::from_value(json!({"sala_id": null, "todos_dibujan": true})).unwrap();
        assert_eq!(
            whiteboard::set_permissions(
                State(state.clone()),
                Extension(auth(ana)),
                Extension(hub.clone()),
                Path((node, room)),
                Json(
                    serde_json::from_value(json!({"sala_id": null, "todos_dibujan": true}))
                        .unwrap()
                )
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            whiteboard::set_permissions(
                State(state.clone()),
                Extension(auth(owner)),
                Extension(hub.clone()),
                Path((node, room)),
                Json(everyone)
            )
            .await
            .0,
            StatusCode::OK
        );
        assert_eq!(board(&mut ana_ws).await["todos_dibujan"], true);
        let (status, Json(mine)) = draw(ana, None).await;
        assert_eq!(status, StatusCode::CREATED);
        let first_id: Uuid = serde_json::from_value(first).unwrap();
        let mine_id: Uuid = serde_json::from_value(mine["trazo"]["id"].clone()).unwrap();
        assert_eq!(
            whiteboard::delete_stroke(
                State(state.clone()),
                Extension(auth(ana)),
                Extension(hub.clone()),
                Path((node, room, first_id))
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            whiteboard::delete_stroke(
                State(state.clone()),
                Extension(auth(ana)),
                Extension(hub.clone()),
                Path((node, room, mine_id))
            )
            .await
            .0,
            StatusCode::OK
        );
        // Quien no está en la llamada no puede dibujar aunque se permita a todos.
        assert_eq!(draw(beto, None).await.0, StatusCode::TOO_MANY_REQUESTS);

        // Cada sala tiene su propia pizarra: lo de la principal no llega a la sala.
        let request: crate::breakout::SalasRequest =
            serde_json::from_value(json!({"salas":[{"nombre":"Dibujo","miembros":[ana]}]}))
                .unwrap();
        let (_, Json(created)) = crate::breakout::replace(
            State(state.clone()),
            Extension(auth(owner)),
            Extension(hub.clone()),
            Path((node, room)),
            Json(request),
        )
        .await;
        let sala: Uuid = serde_json::from_value(created["salas"][0]["id"].clone()).unwrap();
        let mut ana_sala = connect(ana, Some(sala)).await;
        until_room_state(&mut ana_sala).await;
        assert_eq!(draw(owner, None).await.0, StatusCode::CREATED);
        assert_eq!(read(ana, Some(sala)).await["trazos"], json!([]));
        assert_eq!(
            read(beto, Some(sala)).await["message"],
            "La pizarra no está disponible."
        );
        assert_eq!(draw(owner, Some(sala)).await.0, StatusCode::CREATED);
        assert_eq!(board(&mut ana_sala).await["op"], "stroke");

        // Limpiar: solo quien modera; el lienzo vacío se recupera así.
        let clear = |user: Uuid| {
            let (state, hub) = (state.clone(), hub.clone());
            async move {
                whiteboard::clear(
                    State(state),
                    Extension(auth(user)),
                    Extension(hub),
                    Path((node, room)),
                    Query(serde_json::from_value(json!({"sala_id": null})).unwrap()),
                )
                .await
                .0
            }
        };
        assert_eq!(clear(ana).await, StatusCode::FORBIDDEN);
        assert_eq!(clear(owner).await, StatusCode::OK);
        assert_eq!(read(owner, None).await["trazos"], json!([]));
        assert_eq!(
            read(owner, Some(sala)).await["trazos"]
                .as_array()
                .unwrap()
                .len(),
            1,
            "la sala conserva lo suyo"
        );

        for mut ws in [owner_ws, ana_ws, ana_sala] {
            let _ = ws.close(None).await;
        }
        server.abort();
        sqlx::query("DELETE FROM users WHERE id = ANY($1)")
            .bind(vec![owner, ana, beto])
            .execute(&pool)
            .await
            .unwrap();
        pool.close().await;
    }

    async fn until_room_state(
        ws: &mut WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>,
    ) -> Value {
        loop {
            let value = next_json(ws).await;
            if value["type"] == "room_state" {
                return value;
            }
        }
    }
}
