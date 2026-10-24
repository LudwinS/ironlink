//! Sprint 4: a bounded, authorized cross-node meeting calendar.
use crate::auth::{middleware::AuthUser, verification::AppState};
use axum::{
    Extension, Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CalendarQuery {
    from: DateTime<Utc>,
    to: DateTime<Utc>,
    node_id: Option<Uuid>,
}
impl CalendarQuery {
    fn valid(&self) -> bool {
        self.to > self.from && self.to - self.from <= Duration::days(93)
    }
}

#[derive(Serialize, sqlx::FromRow)]
struct CalendarEvent {
    id: Uuid,
    nodo_id: Uuid,
    nodo_nombre: String,
    titulo: String,
    descripcion: Option<String>,
    fecha_inicio: DateTime<Utc>,
    fecha_fin: Option<DateTime<Utc>>,
    enlace_reunion: Option<String>,
    creado_por: Uuid,
    creador_nombre: String,
    created_at: DateTime<Utc>,
    rtc_estado: String,
    serie_id: Option<Uuid>,
    repeticion: Option<String>,
    espontanea: bool,
    privada: bool,
    mi_respuesta: Option<String>,
    invitados: i64,
    aceptados: i64,
    can_moderate: bool,
    can_join: bool,
    todo_el_dia: bool,
    ubicacion: Option<String>,
    asistentes: Vec<Uuid>,
}

async fn events(
    pool: &PgPool,
    user: Uuid,
    query: &CalendarQuery,
) -> Result<Option<Vec<CalendarEvent>>, sqlx::Error> {
    select(pool, user, Scope::Range(query)).await
}

/// Sprint 4 (IRL-WKS-US-06): resolves a shared meeting link with exactly the
/// calendar's authorization. Links carry only the meeting ID, never tokens.
async fn shared_meeting(
    pool: &PgPool,
    user: Uuid,
    meeting: Uuid,
) -> Result<Option<Option<CalendarEvent>>, sqlx::Error> {
    Ok(select(pool, user, Scope::Meeting(meeting))
        .await?
        .map(|rows| rows.into_iter().next()))
}

enum Scope<'a> {
    Range(&'a CalendarQuery),
    Meeting(Uuid),
}

async fn select(
    pool: &PgPool,
    user: Uuid,
    scope: Scope<'_>,
) -> Result<Option<Vec<CalendarEvent>>, sqlx::Error> {
    let (from, to, node, meeting) = match scope {
        Scope::Range(q) => (Some(q.from), Some(q.to), q.node_id, None),
        Scope::Meeting(id) => (None, None, None, Some(id)),
    };
    // Unlike the JWT role claim, account activation is checked live in the DB.
    if !sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND estado='ACTIVE')",
    )
    .bind(user)
    .fetch_one(pool)
    .await?
    {
        return Ok(None);
    }
    let rows = sqlx::query_as::<_, CalendarEvent>(
        "SELECT r.id,r.nodo_id,n.nombre AS nodo_nombre,r.titulo,r.descripcion,
         r.fecha_inicio,r.fecha_fin,r.enlace_reunion,r.creado_por,u.name AS creador_nombre,
         r.created_at,r.rtc_estado,r.serie_id,r.repeticion,r.espontanea,r.privada,
         (SELECT i.respuesta FROM reunion_invitados i WHERE i.reunion_id=r.id AND i.user_id=$1) AS mi_respuesta,
         (SELECT COUNT(*) FROM reunion_invitados i WHERE i.reunion_id=r.id) AS invitados,
         (SELECT COUNT(*) FROM reunion_invitados i WHERE i.reunion_id=r.id AND i.respuesta='aceptada') AS aceptados,
         (r.creado_por=$1 OR n.creador_id=$1 OR me.rol::text IN ('ADMIN','MODERATOR')) AS can_moderate,
         (r.rtc_estado='active' AND NOT EXISTS(SELECT 1 FROM rtc_participant_controls c WHERE c.reunion_id=r.id AND c.user_id=$1 AND c.kicked)) AS can_join,
         r.todo_el_dia,r.ubicacion,
         ARRAY(SELECT i.user_id FROM reunion_invitados i WHERE i.reunion_id=r.id AND i.user_id<>r.creado_por ORDER BY i.user_id) AS asistentes
         FROM reuniones r JOIN nodos n ON n.id=r.nodo_id AND n.estado='active'
         JOIN nodo_miembros me ON me.nodo_id=n.id AND me.user_id=$1
         JOIN users u ON u.id=r.creado_por
         WHERE (($5::uuid IS NULL AND r.fecha_inicio >= $2 AND r.fecha_inicio < $3) OR r.id=$5)
         AND ($4::uuid IS NULL OR n.id=$4)
         AND (NOT r.privada OR r.creado_por=$1 OR EXISTS(SELECT 1 FROM reunion_invitados i WHERE i.reunion_id=r.id AND i.user_id=$1))
         AND NOT EXISTS(SELECT 1 FROM nodo_baneos b WHERE b.nodo_id=n.id AND b.user_id=$1)
         ORDER BY r.fecha_inicio,r.id LIMIT 501"
    ).bind(user).bind(from).bind(to).bind(node).bind(meeting).fetch_all(pool).await?;
    Ok(Some(rows))
}

pub async fn list(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Query(query): Query<CalendarQuery>,
) -> (StatusCode, Json<Value>) {
    if !query.valid() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"message":"El intervalo debe ser positivo y no superar 93 días."})),
        );
    }
    match events(&state.pool, user.user_id, &query).await {
        Ok(Some(mut rows)) => {
            let truncated = rows.len() > 500;
            rows.truncate(500);
            (
                StatusCode::OK,
                Json(json!({"reuniones":rows,"truncated":truncated})),
            )
        }
        Ok(None) => (
            StatusCode::FORBIDDEN,
            Json(json!({"message":"La cuenta no está activa."})),
        ),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"message":"No se pudo cargar el calendario. Intenta nuevamente."})),
        ),
    }
}

/// `GET /reuniones/{id}`: datos de una reunión compartida por enlace. Quien no
/// pertenece al nodo, está baneado o la reunión no existe recibe el mismo 404,
/// así un enlace no revela si la reunión existe.
pub async fn shared(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Path(id): Path<Uuid>,
) -> (StatusCode, Json<Value>) {
    match shared_meeting(&state.pool, user.user_id, id).await {
        Ok(Some(Some(event))) => (StatusCode::OK, Json(json!({ "reunion": event }))),
        Ok(Some(None)) => (
            StatusCode::NOT_FOUND,
            Json(json!({"message":"La reunión no existe o no tienes acceso a ella."})),
        ),
        Ok(None) => (
            StatusCode::FORBIDDEN,
            Json(json!({"message":"La cuenta no está activa."})),
        ),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"message":"No se pudo abrir la reunión. Intenta nuevamente."})),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn calendar_range_is_bounded_and_half_open() {
        let from = Utc::now();
        for (days, accepted) in [(0, false), (-1, false), (1, true), (93, true), (94, false)] {
            assert_eq!(
                CalendarQuery {
                    from,
                    to: from + Duration::days(days),
                    node_id: None
                }
                .valid(),
                accepted
            );
        }
        assert!(
            serde_json::from_value::<CalendarQuery>(json!({"from":"invalid","to":"invalid"}))
                .is_err()
        );
        assert!(
            serde_json::from_value::<CalendarQuery>(
                json!({"from":from,"to":from+Duration::days(1),"user_id":Uuid::new_v4()})
            )
            .is_err()
        );
    }
    #[tokio::test]
    #[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
    async fn calendar_only_contains_authorized_nodes_and_rechecks_bans() {
        let pool = PgPool::connect(&std::env::var("IRONLINK_TEST_DATABASE_URL").unwrap())
            .await
            .unwrap();
        for file in [
            include_str!("../migrations/001_sprint1_complete.sql"),
            include_str!("../migrations/002_sprint2_fixes.sql"),
            include_str!("../migrations/003_sprint3_rtc.sql"),
            include_str!("../migrations/005_rtc_moderation.sql"),
            include_str!("../migrations/007_calendar_index.sql"),
            include_str!("../migrations/009_notifications.sql"),
            include_str!("../migrations/015_meeting_scheduling.sql"),
            include_str!("../migrations/017_calendar_details.sql"),
        ] {
            sqlx::raw_sql(sqlx::AssertSqlSafe(file))
                .execute(&pool)
                .await
                .unwrap();
        }
        let owner = Uuid::new_v4();
        let member = Uuid::new_v4();
        let outsider = Uuid::new_v4();
        for id in [owner, member, outsider] {
            sqlx::query("INSERT INTO users(id,name,email,password,telefono,estado) VALUES($1,'Calendar test',$2,'test-only',$3,'ACTIVE')").bind(id).bind(format!("{id}@example.invalid")).bind(id.to_string()).execute(&pool).await.unwrap();
        }
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        for node in [a, b] {
            sqlx::query("INSERT INTO nodos(id,nombre,token_acceso,creador_id) VALUES($1,'Calendar node',$2,$3)").bind(node).bind(node.to_string()[..32].to_string()).bind(owner).execute(&pool).await.unwrap();
            for user in [owner, member] {
                sqlx::query("INSERT INTO nodo_miembros(nodo_id,user_id) VALUES($1,$2)")
                    .bind(node)
                    .bind(user)
                    .execute(&pool)
                    .await
                    .unwrap();
            }
        }
        let from = DateTime::parse_from_rfc3339("2026-10-01T00:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let to = from + Duration::days(31);
        let mut ids = vec![];
        for (node, time) in [(a, from), (b, from + Duration::days(1)), (a, to)] {
            let id = Uuid::new_v4();
            ids.push(id);
            sqlx::query("INSERT INTO reuniones(id,nodo_id,titulo,enlace,fecha_inicio,creado_por,rtc_estado) VALUES($1,$2,'Calendar event','',$3,$4,'active')").bind(id).bind(node).bind(time).bind(owner).execute(&pool).await.unwrap();
        }
        let mut query = CalendarQuery {
            from,
            to,
            node_id: None,
        };
        let rows = events(&pool, member, &query).await.unwrap().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].id, ids[0]);
        // A shared link resolves only for members, regardless of the date range.
        let shared = |u, id| shared_meeting(&pool, u, id);
        assert_eq!(
            shared(member, ids[2]).await.unwrap().unwrap().unwrap().id,
            ids[2]
        );
        assert!(shared(outsider, ids[0]).await.unwrap().unwrap().is_none());
        assert!(
            shared(member, Uuid::new_v4())
                .await
                .unwrap()
                .unwrap()
                .is_none()
        );
        assert!(rows.iter().all(|r| !r.can_moderate && r.can_join));
        assert!(
            events(&pool, owner, &query)
                .await
                .unwrap()
                .unwrap()
                .iter()
                .all(|r| r.can_moderate)
        );
        assert!(
            events(&pool, outsider, &query)
                .await
                .unwrap()
                .unwrap()
                .is_empty()
        );
        query.node_id = Some(b);
        assert_eq!(
            events(&pool, member, &query).await.unwrap().unwrap().len(),
            1
        );
        sqlx::query(
            "INSERT INTO rtc_participant_controls(reunion_id,user_id,kicked) VALUES($1,$2,true)",
        )
        .bind(ids[1])
        .bind(member)
        .execute(&pool)
        .await
        .unwrap();
        assert!(!events(&pool, member, &query).await.unwrap().unwrap()[0].can_join);
        sqlx::query("INSERT INTO nodo_baneos(nodo_id,user_id,creado_por) VALUES($1,$2,$3)")
            .bind(b)
            .bind(member)
            .bind(owner)
            .execute(&pool)
            .await
            .unwrap();
        assert!(shared(member, ids[1]).await.unwrap().unwrap().is_none());
        assert!(
            events(&pool, member, &query)
                .await
                .unwrap()
                .unwrap()
                .is_empty()
        );
        query.node_id = None;
        assert_eq!(
            events(&pool, member, &query).await.unwrap().unwrap().len(),
            1
        );
        sqlx::query("DELETE FROM nodo_miembros WHERE nodo_id=$1 AND user_id=$2")
            .bind(a)
            .bind(member)
            .execute(&pool)
            .await
            .unwrap();
        assert!(
            events(&pool, member, &query)
                .await
                .unwrap()
                .unwrap()
                .is_empty()
        );
        sqlx::query("UPDATE users SET estado='SUSPENDED' WHERE id=$1")
            .bind(member)
            .execute(&pool)
            .await
            .unwrap();
        assert!(events(&pool, member, &query).await.unwrap().is_none());
        sqlx::query("DELETE FROM users WHERE id=ANY($1)")
            .bind(vec![owner, member, outsider])
            .execute(&pool)
            .await
            .unwrap();
        pool.close().await;
    }
}
