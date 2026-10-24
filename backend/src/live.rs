//! Authorized application-wide WebSocket updates, independent of RTC rooms.
use crate::{
    auth::{middleware::AuthUser, session, verification::AppState},
    rtc::server::RoomHub,
};
use axum::{
    Extension, Json,
    extract::{
        Query, State,
        ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade},
    },
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::PgPool;
use std::{sync::Arc, time::Duration};
use tokio::sync::broadcast;
use uuid::Uuid;

pub async fn issue_ticket(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
) -> (StatusCode, Json<Value>) {
    let id = Uuid::new_v4();
    // El pase lleva la versión de sesión del JWT: si entretanto se cerró la
    // sesión, no se emite, y si se cierra después, ya no se puede canjear.
    let result = sqlx::query("INSERT INTO live_tickets (id,user_id,expires_at,version_sesion) SELECT $1,id,NOW()+INTERVAL '60 seconds',$3 FROM users WHERE id=$2 AND estado='ACTIVE' AND version_sesion=$3").bind(id).bind(user.user_id).bind(user.session_version).execute(&state.pool).await;
    match result {
        Ok(result) if result.rows_affected() == 1 => (
            StatusCode::OK,
            Json(json!({"ticket":id,"expires_in_seconds":60})),
        ),
        Ok(_) => (StatusCode::FORBIDDEN, Json(json!({"code":"inactive_user"}))),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"code":"database_unavailable"})),
        ),
    }
}

/// Devuelve el usuario y la versión de sesión con la que se emitió el pase.
async fn consume(pool: &PgPool, ticket: Uuid) -> Result<Option<(Uuid, i32)>, sqlx::Error> {
    sqlx::query_as("DELETE FROM live_tickets t USING users u WHERE t.id=$1 AND t.expires_at>NOW() AND u.id=t.user_id AND u.estado='ACTIVE' AND u.version_sesion=t.version_sesion RETURNING t.user_id, t.version_sesion").bind(ticket).fetch_optional(pool).await
}

/// Authorization is repeated for every snapshot, including removals and bans.
async fn snapshot(pool: &PgPool, hub: &RoomHub, user: Uuid) -> Result<Option<Value>, sqlx::Error> {
    if !sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND estado='ACTIVE')",
    )
    .bind(user)
    .fetch_one(pool)
    .await?
    {
        return Ok(None);
    }
    let people = sqlx::query_as::<_, (Uuid, Option<String>)>(
        "SELECT DISTINCT u.id,u.status_text FROM users u WHERE u.estado='ACTIVE' AND (u.id=$1 OR EXISTS (
         SELECT 1 FROM nodo_miembros me JOIN nodos n ON n.id=me.nodo_id AND n.estado='active'
         JOIN nodo_miembros other ON other.nodo_id=n.id AND other.user_id=u.id
         WHERE me.user_id=$1 AND NOT EXISTS(SELECT 1 FROM nodo_baneos b WHERE b.nodo_id=n.id AND b.user_id IN ($1,u.id)))
         OR EXISTS (SELECT 1 FROM amistades f WHERE f.estado='aceptada'
         AND ((f.solicitante=$1 AND f.destinatario=u.id) OR (f.solicitante=u.id AND f.destinatario=$1))))
         ORDER BY u.id LIMIT 501"
    ).bind(user).fetch_all(pool).await?;
    let truncated = people.len() > 500;
    let mut presence = serde_json::Map::new();
    // Always include self, even if the authorized roster exceeds the limit.
    presence.insert(user.to_string(), json!(hub.presence(user)));
    for (id, manual) in people.into_iter().take(500) {
        let state = hub.presence(id);
        let busy = manual
            .as_deref()
            .is_some_and(|s| matches!(s.trim().to_lowercase().as_str(), "ocupado" | "🔴 ocupado"));
        presence.insert(
            id.to_string(),
            json!(if state == "available" && busy {
                "busy"
            } else {
                state
            }),
        );
    }
    let meetings = sqlx::query_as::<_, (Uuid, Uuid, String, Uuid, String, String)>(
        "SELECT r.id,r.nodo_id,r.titulo,r.creado_por,u.name,r.rtc_started_at::text FROM reuniones r
         JOIN nodos n ON n.id=r.nodo_id AND n.estado='active'
         JOIN nodo_miembros me ON me.nodo_id=n.id AND me.user_id=$1
         JOIN users u ON u.id=r.creado_por
         WHERE r.rtc_estado='active' AND r.rtc_started_at IS NOT NULL
         AND (NOT r.privada OR r.creado_por=$1 OR EXISTS(SELECT 1 FROM reunion_invitados i WHERE i.reunion_id=r.id AND i.user_id=$1))
         AND NOT EXISTS(SELECT 1 FROM nodo_baneos b WHERE b.nodo_id=n.id AND b.user_id=$1)
         AND NOT EXISTS(SELECT 1 FROM rtc_participant_controls c WHERE c.reunion_id=r.id AND c.user_id=$1 AND c.kicked)
         ORDER BY r.rtc_started_at DESC LIMIT 51"
    ).bind(user).fetch_all(pool).await?;
    let meetings_truncated = meetings.len() > 50;
    let meetings: Vec<Value> = meetings.into_iter().take(50).map(|(id,node_id,title,creator_id,creator_name,started_at)| json!({"id":id,"node_id":node_id,"title":title,"creator_id":creator_id,"creator_name":creator_name,"started_at":started_at})).collect();
    // IRL-NTF-US-03: el contador de no leídas viaja en la misma instantánea.
    let notifications = crate::notifications::live_summary(pool, user).await?;
    // Solicitudes de amistad pendientes recibidas, para el contador en vivo.
    let friend_requests = crate::amigos::pendientes_recibidas(pool, user).await?;
    // Mensajes de amistad sin leer: la app refresca la bandeja de Chats.
    let friend_unread = crate::amigos_chat::no_leidos(pool, user).await?;
    let (friends_accepted, friends_sent) = crate::amigos::resumen_relaciones(pool, user).await?;
    Ok(Some(
        json!({"type":"live_snapshot","user_id":user,"presence":presence,"meetings":meetings,
               "notifications":notifications,
               "friends":{"pending":friend_requests,"unread_messages":friend_unread,
                          "accepted":friends_accepted,"sent":friends_sent},
               "truncated":truncated || meetings_truncated}),
    ))
}

#[derive(Deserialize)]
pub struct TicketQuery {
    ticket: Uuid,
}

pub async fn websocket(
    ws: WebSocketUpgrade,
    Query(query): Query<TicketQuery>,
    State(state): State<AppState>,
    Extension(hub): Extension<Arc<RoomHub>>,
) -> Response {
    match consume(&state.pool, query.ticket).await {
        Ok(Some((user, version))) => ws
            .max_message_size(1024)
            .max_frame_size(1024)
            .on_upgrade(move |socket| serve(socket, state.pool, hub, user, version)),
        Ok(None) => (
            StatusCode::UNAUTHORIZED,
            Json(json!({"code":"invalid_ticket"})),
        )
            .into_response(),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"code":"database_unavailable"})),
        )
            .into_response(),
    }
}

async fn send_bounded(socket: &mut WebSocket, message: Message) -> bool {
    matches!(
        tokio::time::timeout(Duration::from_secs(5), socket.send(message)).await,
        Ok(Ok(()))
    )
}

/// Cierre por sesión revocada: el cliente pide un pase nuevo con su JWT
/// renovado o, si ya no tiene sesión, vuelve al inicio de sesión.
fn revoked_close() -> Message {
    Message::Close(Some(CloseFrame {
        code: session::SESSION_REVOKED_CLOSE,
        reason: "session_revoked".into(),
    }))
}

async fn serve(mut socket: WebSocket, pool: PgPool, hub: Arc<RoomHub>, user: Uuid, version: i32) {
    let mut changes = hub.subscribe();
    let mut revocations = session::revocations();
    // Una revocación entre el canje del pase y la suscripción no se perdería
    // de vista: se compara la versión ya suscritos.
    if !matches!(session::current_version(&pool, user).await, Ok(Some(v)) if v == version) {
        send_bounded(&mut socket, revoked_close()).await;
        return;
    }
    let Some(connection) = hub.live_join(user) else {
        send_bounded(&mut socket, Message::Close(None)).await;
        return;
    };
    let mut revoked = false;
    let mut heartbeat = tokio::time::interval(Duration::from_secs(5));
    let start = tokio::time::Instant::now();
    let mut last_pong = start;
    let mut last_snapshot = Value::Null;
    loop {
        let mut periodic = false;
        tokio::select! {
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Pong(_))) => last_pong = tokio::time::Instant::now(),
                Some(Ok(Message::Ping(value))) => { if !send_bounded(&mut socket, Message::Pong(value)).await { break; } },
                _ => break, // Clients cannot publish arbitrary state or broadcasts.
            },
            changed = changes.changed() => { if changed.is_err() { break; } },
            revocation = revocations.recv() => match revocation {
                Ok(id) if id == user => { revoked = true; break; }
                Ok(_) => continue,
                // Se perdieron avisos: se comprueba la versión directamente.
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    if !matches!(session::current_version(&pool, user).await, Ok(Some(v)) if v == version) {
                        revoked = true;
                        break;
                    }
                    continue;
                }
                Err(broadcast::error::RecvError::Closed) => break,
            },
            _ = heartbeat.tick() => {
                periodic = true;
                if start.elapsed() >= Duration::from_secs(15*60) || last_pong.elapsed() > Duration::from_secs(20) { break; }
                if !send_bounded(&mut socket, Message::Ping(Vec::new().into())).await { break; }
            },
        }
        let Ok(Some(current)) = snapshot(&pool, &hub, user).await else {
            break;
        };
        if current != last_snapshot {
            if !send_bounded(&mut socket, Message::Text(current.to_string().into())).await {
                break;
            }
            last_snapshot = current;
        } else if periodic
            && !send_bounded(
                &mut socket,
                Message::Text(
                    json!({"type":"live_heartbeat","user_id":user})
                        .to_string()
                        .into(),
                ),
            )
            .await
        {
            break;
        }
    }
    hub.live_leave(user, connection);
    let close = if revoked {
        revoked_close()
    } else {
        Message::Close(None)
    };
    send_bounded(&mut socket, close).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::StreamExt;
    use tokio_tungstenite::{connect_async, tungstenite::Message as ClientMessage};

    async fn test_pool() -> PgPool {
        let pool = PgPool::connect(&std::env::var("IRONLINK_TEST_DATABASE_URL").unwrap())
            .await
            .unwrap();
        // Todas las migraciones, como main.rs: el snapshot consulta tablas de
        // casi todos los módulos y la prueba debe funcionar sola.
        for file in [
            include_str!("../migrations/001_sprint1_complete.sql"),
            include_str!("../migrations/002_sprint2_fixes.sql"),
            include_str!("../migrations/003_sprint3_rtc.sql"),
            include_str!("../migrations/004_direct_messages.sql"),
            include_str!("../migrations/005_rtc_moderation.sql"),
            include_str!("../migrations/006_live_updates.sql"),
            include_str!("../migrations/007_calendar_index.sql"),
            include_str!("../migrations/008_attendance.sql"),
            include_str!("../migrations/009_notifications.sql"),
            include_str!("../migrations/010_breakout_rooms.sql"),
            include_str!("../migrations/011_whiteboard.sql"),
            include_str!("../migrations/012_security_fixes.sql"),
            include_str!("../migrations/013_orphan_subgroup_members.sql"),
            include_str!("../migrations/014_session_cutoff.sql"),
            include_str!("../migrations/015_meeting_scheduling.sql"),
            include_str!("../migrations/016_friendships.sql"),
            include_str!("../migrations/017_calendar_details.sql"),
            include_str!("../migrations/018_social_privacy.sql"),
            include_str!("../migrations/019_session_version.sql"),
            include_str!("../migrations/020_ticket_session.sql"),
        ] {
            sqlx::raw_sql(sqlx::AssertSqlSafe(file))
                .execute(&pool)
                .await
                .unwrap();
        }
        pool
    }

    fn test_state(pool: &PgPool) -> AppState {
        AppState {
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
        }
    }
    #[test]
    fn presence_tracks_multiple_windows_and_does_not_clear_other_sessions() {
        let hub = RoomHub::default();
        let user = Uuid::new_v4();
        assert_eq!(hub.presence(user), "offline");
        let a = hub.live_join(user).unwrap();
        let b = hub.live_join(user).unwrap();
        assert_eq!(hub.presence(user), "available");
        hub.live_leave(user, a);
        assert_eq!(hub.presence(user), "available");
        let c = hub.live_join(user).unwrap();
        let d = hub.live_join(user).unwrap();
        let e = hub.live_join(user).unwrap();
        assert!(hub.live_join(user).is_none());
        for id in [b, c, d, e] {
            hub.live_leave(user, id);
        }
        assert_eq!(hub.presence(user), "offline");
    }
    #[tokio::test]
    #[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
    async fn snapshots_are_authorized_and_tickets_are_single_use() {
        let pool = test_pool().await;
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let outsider = Uuid::new_v4();
        let node = Uuid::new_v4();
        let room = Uuid::new_v4();
        for id in [a, b, outsider] {
            sqlx::query("INSERT INTO users(id,name,email,password,telefono,estado) VALUES($1,'Live test',$2,'test-only',$3,'ACTIVE')").bind(id).bind(format!("{id}@example.invalid")).bind(id.to_string()).execute(&pool).await.unwrap();
        }
        sqlx::query(
            "INSERT INTO nodos(id,nombre,token_acceso,creador_id) VALUES($1,'Live test',$2,$3)",
        )
        .bind(node)
        .bind(node.to_string()[..32].to_string())
        .bind(a)
        .execute(&pool)
        .await
        .unwrap();
        for id in [a, b] {
            sqlx::query("INSERT INTO nodo_miembros(nodo_id,user_id) VALUES($1,$2)")
                .bind(node)
                .bind(id)
                .execute(&pool)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO reuniones(id,nodo_id,titulo,enlace,fecha_inicio,creado_por,rtc_estado,rtc_started_at) VALUES($1,$2,'Started','',NOW(),$3,'active',NOW())").bind(room).bind(node).bind(a).execute(&pool).await.unwrap();
        let hub = Arc::new(RoomHub::default());
        let online = hub.live_join(a).unwrap();
        let data = snapshot(&pool, &hub, b).await.unwrap().unwrap();
        assert_eq!(data["presence"][a.to_string()], "available");
        assert_eq!(data["meetings"][0]["id"], room.to_string());
        let hidden = snapshot(&pool, &hub, outsider).await.unwrap().unwrap();
        assert!(hidden["presence"].get(a.to_string()).is_none());
        assert_eq!(hidden["meetings"], json!([]));
        let ticket = Uuid::new_v4();
        sqlx::query("INSERT INTO live_tickets(id,user_id,expires_at) VALUES($1,$2,NOW()+INTERVAL '60 seconds')").bind(ticket).bind(b).execute(&pool).await.unwrap();
        assert_eq!(consume(&pool, ticket).await.unwrap(), Some((b, 0)));
        assert_eq!(consume(&pool, ticket).await.unwrap(), None);
        // Real WS delivery: starting a meeting wakes authorized application
        // subscribers, without any RTC-room subscription or HTTP polling.
        let live_ticket = Uuid::new_v4();
        sqlx::query("INSERT INTO live_tickets(id,user_id,expires_at) VALUES($1,$2,NOW()+INTERVAL '60 seconds')").bind(live_ticket).bind(b).execute(&pool).await.unwrap();
        let state = test_state(&pool);
        let router = axum::Router::new()
            .route("/live/ws", axum::routing::get(websocket))
            .layer(Extension(hub.clone()))
            .with_state(state.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        let (mut socket, _) = connect_async(format!("ws://{address}/live/ws?ticket={live_ticket}"))
            .await
            .unwrap();
        let first = loop {
            if let ClientMessage::Text(text) =
                tokio::time::timeout(Duration::from_secs(2), socket.next())
                    .await
                    .unwrap()
                    .unwrap()
                    .unwrap()
            {
                let message = serde_json::from_str::<Value>(&text).unwrap();
                if message["type"] == "live_snapshot" {
                    break message;
                }
            }
        };
        assert_eq!(first["type"], "live_snapshot");
        assert_eq!(first["presence"][b.to_string()], "available");
        assert!(
            connect_async(format!("ws://{address}/live/ws?ticket={live_ticket}"))
                .await
                .is_err()
        );
        let second_room = Uuid::new_v4();
        sqlx::query("INSERT INTO reuniones(id,nodo_id,titulo,enlace,fecha_inicio,creado_por) VALUES($1,$2,'New meeting','',NOW(),$3)").bind(second_room).bind(node).bind(a).execute(&pool).await.unwrap();
        assert_eq!(
            crate::rtc::server::start_meeting(
                State(state),
                Extension(AuthUser {
                    user_id: a,
                    role: "MEMBER".into(),
                    session_version: 0,
                }),
                Extension(hub.clone()),
                axum::extract::Path((node, second_room))
            )
            .await
            .0,
            StatusCode::OK
        );
        let delivered = loop {
            if let ClientMessage::Text(text) =
                tokio::time::timeout(Duration::from_secs(2), socket.next())
                    .await
                    .unwrap()
                    .unwrap()
                    .unwrap()
            {
                let message = serde_json::from_str::<Value>(&text).unwrap();
                if message["type"] == "live_snapshot" {
                    break message;
                }
            }
        };
        assert!(
            delivered["meetings"]
                .as_array()
                .unwrap()
                .iter()
                .any(|m| m["id"] == second_room.to_string())
        );
        socket.close(None).await.unwrap();
        tokio::time::timeout(Duration::from_secs(2), async {
            while hub.presence(b) != "offline" {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        server.abort();
        sqlx::query("INSERT INTO nodo_baneos(nodo_id,user_id) VALUES($1,$2)")
            .bind(node)
            .bind(b)
            .execute(&pool)
            .await
            .unwrap();
        let hidden = snapshot(&pool, &hub, b).await.unwrap().unwrap();
        assert_eq!(hidden["meetings"], json!([]));
        assert!(hidden["presence"].get(a.to_string()).is_none());
        sqlx::query("UPDATE users SET estado='SUSPENDED' WHERE id=$1")
            .bind(b)
            .execute(&pool)
            .await
            .unwrap();
        assert!(snapshot(&pool, &hub, b).await.unwrap().is_none());
        // Amistades: una solicitud pendiente solo suma al contador; aceptada,
        // la presencia se comparte aunque no haya nodo en común.
        sqlx::query("INSERT INTO amistades(solicitante,destinatario) VALUES($1,$2)")
            .bind(a)
            .bind(outsider)
            .execute(&pool)
            .await
            .unwrap();
        let pending = snapshot(&pool, &hub, outsider).await.unwrap().unwrap();
        assert_eq!(pending["friends"]["pending"], 1);
        assert!(pending["presence"].get(a.to_string()).is_none());
        sqlx::query("UPDATE amistades SET estado='aceptada' WHERE solicitante=$1")
            .bind(a)
            .execute(&pool)
            .await
            .unwrap();
        let friends = snapshot(&pool, &hub, outsider).await.unwrap().unwrap();
        assert_eq!(friends["friends"]["pending"], 0);
        assert_eq!(friends["friends"]["unread_messages"], 0);
        // Un mensaje de amistad sin leer cambia la instantánea.
        sqlx::query(
            "INSERT INTO mensajes_amistad(sender_id,recipient_id,content) VALUES($1,$2,'Hola')",
        )
        .bind(a)
        .bind(outsider)
        .execute(&pool)
        .await
        .unwrap();
        let unread = snapshot(&pool, &hub, outsider).await.unwrap().unwrap();
        assert_eq!(unread["friends"]["unread_messages"], 1);
        assert_eq!(friends["presence"][a.to_string()], "available");
        hub.live_leave(a, online);
        sqlx::query("DELETE FROM users WHERE id=ANY($1)")
            .bind(vec![a, b, outsider])
            .execute(&pool)
            .await
            .unwrap();
        pool.close().await;
    }

    /// Riesgo: cerrar sesión o cambiar la contraseña invalida los pases ya
    /// emitidos y cierra con 4401 los WebSockets abiertos de esa cuenta, sin
    /// tocar los de otras.
    #[tokio::test]
    #[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
    async fn closing_the_session_revokes_tickets_and_open_sockets() {
        type Socket = tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >;
        let pool = test_pool().await;
        let (a, c) = (Uuid::new_v4(), Uuid::new_v4());
        for id in [a, c] {
            sqlx::query("INSERT INTO users(id,name,email,password,telefono,estado) VALUES($1,'Live test',$2,'test-only',$3,'ACTIVE')").bind(id).bind(format!("{id}@example.invalid")).bind(id.to_string()).execute(&pool).await.unwrap();
        }
        let state = test_state(&pool);
        let hub = Arc::new(RoomHub::default());
        let router = axum::Router::new()
            .route("/live/ws", axum::routing::get(websocket))
            .layer(Extension(hub.clone()))
            .with_state(state.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        let issue = |user_id: Uuid, session_version: i32| {
            let state = state.clone();
            async move {
                issue_ticket(
                    State(state),
                    Extension(AuthUser {
                        user_id,
                        role: "MEMBER".into(),
                        session_version,
                    }),
                )
                .await
            }
        };
        let open = |user_id: Uuid, session_version: i32| async move {
            let (status, Json(body)) = issue(user_id, session_version).await;
            assert_eq!(status, StatusCode::OK, "{body}");
            let ticket = body["ticket"].as_str().unwrap().to_string();
            connect_async(format!("ws://{address}/live/ws?ticket={ticket}")).await
        };
        let logout = |user: Uuid| {
            let state = state.clone();
            async move {
                let refresh = Uuid::new_v4();
                sqlx::query("INSERT INTO refresh_tokens (token, user_id, expires_at) VALUES ($1, $2, NOW() + INTERVAL '1 day')")
                    .bind(refresh).bind(user).execute(&state.pool).await.unwrap();
                let body = crate::auth::session::RefreshRequest {
                    refresh_token: refresh.to_string(),
                };
                assert_eq!(
                    crate::auth::session::logout(State(state), Json(body)).await,
                    StatusCode::NO_CONTENT
                );
            }
        };
        async fn first_snapshot(socket: &mut Socket) {
            loop {
                let message = tokio::time::timeout(Duration::from_secs(2), socket.next())
                    .await
                    .unwrap()
                    .unwrap()
                    .unwrap();
                if let ClientMessage::Text(text) = message
                    && serde_json::from_str::<Value>(&text).unwrap()["type"] == "live_snapshot"
                {
                    return;
                }
            }
        }
        async fn close_code(socket: &mut Socket) -> Option<u16> {
            loop {
                match tokio::time::timeout(Duration::from_secs(2), socket.next()).await {
                    Ok(Some(Ok(ClientMessage::Close(frame)))) => {
                        return frame.map(|f| u16::from(f.code));
                    }
                    Ok(Some(Ok(_))) => continue,
                    _ => return None,
                }
            }
        }

        // 1. Un pase emitido antes de cerrar sesión ya no se canjea.
        let (status, Json(body)) = issue(a, 0).await;
        assert_eq!(status, StatusCode::OK);
        let stale = body["ticket"].as_str().unwrap().to_string();
        logout(a).await;
        assert!(
            connect_async(format!("ws://{address}/live/ws?ticket={stale}"))
                .await
                .is_err()
        );
        // 2. Con el JWT anterior (versión 0) ya no se emiten pases.
        assert_eq!(issue(a, 0).await.0, StatusCode::FORBIDDEN);

        // 3. Sockets abiertos: el de la cuenta que cierra sesión se cierra con
        // 4401; el de otra cuenta sigue abierto.
        let (mut revoked, _) = open(a, 1).await.unwrap();
        let (mut other, _) = open(c, 0).await.unwrap();
        first_snapshot(&mut revoked).await;
        first_snapshot(&mut other).await;
        logout(a).await;
        assert_eq!(
            close_code(&mut revoked).await,
            Some(crate::auth::session::SESSION_REVOKED_CLOSE)
        );
        // El de la otra cuenta sigue abierto (puede recibir latidos, no un cierre).
        let deadline = tokio::time::Instant::now() + Duration::from_millis(500);
        while let Ok(message) = tokio::time::timeout_at(deadline, other.next()).await {
            assert!(
                matches!(message, Some(Ok(ref m)) if !m.is_close()),
                "el socket de otra cuenta no se cierra: {message:?}"
            );
        }

        // 4. Cambiar la contraseña también cierra los sockets abiertos.
        let (mut after_password, _) = open(a, 2).await.unwrap();
        first_snapshot(&mut after_password).await;
        crate::auth::session::update_password(&pool, a, "test-only-2")
            .await
            .unwrap();
        assert_eq!(
            close_code(&mut after_password).await,
            Some(crate::auth::session::SESSION_REVOKED_CLOSE)
        );

        server.abort();
        sqlx::query("DELETE FROM users WHERE id = ANY($1)")
            .bind(vec![a, c])
            .execute(&pool)
            .await
            .unwrap();
    }
}
