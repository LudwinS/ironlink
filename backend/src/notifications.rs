//! Sprint 4: recordatorios de reunión (IRL-NTF-US-01) y panel de
//! notificaciones del día (IRL-NTF-US-03). Solo el servidor crea
//! notificaciones; cada usuario lee y marca las suyas.
use crate::auth::{middleware::AuthUser, verification::AppState};
use axum::{
    Extension, Json,
    extract::{Query, State},
    http::StatusCode,
};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

/// Crea los recordatorios de 15 y 5 minutos que correspondan ahora mismo.
///
/// Se ejecuta periódicamente. `dedupe_key` incluye la hora de inicio: un
/// recordatorio no se repite, y reprogramar la reunión genera los de la nueva
/// hora. Si la reunión ya está a 5 minutos o menos, solo se envía el de 5.
/// Devuelve cuántas notificaciones se crearon.
pub async fn generate_reminders(pool: &PgPool) -> Result<u64, sqlx::Error> {
    Ok(sqlx::query(
        "INSERT INTO notificaciones (user_id, tipo, nodo_id, reunion_id, titulo, programada_para, dedupe_key)
         SELECT m.user_id, t.tipo, r.nodo_id, r.id, r.titulo, r.fecha_inicio,
                t.tipo || ':' || r.id || ':' || m.user_id || ':' || EXTRACT(EPOCH FROM r.fecha_inicio)::bigint
         FROM reuniones r
         JOIN nodos n ON n.id = r.nodo_id AND n.estado = 'active'
         JOIN nodo_miembros m ON m.nodo_id = r.nodo_id
         JOIN users u ON u.id = m.user_id AND u.estado = 'ACTIVE'
         CROSS JOIN (VALUES ('recordatorio_15', 15), ('recordatorio_5', 5)) AS t(tipo, minutos)
         WHERE r.rtc_estado = 'scheduled'
           -- Los eventos de todo el día no avisan a medianoche.
           AND NOT r.todo_el_dia
           AND r.fecha_inicio > NOW()
           AND r.fecha_inicio <= NOW() + make_interval(mins => t.minutos)
           AND NOT (t.minutos = 15 AND r.fecha_inicio <= NOW() + INTERVAL '5 minutes')
           AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = r.nodo_id AND b.user_id = m.user_id)
           -- Sin avisos de reuniones ajenas privadas ni para quien declinó.
           AND (NOT r.privada OR r.creado_por = m.user_id OR EXISTS (SELECT 1 FROM reunion_invitados i WHERE i.reunion_id = r.id AND i.user_id = m.user_id))
           AND NOT EXISTS (SELECT 1 FROM reunion_invitados i WHERE i.reunion_id = r.id AND i.user_id = m.user_id AND i.respuesta = 'rechazada')
         ON CONFLICT (dedupe_key) DO NOTHING",
    )
    .execute(pool)
    .await?
    .rows_affected())
}

/// Aviso persistente de que un moderador inició la reunión (complementa el
/// aviso en vivo de IRL-NTF-US-02 para quien no estaba conectado).
pub async fn meeting_started(pool: &PgPool, room: Uuid, starter: Uuid) {
    if let Err(e) = sqlx::query(
        "INSERT INTO notificaciones (user_id, tipo, nodo_id, reunion_id, titulo, programada_para, dedupe_key)
         SELECT m.user_id, 'reunion_iniciada', r.nodo_id, r.id, r.titulo, r.fecha_inicio,
                'reunion_iniciada:' || r.id || ':' || m.user_id
         FROM reuniones r
         JOIN nodo_miembros m ON m.nodo_id = r.nodo_id AND m.user_id <> $2
         JOIN users u ON u.id = m.user_id AND u.estado = 'ACTIVE'
         WHERE r.id = $1
           AND (NOT r.privada OR EXISTS (SELECT 1 FROM reunion_invitados i WHERE i.reunion_id = r.id AND i.user_id = m.user_id))
           AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = r.nodo_id AND b.user_id = m.user_id)
         ON CONFLICT (dedupe_key) DO NOTHING",
    )
    .bind(room)
    .bind(starter)
    .execute(pool)
    .await
    {
        eprintln!("Notificaciones: no se pudo registrar el inicio de la reunión: {e}");
    }
}

/// Las consultas solo devuelven notificaciones propias de nodos activos donde
/// el usuario sigue siendo miembro y no está baneado.
///
/// Resumen para el canal en vivo: no leídas de las últimas 24 h y la más
/// reciente, para que el cliente avise al llegar una nueva.
pub async fn live_summary(pool: &PgPool, user: Uuid) -> Result<Value, sqlx::Error> {
    let (unread, latest): (i64, Option<Uuid>) = sqlx::query_as("SELECT COUNT(*) FILTER (WHERE n.read_at IS NULL),
                (ARRAY_AGG(n.id ORDER BY n.created_at DESC, n.id DESC))[1]
         FROM notificaciones n
         WHERE n.user_id = $1
    AND EXISTS (SELECT 1 FROM nodos x JOIN nodo_miembros me ON me.nodo_id = x.id AND me.user_id = $1
                WHERE x.id = n.nodo_id AND x.estado = 'active')
    AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = n.nodo_id AND b.user_id = $1) AND n.created_at > NOW() - INTERVAL '24 hours'")
    .bind(user)
    .fetch_one(pool)
    .await?;
    Ok(json!({ "unread": unread, "latest": latest }))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ListQuery {
    /// Inicio del día en la zona del cliente, en UTC.
    desde: DateTime<Utc>,
}

#[derive(Serialize, sqlx::FromRow)]
struct Item {
    id: Uuid,
    tipo: String,
    nodo_id: Uuid,
    nodo_nombre: String,
    reunion_id: Uuid,
    titulo: String,
    programada_para: DateTime<Utc>,
    created_at: DateTime<Utc>,
    read_at: Option<DateTime<Utc>>,
    reunion_estado: String,
}

async fn list_items(
    pool: &PgPool,
    user: Uuid,
    since: DateTime<Utc>,
) -> Result<Vec<Item>, sqlx::Error> {
    sqlx::query_as::<_, Item>("SELECT n.id, n.tipo, n.nodo_id, x.nombre AS nodo_nombre, n.reunion_id, n.titulo,
                n.programada_para, n.created_at, n.read_at, r.rtc_estado AS reunion_estado
         FROM notificaciones n
         JOIN nodos x ON x.id = n.nodo_id
         JOIN reuniones r ON r.id = n.reunion_id
         WHERE n.user_id = $1
    AND EXISTS (SELECT 1 FROM nodos x JOIN nodo_miembros me ON me.nodo_id = x.id AND me.user_id = $1
                WHERE x.id = n.nodo_id AND x.estado = 'active')
    AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = n.nodo_id AND b.user_id = $1) AND n.created_at >= $2
         ORDER BY n.created_at DESC, n.id DESC LIMIT 200")
    .bind(user)
    .bind(since)
    .fetch_all(pool)
    .await
}

/// `GET /notificaciones?desde=<RFC3339>` — notificaciones propias desde esa
/// hora (como máximo 48 h atrás) y hasta 200, de más reciente a más antigua.
pub async fn list(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Query(query): Query<ListQuery>,
) -> (StatusCode, Json<Value>) {
    let now = Utc::now();
    if query.desde > now || now - query.desde > Duration::hours(48) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"message":"El inicio debe estar dentro de las últimas 48 horas."})),
        );
    }
    match list_items(&state.pool, user.user_id, query.desde).await {
        Ok(items) => (StatusCode::OK, Json(json!({ "notificaciones": items }))),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"message":"No se pudieron cargar las notificaciones."})),
        ),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MarkRead {
    #[serde(default)]
    ids: Vec<Uuid>,
    #[serde(default)]
    todas: bool,
}

async fn mark(pool: &PgPool, user: Uuid, body: &MarkRead) -> Result<u64, sqlx::Error> {
    Ok(sqlx::query(
        "UPDATE notificaciones SET read_at = NOW()
         WHERE user_id = $1 AND read_at IS NULL AND ($2 OR id = ANY($3))",
    )
    .bind(user)
    .bind(body.todas)
    .bind(&body.ids)
    .execute(pool)
    .await?
    .rows_affected())
}

/// `POST /notificaciones/leidas` con `{"ids":[...]}` o `{"todas":true}`.
/// Solo afecta a las notificaciones del propio usuario.
pub async fn mark_read(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Extension(hub): Extension<std::sync::Arc<crate::rtc::server::RoomHub>>,
    Json(body): Json<MarkRead>,
) -> (StatusCode, Json<Value>) {
    if body.ids.len() > 200 || (!body.todas && body.ids.is_empty()) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"message":"Indica entre 1 y 200 notificaciones, o todas."})),
        );
    }
    match mark(&state.pool, user.user_id, &body).await {
        Ok(updated) => {
            // Actualiza el contador en las demás ventanas del usuario.
            hub.changed();
            (StatusCode::OK, Json(json!({ "actualizadas": updated })))
        }
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"message":"No se pudieron actualizar las notificaciones."})),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    #[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
    async fn reminders_are_timely_unique_rescheduled_and_private() {
        let pool = PgPool::connect(&std::env::var("IRONLINK_TEST_DATABASE_URL").unwrap())
            .await
            .unwrap();
        for file in [
            include_str!("../migrations/001_sprint1_complete.sql"),
            include_str!("../migrations/002_sprint2_fixes.sql"),
            include_str!("../migrations/003_sprint3_rtc.sql"),
            include_str!("../migrations/005_rtc_moderation.sql"),
            include_str!("../migrations/009_notifications.sql"),
            include_str!("../migrations/015_meeting_scheduling.sql"),
            include_str!("../migrations/017_calendar_details.sql"),
        ] {
            sqlx::raw_sql(sqlx::AssertSqlSafe(file))
                .execute(&pool)
                .await
                .unwrap();
        }
        let (owner, ana, banned, outsider) = (
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
        );
        for id in [owner, ana, banned, outsider] {
            sqlx::query("INSERT INTO users(id,name,email,password,telefono,estado) VALUES($1,'N',$2,'test-only',$3,'ACTIVE')")
                .bind(id).bind(format!("{id}@example.invalid")).bind(id.to_string())
                .execute(&pool).await.unwrap();
        }
        let node = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO nodos(id,nombre,token_acceso,creador_id) VALUES($1,'Recordatorios',$2,$3)",
        )
        .bind(node)
        .bind(node.to_string()[..32].to_string())
        .bind(owner)
        .execute(&pool)
        .await
        .unwrap();
        for user in [owner, ana, banned] {
            sqlx::query("INSERT INTO nodo_miembros(nodo_id,user_id) VALUES($1,$2)")
                .bind(node)
                .bind(user)
                .execute(&pool)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO nodo_baneos(nodo_id,user_id,creado_por) VALUES($1,$2,$3)")
            .bind(node)
            .bind(banned)
            .bind(owner)
            .execute(&pool)
            .await
            .unwrap();
        let count = |user: Uuid, tipo: &'static str| {
            let pool = pool.clone();
            async move {
                sqlx::query_scalar::<_, i64>(
                    "SELECT COUNT(*) FROM notificaciones WHERE user_id=$1 AND tipo=$2",
                )
                .bind(user)
                .bind(tipo)
                .fetch_one(&pool)
                .await
                .unwrap()
            }
        };
        let schedule = |minutes: i64| {
            let pool = pool.clone();
            async move {
                let id = Uuid::new_v4();
                sqlx::query("INSERT INTO reuniones(id,nodo_id,titulo,enlace,fecha_inicio,creado_por) VALUES($1,$2,'Daily','',NOW() + make_interval(mins => $3),$4)")
                    .bind(id).bind(node).bind(minutes as i32).bind(owner)
                    .execute(&pool).await.unwrap();
                id
            }
        };

        // A 30 min no hay recordatorio; a 12 min, el de 15; a 3 min, solo el de 5.
        let far = schedule(30).await;
        let soon = schedule(12).await;
        let close = schedule(3).await;
        // Dos miembros activos sin ban: owner y ana, y dos reuniones en ventana.
        assert_eq!(generate_reminders(&pool).await.unwrap(), 4);
        assert_eq!(
            generate_reminders(&pool).await.unwrap(),
            0,
            "sin duplicados"
        );
        assert_eq!(count(ana, "recordatorio_15").await, 1);
        assert_eq!(count(ana, "recordatorio_5").await, 1);
        assert_eq!(count(banned, "recordatorio_15").await, 0);
        assert_eq!(count(outsider, "recordatorio_5").await, 0);
        let close_15: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM notificaciones WHERE reunion_id=$1 AND tipo='recordatorio_15'",
        )
        .bind(close)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(close_15, 0);

        // Reprogramar a 4 min genera el de 5 para la nueva hora.
        sqlx::query("UPDATE reuniones SET fecha_inicio = NOW() + INTERVAL '4 minutes' WHERE id=$1")
            .bind(soon)
            .execute(&pool)
            .await
            .unwrap();
        assert_eq!(generate_reminders(&pool).await.unwrap(), 2);
        // Una reunión iniciada ya no genera recordatorios.
        sqlx::query("UPDATE reuniones SET rtc_estado='active', fecha_inicio = NOW() + INTERVAL '2 minutes' WHERE id=$1")
            .bind(far).execute(&pool).await.unwrap();
        assert_eq!(generate_reminders(&pool).await.unwrap(), 0);

        meeting_started(&pool, far, owner).await;
        assert_eq!(count(ana, "reunion_iniciada").await, 1);
        assert_eq!(
            count(owner, "reunion_iniciada").await,
            0,
            "quien inicia no se avisa"
        );
        assert_eq!(count(banned, "reunion_iniciada").await, 0);

        let since = Utc::now() - Duration::hours(1);
        let items = list_items(&pool, ana, since).await.unwrap();
        assert_eq!(items.len(), 4);
        assert_eq!(live_summary(&pool, ana).await.unwrap()["unread"], 4);
        let first = items[0].id;
        assert_eq!(
            mark(
                &pool,
                ana,
                &MarkRead {
                    ids: vec![first],
                    todas: false
                }
            )
            .await
            .unwrap(),
            1
        );
        // Nadie puede marcar notificaciones ajenas.
        let owner_items = list_items(&pool, owner, since).await.unwrap();
        assert_eq!(
            mark(
                &pool,
                ana,
                &MarkRead {
                    ids: vec![owner_items[0].id],
                    todas: false
                }
            )
            .await
            .unwrap(),
            0
        );
        assert_eq!(live_summary(&pool, ana).await.unwrap()["unread"], 3);
        assert_eq!(
            mark(
                &pool,
                ana,
                &MarkRead {
                    ids: vec![],
                    todas: true
                }
            )
            .await
            .unwrap(),
            3
        );

        // Al salir del nodo dejan de verse sus notificaciones.
        sqlx::query("DELETE FROM nodo_miembros WHERE nodo_id=$1 AND user_id=$2")
            .bind(node)
            .bind(ana)
            .execute(&pool)
            .await
            .unwrap();
        assert!(list_items(&pool, ana, since).await.unwrap().is_empty());
        assert_eq!(live_summary(&pool, ana).await.unwrap()["unread"], 0);
    }
}
