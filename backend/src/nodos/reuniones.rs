//! Reuniones de un nodo: programación (con repetición e invitados que
//! responden), reuniones instantáneas ("Reunirse ahora") y su gestión.
//!
//! Las reuniones son de IronLink: ya no se pide un enlace externo. El enlace
//! para compartir se genera en el cliente a partir del ID de la reunión.
use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use chrono::{DateTime, Datelike, Duration, Months, Utc, Weekday};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::auth::verification::AppState;
use crate::rtc::server::RoomHub;

/// Como máximo un año de repeticiones semanales.
const MAX_OCCURRENCES: u32 = 52;
const MAX_TITLE_CHARS: usize = 120;
const MAX_DESCRIPTION_CHARS: usize = 2000;
const MAX_LOCATION_CHARS: usize = 200;
/// Disponibilidad: como máximo dos semanas y 20 personas por consulta.
const MAX_AVAILABILITY_DAYS: i64 = 14;
const MAX_AVAILABILITY_USERS: usize = 20;

// ─── DTOs ────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct RepeticionDto {
    /// `none`, `daily`, `weekdays`, `weekly`, `biweekly` o `monthly`.
    pub frecuencia: String,
    pub ocurrencias: u32,
}

#[derive(Deserialize)]
pub struct CreateReunionDto {
    pub titulo: String,
    pub descripcion: Option<String>,
    pub fecha_inicio: DateTime<Utc>,
    pub fecha_fin: Option<DateTime<Utc>>,
    /// Compatibilidad con clientes anteriores; la app ya no lo pide.
    pub enlace_reunion: Option<String>,
    pub repeticion: Option<RepeticionDto>,
    /// Personas invitadas. Sin valor se invita a todo el nodo.
    pub invitados: Option<Vec<Uuid>>,
    /// Desfase horario del cliente en minutos (UTC−6 → −360). Decide qué día
    /// es laborable y en qué día del mes cae cada repetición.
    pub zona_minutos: Option<i32>,
    /// Evento de todo el día: de medianoche local a la medianoche siguiente.
    #[serde(default)]
    pub todo_el_dia: bool,
    /// Sala, dirección o lugar (opcional, máx. 200 caracteres).
    pub ubicacion: Option<String>,
}

/// Cambios de una reunión. Los campos ausentes no cambian; una descripción
/// o ubicación vacía se borra.
#[derive(Deserialize)]
pub struct UpdateReunionDto {
    pub titulo: Option<String>,
    pub descripcion: Option<String>,
    pub fecha_inicio: Option<DateTime<Utc>>,
    pub fecha_fin: Option<DateTime<Utc>>,
    pub enlace_reunion: Option<String>,
    pub ubicacion: Option<String>,
    pub todo_el_dia: Option<bool>,
    pub zona_minutos: Option<i32>,
    /// Lista completa de invitados (sin el organizador). Los nuevos quedan
    /// pendientes de responder y los que ya no están se quitan.
    pub invitados: Option<Vec<Uuid>>,
    /// En una serie: `una` (predeterminado), `siguientes` o `serie`. El
    /// cambio de hora se aplica como desplazamiento a cada reunión aún
    /// programada; las celebradas o en curso no cambian.
    pub alcance: Option<String>,
}

#[derive(Deserialize)]
pub struct AvailabilityQuery {
    pub desde: DateTime<Utc>,
    pub hasta: DateTime<Utc>,
    /// UUID separados por comas.
    pub usuarios: String,
    /// Reunión que se está editando: no cuenta como ocupación.
    pub excluir: Option<Uuid>,
}

#[derive(Deserialize, Default)]
pub struct MeetNowDto {
    pub titulo: Option<String>,
    #[serde(default)]
    pub invitados: Vec<Uuid>,
    /// Solo quien la crea y sus invitados la ven (p. ej. una llamada directa).
    #[serde(default)]
    pub privada: bool,
}

#[derive(Deserialize)]
pub struct RespuestaDto {
    /// `aceptada`, `tentativa` o `rechazada`.
    pub respuesta: String,
    /// Aplica la respuesta a las reuniones programadas de toda la serie.
    #[serde(default)]
    pub serie: bool,
}

#[derive(Deserialize, Default)]
pub struct DeleteQuery {
    /// Cancela también las demás reuniones programadas de la serie.
    #[serde(default)]
    pub serie: bool,
}

#[derive(Serialize, Clone, sqlx::FromRow)]
pub struct ReunionInfo {
    pub id: Uuid,
    pub nodo_id: Uuid,
    pub titulo: String,
    pub descripcion: Option<String>,
    pub fecha_inicio: DateTime<Utc>,
    pub fecha_fin: Option<DateTime<Utc>>,
    pub enlace_reunion: Option<String>,
    pub creado_por: Uuid,
    pub creador_nombre: String,
    pub created_at: DateTime<Utc>,
    pub rtc_estado: String,
    pub serie_id: Option<Uuid>,
    pub repeticion: Option<String>,
    pub espontanea: bool,
    pub privada: bool,
    /// Respuesta de quien consulta, si está invitado.
    pub mi_respuesta: Option<String>,
    pub invitados: i64,
    pub aceptados: i64,
    pub todo_el_dia: bool,
    pub ubicacion: Option<String>,
    /// Personas invitadas (sin el organizador), para editar la reunión.
    pub asistentes: Vec<Uuid>,
}

#[derive(Serialize, Default)]
pub struct ReunionResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reunion: Option<ReunionInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reuniones: Option<Vec<ReunionInfo>>,
    /// Reuniones creadas por una programación repetida.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ocurrencias: Option<usize>,
}

/// Intervalo ocupado, sin datos de la reunión.
#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Intervalo {
    pub inicio: DateTime<Utc>,
    pub fin: DateTime<Utc>,
}

#[derive(Serialize)]
pub struct Disponibilidad {
    pub user_id: Uuid,
    pub ocupado: Vec<Intervalo>,
}

#[derive(Serialize, Default)]
pub struct DisponibilidadResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usuarios: Option<Vec<Disponibilidad>>,
}

/// Columnas de [`ReunionInfo`] para quien consulta ($1). Una reunión privada
/// solo es visible para quien la creó y sus invitados.
const SELECT_INFO: &str = "SELECT r.id, r.nodo_id, r.titulo, r.descripcion, r.fecha_inicio, r.fecha_fin,
        r.enlace_reunion, r.creado_por, u.name AS creador_nombre, r.created_at, r.rtc_estado,
        r.serie_id, r.repeticion, r.espontanea, r.privada,
        (SELECT i.respuesta FROM reunion_invitados i WHERE i.reunion_id = r.id AND i.user_id = $1) AS mi_respuesta,
        (SELECT COUNT(*) FROM reunion_invitados i WHERE i.reunion_id = r.id) AS invitados,
        (SELECT COUNT(*) FROM reunion_invitados i WHERE i.reunion_id = r.id AND i.respuesta = 'aceptada') AS aceptados,
        r.todo_el_dia, r.ubicacion,
        ARRAY(SELECT i.user_id FROM reunion_invitados i WHERE i.reunion_id = r.id AND i.user_id <> r.creado_por ORDER BY i.user_id) AS asistentes
     FROM reuniones r JOIN users u ON u.id = r.creado_por";

// ─── Utilidades ──────────────────────────────────────────────────────────

/// Inicio y fin de una repetición.
pub(crate) type Occurrence = (DateTime<Utc>, Option<DateTime<Utc>>);

/// Fechas de cada repetición, conservando la duración y la hora local.
pub(crate) fn occurrences(
    start: DateTime<Utc>,
    end: Option<DateTime<Utc>>,
    frecuencia: &str,
    count: u32,
    offset_minutes: i32,
) -> Result<Vec<Occurrence>, &'static str> {
    if !(1..=MAX_OCCURRENCES).contains(&count) {
        return Err("Las repeticiones deben estar entre 1 y 52.");
    }
    if !valid_offset(offset_minutes) {
        return Err("Zona horaria inválida.");
    }
    let duration = end.map(|e| e - start);
    let offset = Duration::minutes(offset_minutes.into());
    let local = start + offset;
    let mut starts = Vec::new();
    match frecuencia {
        "none" => starts.push(start),
        "daily" | "weekly" | "biweekly" => {
            let step = match frecuencia {
                "daily" => 1,
                "weekly" => 7,
                _ => 14,
            };
            for i in 0..count {
                starts.push(start + Duration::days(i64::from(i * step)));
            }
        }
        "weekdays" => {
            let mut day = 0;
            while starts.len() < count as usize {
                let candidate = local + Duration::days(day);
                if !matches!(candidate.weekday(), Weekday::Sat | Weekday::Sun) {
                    starts.push(candidate - offset);
                }
                day += 1;
            }
        }
        "monthly" => {
            for i in 0..count {
                let next = local
                    .naive_utc()
                    .checked_add_months(Months::new(i))
                    .ok_or("Fecha fuera de rango.")?;
                starts.push(next.and_utc() - offset);
            }
        }
        _ => return Err("Repetición no válida."),
    }
    if frecuencia == "none" && count != 1 {
        return Err("Una reunión que no se repite tiene una sola fecha.");
    }
    Ok(starts
        .into_iter()
        .map(|s| (s, duration.map(|d| s + d)))
        .collect())
}

fn valid_offset(offset_minutes: i32) -> bool {
    (-14 * 60..=14 * 60).contains(&offset_minutes)
}

/// Evento de todo el día: de la medianoche local del día de `start` a la
/// medianoche siguiente, según el desfase del cliente.
pub(crate) fn all_day_bounds(
    start: DateTime<Utc>,
    offset_minutes: i32,
) -> (DateTime<Utc>, DateTime<Utc>) {
    let offset = Duration::minutes(offset_minutes.into());
    let midnight = (start + offset)
        .date_naive()
        .and_time(chrono::NaiveTime::MIN)
        .and_utc()
        - offset;
    (midnight, midnight + Duration::days(1))
}

/// Ubicación sin espacios sobrantes; `Some("")` significa borrarla.
pub(crate) fn clean_location(raw: Option<&str>) -> Result<Option<&str>, &'static str> {
    let location = raw.map(str::trim);
    if location.is_some_and(|l| l.chars().count() > MAX_LOCATION_CHARS) {
        return Err("La ubicación admite como máximo 200 caracteres.");
    }
    Ok(location)
}

/// Alcance de una edición en una serie.
pub(crate) fn edit_scope(raw: Option<&str>) -> Result<&'static str, &'static str> {
    match raw.unwrap_or("una") {
        "una" => Ok("una"),
        "siguientes" => Ok("siguientes"),
        "serie" => Ok("serie"),
        _ => Err("Alcance no válido: usa una, siguientes o serie."),
    }
}

/// Lista `uuid,uuid` de la consulta de disponibilidad, sin repetidos.
pub(crate) fn parse_users(raw: &str) -> Result<Vec<Uuid>, &'static str> {
    let mut users = Vec::new();
    for part in raw.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        let id = Uuid::parse_str(part).map_err(|_| "Usuario no válido.")?;
        if !users.contains(&id) {
            users.push(id);
        }
    }
    if users.is_empty() {
        return Err("Indica al menos una persona.");
    }
    if users.len() > MAX_AVAILABILITY_USERS {
        return Err("Consulta como máximo 20 personas a la vez.");
    }
    Ok(users)
}

/// Une intervalos que se solapan o se tocan. Así la respuesta no revela
/// cuántas reuniones hay en un hueco ocupado.
pub(crate) fn merge_intervals(mut list: Vec<Intervalo>) -> Vec<Intervalo> {
    list.sort_by_key(|i| (i.inicio, i.fin));
    let mut merged: Vec<Intervalo> = Vec::with_capacity(list.len());
    for next in list {
        match merged.last_mut() {
            Some(last) if next.inicio <= last.fin => last.fin = last.fin.max(next.fin),
            _ => merged.push(next),
        }
    }
    merged
}

/// Miembro activo, no baneado, de un nodo activo.
async fn active_member(pool: &sqlx::PgPool, nodo: Uuid, user: Uuid) -> Result<bool, sqlx::Error> {
    sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM nodo_miembros nm
         JOIN nodos n ON n.id = nm.nodo_id AND n.estado = 'active'
         JOIN users u ON u.id = nm.user_id AND u.estado = 'ACTIVE'
         WHERE nm.nodo_id = $1 AND nm.user_id = $2
         AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = $1 AND b.user_id = $2))",
    )
    .bind(nodo)
    .bind(user)
    .fetch_one(pool)
    .await
}

/// Invitados válidos: miembros activos del nodo, sin repetir y sin el
/// organizador. `None` si alguno no pertenece al nodo.
async fn valid_invitees(
    pool: &sqlx::PgPool,
    nodo: Uuid,
    organizer: Uuid,
    requested: Option<&[Uuid]>,
) -> Result<Option<Vec<Uuid>>, sqlx::Error> {
    let members: Vec<Uuid> = sqlx::query_scalar(
        "SELECT nm.user_id FROM nodo_miembros nm JOIN users u ON u.id = nm.user_id AND u.estado = 'ACTIVE'
         WHERE nm.nodo_id = $1 AND nm.user_id <> $2
         AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = $1 AND b.user_id = nm.user_id)",
    )
    .bind(nodo)
    .bind(organizer)
    .fetch_all(pool)
    .await?;
    let Some(requested) = requested else {
        return Ok(Some(members));
    };
    let mut chosen: Vec<Uuid> = requested
        .iter()
        .copied()
        .filter(|u| *u != organizer)
        .collect();
    chosen.sort();
    chosen.dedup();
    Ok(chosen.iter().all(|u| members.contains(u)).then_some(chosen))
}

async fn info(pool: &sqlx::PgPool, viewer: Uuid, reunion: Uuid) -> Option<ReunionInfo> {
    sqlx::query_as::<_, ReunionInfo>(sqlx::AssertSqlSafe(format!(
        "{SELECT_INFO} WHERE r.id = $2"
    )))
    .bind(viewer)
    .bind(reunion)
    .fetch_optional(pool)
    .await
    .ok()
    .flatten()
}

// ─── POST /nodos/{id}/reuniones ──────────────────────────────────────────

pub async fn create_reunion(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path(nodo_id): Path<Uuid>,
    Json(payload): Json<CreateReunionDto>,
) -> (StatusCode, Json<ReunionResponse>) {
    match active_member(&state.pool, nodo_id, auth_user.user_id).await {
        Ok(true) => {}
        Ok(false) => {
            return (
                StatusCode::FORBIDDEN,
                ReunionResponse::failure(
                    "No tienes permiso para programar reuniones en este nodo.",
                ),
            );
        }
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                ReunionResponse::failure("No se pudo verificar tu membresía."),
            );
        }
    }

    let titulo = payload.titulo.trim();
    let descripcion = payload
        .descripcion
        .as_deref()
        .map(str::trim)
        .filter(|d| !d.is_empty());
    let zona = payload.zona_minutos.unwrap_or(0);
    let ubicacion = match clean_location(payload.ubicacion.as_deref()) {
        Ok(l) => l.filter(|l| !l.is_empty()),
        Err(message) => return (StatusCode::BAD_REQUEST, ReunionResponse::failure(message)),
    };
    // Todo el día: de medianoche a medianoche en la hora local del cliente.
    let (fecha_inicio, fecha_fin) = if payload.todo_el_dia && valid_offset(zona) {
        let (inicio, fin) = all_day_bounds(payload.fecha_inicio, zona);
        (inicio, Some(fin))
    } else {
        (payload.fecha_inicio, payload.fecha_fin)
    };
    let invalid = if titulo.is_empty() {
        Some("El título de la reunión no puede estar vacío.")
    } else if titulo.chars().count() > MAX_TITLE_CHARS {
        Some("El título admite como máximo 120 caracteres.")
    } else if descripcion.is_some_and(|d| d.chars().count() > MAX_DESCRIPTION_CHARS) {
        Some("La descripción admite como máximo 2000 caracteres.")
    } else if fecha_fin.is_some_and(|fin| fin < fecha_inicio) {
        Some("La reunión no puede terminar antes de empezar.")
    } else if fecha_fin.is_some_and(|fin| fin - fecha_inicio > Duration::hours(24)) {
        Some("Una reunión no puede durar más de 24 horas.")
    } else {
        None
    };
    if let Some(message) = invalid {
        return (StatusCode::BAD_REQUEST, ReunionResponse::failure(message));
    }

    let (frecuencia, count) = match &payload.repeticion {
        Some(r) => (r.frecuencia.as_str(), r.ocurrencias),
        None => ("none", 1),
    };
    let dates = match occurrences(fecha_inicio, fecha_fin, frecuencia, count, zona) {
        Ok(d) => d,
        Err(message) => return (StatusCode::BAD_REQUEST, ReunionResponse::failure(message)),
    };

    let invitees = match valid_invitees(
        &state.pool,
        nodo_id,
        auth_user.user_id,
        payload.invitados.as_deref(),
    )
    .await
    {
        Ok(Some(list)) => list,
        Ok(None) => {
            return (
                StatusCode::BAD_REQUEST,
                ReunionResponse::failure("Solo puedes invitar a integrantes de este nodo."),
            );
        }
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                ReunionResponse::failure("No se pudieron verificar los invitados."),
            );
        }
    };

    let serie_id = (dates.len() > 1).then(Uuid::new_v4);
    let repeticion = (frecuencia != "none").then_some(frecuencia);
    let created: Result<Vec<Uuid>, sqlx::Error> = async {
        let mut tx = state.pool.begin().await?;
        let mut ids = Vec::with_capacity(dates.len());
        for (inicio, fin) in &dates {
            let id: Uuid = sqlx::query_scalar(
                "INSERT INTO reuniones (nodo_id, titulo, descripcion, fecha_inicio, fecha_fin, enlace_reunion, creado_por, serie_id, repeticion, todo_el_dia, ubicacion)
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING id",
            )
            .bind(nodo_id)
            .bind(titulo)
            .bind(descripcion)
            .bind(inicio)
            .bind(fin)
            .bind(payload.enlace_reunion.as_deref().filter(|e| !e.trim().is_empty()))
            .bind(auth_user.user_id)
            .bind(serie_id)
            .bind(repeticion)
            .bind(payload.todo_el_dia)
            .bind(ubicacion)
            .fetch_one(&mut *tx)
            .await?;
            // El organizador asiste; los invitados quedan pendientes de responder.
            sqlx::query(
                "INSERT INTO reunion_invitados (reunion_id, user_id, respuesta)
                 SELECT $1, $2, 'aceptada'
                 UNION ALL SELECT $1, u, 'pendiente' FROM UNNEST($3::uuid[]) AS u",
            )
            .bind(id)
            .bind(auth_user.user_id)
            .bind(&invitees)
            .execute(&mut *tx)
            .await?;
            ids.push(id);
        }
        // Un solo aviso de invitación por serie, con la primera fecha.
        sqlx::query(
            "INSERT INTO notificaciones (user_id, tipo, nodo_id, reunion_id, titulo, programada_para, dedupe_key)
             SELECT u, 'invitacion', $1, $2, $3, $4, 'invitacion:' || $2 || ':' || u
             FROM UNNEST($5::uuid[]) AS u ON CONFLICT (dedupe_key) DO NOTHING",
        )
        .bind(nodo_id)
        .bind(ids[0])
        .bind(titulo)
        .bind(dates[0].0)
        .bind(&invitees)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(ids)
    }
    .await;

    match created {
        Ok(ids) => {
            let reunion = info(&state.pool, auth_user.user_id, ids[0]).await;
            (
                StatusCode::CREATED,
                Json(ReunionResponse {
                    success: true,
                    message: if ids.len() > 1 {
                        format!("Se programaron {} reuniones.", ids.len())
                    } else {
                        "Reunión programada exitosamente.".to_string()
                    },
                    reunion,
                    reuniones: None,
                    ocurrencias: Some(ids.len()),
                }),
            )
        }
        Err(e) => {
            eprintln!("Error al programar reunión: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                ReunionResponse::failure("Error interno al programar la reunión."),
            )
        }
    }
}

// ─── POST /nodos/{id}/reuniones/ahora ────────────────────────────────────

/// "Reunirse ahora": crea una reunión ya iniciada sin programarla. Cualquier
/// integrante puede hacerlo y la modera quien la crea. Con `privada`, solo
/// la ven quien llama y sus invitados (llamada directa).
pub async fn meet_now(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::Extension(hub): axum::Extension<Arc<RoomHub>>,
    Path(nodo_id): Path<Uuid>,
    Json(payload): Json<MeetNowDto>,
) -> (StatusCode, Json<ReunionResponse>) {
    match active_member(&state.pool, nodo_id, auth_user.user_id).await {
        Ok(true) => {}
        Ok(false) => {
            return (
                StatusCode::FORBIDDEN,
                ReunionResponse::failure("No perteneces a este nodo."),
            );
        }
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                ReunionResponse::failure("No se pudo verificar tu membresía."),
            );
        }
    }
    let titulo = payload
        .titulo
        .as_deref()
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .map(str::to_string);
    if titulo
        .as_deref()
        .is_some_and(|t| t.chars().count() > MAX_TITLE_CHARS)
    {
        return (
            StatusCode::BAD_REQUEST,
            ReunionResponse::failure("El título admite como máximo 120 caracteres."),
        );
    }
    if payload.privada && payload.invitados.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            ReunionResponse::failure("Una llamada privada necesita al menos un invitado."),
        );
    }
    let invitees = match valid_invitees(
        &state.pool,
        nodo_id,
        auth_user.user_id,
        Some(&payload.invitados),
    )
    .await
    {
        Ok(Some(list)) => list,
        Ok(None) => {
            return (
                StatusCode::BAD_REQUEST,
                ReunionResponse::failure("Solo puedes invitar a integrantes de este nodo."),
            );
        }
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                ReunionResponse::failure("No se pudieron verificar los invitados."),
            );
        }
    };
    let created: Result<Uuid, sqlx::Error> = async {
        let mut tx = state.pool.begin().await?;
        let id: Uuid = sqlx::query_scalar(
            "INSERT INTO reuniones (nodo_id, titulo, fecha_inicio, creado_por, rtc_estado, rtc_started_at, espontanea, privada)
             SELECT $1, COALESCE($2, 'Reunión instantánea de ' || u.name), NOW(), $3, 'active', NOW(), TRUE, $4
             FROM users u WHERE u.id = $3 RETURNING id",
        )
        .bind(nodo_id)
        .bind(&titulo)
        .bind(auth_user.user_id)
        .bind(payload.privada)
        .fetch_one(&mut *tx)
        .await?;
        sqlx::query(
            "INSERT INTO reunion_invitados (reunion_id, user_id, respuesta)
             SELECT $1, $2, 'aceptada'
             UNION ALL SELECT $1, u, 'pendiente' FROM UNNEST($3::uuid[]) AS u",
        )
        .bind(id)
        .bind(auth_user.user_id)
        .bind(&invitees)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(id)
    }
    .await;
    match created {
        Ok(id) => {
            crate::notifications::meeting_started(&state.pool, id, auth_user.user_id).await;
            hub.changed();
            (
                StatusCode::CREATED,
                Json(ReunionResponse {
                    success: true,
                    message: "Reunión iniciada.".to_string(),
                    reunion: info(&state.pool, auth_user.user_id, id).await,
                    ..Default::default()
                }),
            )
        }
        Err(e) => {
            eprintln!("Error al iniciar la reunión instantánea: {e}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                ReunionResponse::failure("No se pudo iniciar la reunión."),
            )
        }
    }
}

// ─── PUT /nodos/{id}/reuniones/{reunion_id}/respuesta ───────────────────

/// Respuesta de un invitado: asistiré, tal vez o no asistiré.
pub async fn respond(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path((nodo_id, reunion_id)): Path<(Uuid, Uuid)>,
    Json(payload): Json<RespuestaDto>,
) -> (StatusCode, Json<ReunionResponse>) {
    if !matches!(
        payload.respuesta.as_str(),
        "aceptada" | "tentativa" | "rechazada"
    ) {
        return (
            StatusCode::BAD_REQUEST,
            ReunionResponse::failure("Respuesta no válida."),
        );
    }
    match active_member(&state.pool, nodo_id, auth_user.user_id).await {
        Ok(true) => {}
        Ok(false) => {
            return (
                StatusCode::FORBIDDEN,
                ReunionResponse::failure("No perteneces a este nodo."),
            );
        }
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                ReunionResponse::failure("No se pudo registrar tu respuesta."),
            );
        }
    }
    let updated = sqlx::query(
        "UPDATE reunion_invitados i SET respuesta = $3, updated_at = NOW()
         FROM reuniones r, reuniones base
         WHERE base.id = $1 AND base.nodo_id = $4 AND i.user_id = $2 AND r.id = i.reunion_id
         AND (r.id = base.id OR ($5 AND base.serie_id IS NOT NULL AND r.serie_id = base.serie_id
              AND r.rtc_estado = 'scheduled' AND r.fecha_inicio >= base.fecha_inicio))",
    )
    .bind(reunion_id)
    .bind(auth_user.user_id)
    .bind(&payload.respuesta)
    .bind(nodo_id)
    .bind(payload.serie)
    .execute(&state.pool)
    .await;
    match updated {
        Ok(r) if r.rows_affected() > 0 => (
            StatusCode::OK,
            Json(ReunionResponse {
                success: true,
                message: "Respuesta registrada.".to_string(),
                reunion: info(&state.pool, auth_user.user_id, reunion_id).await,
                ..Default::default()
            }),
        ),
        Ok(_) => (
            StatusCode::NOT_FOUND,
            ReunionResponse::failure("No estás invitado a esta reunión."),
        ),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            ReunionResponse::failure("No se pudo registrar tu respuesta."),
        ),
    }
}

// ─── GET /nodos/{id}/reuniones ───────────────────────────────────────────

pub async fn list_reuniones(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path(nodo_id): Path<Uuid>,
) -> (StatusCode, Json<ReunionResponse>) {
    match active_member(&state.pool, nodo_id, auth_user.user_id).await {
        Ok(true) => {}
        _ => {
            return (
                StatusCode::FORBIDDEN,
                ReunionResponse::failure("No perteneces a este nodo."),
            );
        }
    }

    let rows = sqlx::query_as::<_, ReunionInfo>(sqlx::AssertSqlSafe(format!(
        "{SELECT_INFO} WHERE r.nodo_id = $2
         AND (NOT r.privada OR r.creado_por = $1 OR EXISTS (SELECT 1 FROM reunion_invitados i WHERE i.reunion_id = r.id AND i.user_id = $1))
         ORDER BY r.fecha_inicio ASC"
    )))
    .bind(auth_user.user_id)
    .bind(nodo_id)
    .fetch_all(&state.pool)
    .await;

    match rows {
        Ok(reuniones) => (
            StatusCode::OK,
            Json(ReunionResponse {
                success: true,
                message: "Reuniones listadas exitosamente.".to_string(),
                reuniones: Some(reuniones),
                ..Default::default()
            }),
        ),
        Err(e) => {
            eprintln!("Error al listar reuniones: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                ReunionResponse::failure("Error interno al cargar las reuniones."),
            )
        }
    }
}

// ─── PUT /nodos/{id}/reuniones/{reunion_id} ─────────────────────────────

/// Nuevo horario de la reunión editada, o `None` si no cambia. Con todo el
/// día, va de medianoche a medianoche local; si solo cambia el inicio, se
/// conserva la duración.
pub(crate) fn reschedule(
    base: Occurrence,
    base_all_day: bool,
    start: Option<DateTime<Utc>>,
    end: Option<DateTime<Utc>>,
    all_day: Option<bool>,
    offset_minutes: i32,
) -> Option<Occurrence> {
    if start.is_none() && end.is_none() && all_day.is_none() {
        return None;
    }
    let new_start = start.unwrap_or(base.0);
    if all_day.unwrap_or(base_all_day) {
        let (inicio, fin) = all_day_bounds(new_start, offset_minutes);
        return Some((inicio, Some(fin)));
    }
    let new_end = end.or_else(|| base.1.map(|fin| new_start + (fin - base.0)));
    Some((new_start, new_end))
}

fn seconds(d: Duration) -> f64 {
    d.num_milliseconds() as f64 / 1000.0
}

/// Edita una reunión o, con `alcance`, la serie a la que pertenece. Solo
/// quien la creó o un OWNER/ADMIN del nodo (en las privadas, solo quien la
/// creó) puede hacerlo.
pub async fn update_reunion(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path((nodo_id, reunion_id)): Path<(Uuid, Uuid)>,
    Json(payload): Json<UpdateReunionDto>,
) -> (StatusCode, Json<ReunionResponse>) {
    let bad = |message: &str| (StatusCode::BAD_REQUEST, ReunionResponse::failure(message));
    let is_creator_or_admin = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(
            SELECT 1 FROM reuniones r
            JOIN nodo_miembros nm ON nm.nodo_id = r.nodo_id AND nm.user_id = $2
            WHERE r.id = $1 AND r.nodo_id = $3
            AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = r.nodo_id AND b.user_id = $2)
            AND (r.creado_por = $2 OR (nm.rol IN ('ADMIN', 'OWNER', 'MODERATOR') AND NOT r.privada))
        )",
    )
    .bind(reunion_id)
    .bind(auth_user.user_id)
    .bind(nodo_id)
    .fetch_one(&state.pool)
    .await
    .unwrap_or(false);

    if !is_creator_or_admin {
        return (
            StatusCode::FORBIDDEN,
            ReunionResponse::failure("No tienes permiso para modificar esta reunión."),
        );
    }

    type BaseRow = (DateTime<Utc>, Option<DateTime<Utc>>, bool, Uuid, bool);
    let base: Result<Option<BaseRow>, sqlx::Error> = sqlx::query_as(
        "SELECT fecha_inicio, fecha_fin, todo_el_dia, creado_por, privada
         FROM reuniones WHERE id = $1 AND nodo_id = $2",
    )
    .bind(reunion_id)
    .bind(nodo_id)
    .fetch_optional(&state.pool)
    .await;
    let (base_inicio, base_fin, base_todo, organizer, privada) = match base {
        Ok(Some(row)) => row,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                ReunionResponse::failure("Reunión no encontrada."),
            );
        }
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                ReunionResponse::failure("No se pudo cargar la reunión."),
            );
        }
    };

    let alcance = match edit_scope(payload.alcance.as_deref()) {
        Ok(a) => a,
        Err(message) => return bad(message),
    };
    let ubicacion = match clean_location(payload.ubicacion.as_deref()) {
        Ok(l) => l,
        Err(message) => return bad(message),
    };
    let zona = payload.zona_minutos.unwrap_or(0);
    if !valid_offset(zona) {
        return bad("Zona horaria inválida.");
    }
    let titulo = payload.titulo.as_deref().map(str::trim);
    let descripcion = payload.descripcion.as_deref().map(str::trim);
    let schedule = reschedule(
        (base_inicio, base_fin),
        base_todo,
        payload.fecha_inicio,
        payload.fecha_fin,
        payload.todo_el_dia,
        zona,
    );
    let invalid = if titulo.is_some_and(str::is_empty) {
        Some("El título de la reunión no puede estar vacío.")
    } else if titulo.is_some_and(|t| t.chars().count() > MAX_TITLE_CHARS) {
        Some("El título admite como máximo 120 caracteres.")
    } else if descripcion.is_some_and(|d| d.chars().count() > MAX_DESCRIPTION_CHARS) {
        Some("La descripción admite como máximo 2000 caracteres.")
    } else if matches!(schedule, Some((ini, Some(fin))) if fin < ini) {
        Some("La reunión no puede terminar antes de empezar.")
    } else if matches!(schedule, Some((ini, Some(fin))) if fin - ini > Duration::hours(24)) {
        Some("Una reunión no puede durar más de 24 horas.")
    } else {
        None
    };
    if let Some(message) = invalid {
        return bad(message);
    }

    let invitees = match &payload.invitados {
        None => None,
        Some(list) => match valid_invitees(&state.pool, nodo_id, organizer, Some(list)).await {
            Ok(Some(chosen)) if privada && chosen.is_empty() => {
                return bad("Una llamada privada necesita al menos un invitado.");
            }
            Ok(Some(chosen)) => Some(chosen),
            Ok(None) => return bad("Solo puedes invitar a integrantes de este nodo."),
            Err(_) => {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    ReunionResponse::failure("No se pudieron verificar los invitados."),
                );
            }
        },
    };

    // El cambio de hora es un desplazamiento: cada reunión programada de la
    // serie conserva su día relativo y todas toman la nueva duración.
    let delta = schedule.map_or(0.0, |(ini, _)| seconds(ini - base_inicio));
    let duration = schedule.and_then(|(ini, fin)| fin.map(|f| seconds(f - ini)));
    let updated: Result<Vec<Uuid>, sqlx::Error> = async {
        let mut tx = state.pool.begin().await?;
        let ids: Vec<Uuid> = sqlx::query_scalar(
            "WITH base AS (SELECT id, serie_id, fecha_inicio FROM reuniones WHERE id = $1 AND nodo_id = $2)
             UPDATE reuniones r
             SET titulo = COALESCE($4, r.titulo),
                 descripcion = CASE WHEN $5::text IS NULL THEN r.descripcion ELSE NULLIF($5, '') END,
                 ubicacion = CASE WHEN $6::text IS NULL THEN r.ubicacion ELSE NULLIF($6, '') END,
                 enlace_reunion = COALESCE($7, r.enlace_reunion),
                 todo_el_dia = COALESCE($8, r.todo_el_dia),
                 fecha_inicio = CASE WHEN $9 THEN r.fecha_inicio + make_interval(secs => $10) ELSE r.fecha_inicio END,
                 fecha_fin = CASE WHEN NOT $9 THEN r.fecha_fin
                                  WHEN $11::float8 IS NULL THEN NULL
                                  ELSE r.fecha_inicio + make_interval(secs => $10 + $11) END
             FROM base
             WHERE r.nodo_id = $2 AND (
                 (r.id = base.id AND ($3 = 'una' OR r.rtc_estado = 'scheduled'))
                 OR ($3 <> 'una' AND base.serie_id IS NOT NULL AND r.serie_id = base.serie_id
                     AND r.id <> base.id AND r.rtc_estado = 'scheduled'
                     AND ($3 = 'serie' OR r.fecha_inicio >= base.fecha_inicio)))
             RETURNING r.id",
        )
        .bind(reunion_id)
        .bind(nodo_id)
        .bind(alcance)
        .bind(titulo)
        .bind(descripcion)
        .bind(ubicacion)
        .bind(&payload.enlace_reunion)
        .bind(schedule.map(|_| payload.todo_el_dia.unwrap_or(base_todo)))
        .bind(schedule.is_some())
        .bind(delta)
        .bind(duration)
        .fetch_all(&mut *tx)
        .await?;
        if let (Some(chosen), false) = (&invitees, ids.is_empty()) {
            sqlx::query(
                "DELETE FROM reunion_invitados i USING reuniones r
                 WHERE r.id = i.reunion_id AND i.reunion_id = ANY($1)
                 AND i.user_id <> r.creado_por AND NOT (i.user_id = ANY($2))",
            )
            .bind(&ids)
            .bind(chosen)
            .execute(&mut *tx)
            .await?;
            let mut added: Vec<Uuid> = sqlx::query_scalar(
                "INSERT INTO reunion_invitados (reunion_id, user_id, respuesta)
                 SELECT m, u, 'pendiente' FROM UNNEST($1::uuid[]) AS m, UNNEST($2::uuid[]) AS u
                 ON CONFLICT (reunion_id, user_id) DO NOTHING RETURNING user_id",
            )
            .bind(&ids)
            .bind(chosen)
            .fetch_all(&mut *tx)
            .await?;
            added.sort();
            added.dedup();
            // Quien se suma recibe un aviso de invitación.
            sqlx::query(
                "INSERT INTO notificaciones (user_id, tipo, nodo_id, reunion_id, titulo, programada_para, dedupe_key)
                 SELECT u, 'invitacion', r.nodo_id, r.id, r.titulo, r.fecha_inicio, 'invitacion:' || r.id || ':' || u
                 FROM reuniones r, UNNEST($2::uuid[]) AS u WHERE r.id = $1
                 ON CONFLICT (dedupe_key) DO NOTHING",
            )
            .bind(ids[0])
            .bind(&added)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(ids)
    }
    .await;

    match updated {
        Ok(ids) if ids.is_empty() => (
            StatusCode::CONFLICT,
            ReunionResponse::failure("No hay reuniones programadas que cambiar."),
        ),
        Ok(ids) => (
            StatusCode::OK,
            Json(ReunionResponse {
                success: true,
                message: if ids.len() > 1 {
                    format!("Se actualizaron {} reuniones.", ids.len())
                } else {
                    "Reunión actualizada exitosamente.".to_string()
                },
                reunion: info(&state.pool, auth_user.user_id, reunion_id).await,
                ocurrencias: Some(ids.len()),
                ..Default::default()
            }),
        ),
        Err(e) => {
            eprintln!("Error al actualizar reunión: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                ReunionResponse::failure("Error interno al actualizar la reunión."),
            )
        }
    }
}

// ─── GET /nodos/{id}/disponibilidad ──────────────────────────────────────

/// Asistente de programación: intervalos ocupados de personas del nodo, de
/// cualquier nodo, pero solo horas (nunca títulos ni otros datos). Cuenta
/// cada reunión programada o en curso que organizan o a la que están
/// invitadas sin haberla rechazado.
pub async fn availability(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path(nodo_id): Path<Uuid>,
    Query(query): Query<AvailabilityQuery>,
) -> (StatusCode, Json<DisponibilidadResponse>) {
    if query.hasta <= query.desde
        || query.hasta - query.desde > Duration::days(MAX_AVAILABILITY_DAYS)
    {
        return (
            StatusCode::BAD_REQUEST,
            DisponibilidadResponse::failure("El intervalo debe ser positivo y no superar 14 días."),
        );
    }
    let users = match parse_users(&query.usuarios) {
        Ok(u) => u,
        Err(message) => {
            return (
                StatusCode::BAD_REQUEST,
                DisponibilidadResponse::failure(message),
            );
        }
    };
    match active_member(&state.pool, nodo_id, auth_user.user_id).await {
        Ok(true) => {}
        Ok(false) => {
            return (
                StatusCode::FORBIDDEN,
                DisponibilidadResponse::failure("No perteneces a este nodo."),
            );
        }
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                DisponibilidadResponse::failure("No se pudo verificar tu membresía."),
            );
        }
    }
    let members = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM nodo_miembros nm JOIN users u ON u.id = nm.user_id AND u.estado = 'ACTIVE'
         WHERE nm.nodo_id = $1 AND nm.user_id = ANY($2)
         AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = $1 AND b.user_id = nm.user_id)",
    )
    .bind(nodo_id)
    .bind(&users)
    .fetch_one(&state.pool)
    .await;
    match members {
        Ok(n) if n == users.len() as i64 => {}
        Ok(_) => {
            return (
                StatusCode::FORBIDDEN,
                DisponibilidadResponse::failure(
                    "Solo puedes consultar la disponibilidad de integrantes de este nodo.",
                ),
            );
        }
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                DisponibilidadResponse::failure("No se pudo consultar la disponibilidad."),
            );
        }
    }
    // Sin fin, una reunión ocupa 30 minutos; una en curso, al menos hasta ahora.
    // Los eventos de todo el día no cuentan como ocupado.
    // La reunión que se edita solo se excluye si quien consulta puede verla.
    type BusyRow = (Uuid, DateTime<Utc>, DateTime<Utc>);
    let rows: Result<Vec<BusyRow>, sqlx::Error> = sqlx::query_as(
        "SELECT user_id, inicio, fin FROM (
            SELECT p.u AS user_id, r.fecha_inicio AS inicio,
                   CASE WHEN r.rtc_estado = 'active'
                        THEN GREATEST(COALESCE(r.fecha_fin, r.fecha_inicio + INTERVAL '30 minutes'), NOW())
                        ELSE COALESCE(r.fecha_fin, r.fecha_inicio + INTERVAL '30 minutes') END AS fin
            FROM UNNEST($1::uuid[]) AS p(u)
            JOIN reuniones r ON r.rtc_estado IN ('scheduled', 'active')
            JOIN nodos n ON n.id = r.nodo_id AND n.estado = 'active'
            WHERE r.fecha_inicio < $3
              -- Como en Teams, un evento de todo el día (entrega, feriado) se
              -- muestra en la agenda pero no ocupa a la persona todo el día.
              AND NOT r.todo_el_dia
              AND (r.fecha_inicio > $2 - INTERVAL '25 hours' OR r.rtc_estado = 'active')
              AND (r.creado_por = p.u OR EXISTS (SELECT 1 FROM reunion_invitados i
                   WHERE i.reunion_id = r.id AND i.user_id = p.u AND i.respuesta <> 'rechazada'))
              AND EXISTS (SELECT 1 FROM nodo_miembros m WHERE m.nodo_id = r.nodo_id AND m.user_id = p.u)
              AND NOT (r.id IS NOT DISTINCT FROM $4::uuid AND r.nodo_id = $5
                   AND (NOT r.privada OR r.creado_por = $6 OR EXISTS (SELECT 1 FROM reunion_invitados i
                        WHERE i.reunion_id = r.id AND i.user_id = $6)))
         ) ocupado WHERE fin > $2",
    )
    .bind(&users)
    .bind(query.desde)
    .bind(query.hasta)
    .bind(query.excluir)
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_all(&state.pool)
    .await;
    let rows = match rows {
        Ok(r) => r,
        Err(e) => {
            eprintln!("Error al consultar disponibilidad: {e}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                DisponibilidadResponse::failure("No se pudo consultar la disponibilidad."),
            );
        }
    };
    let usuarios = users
        .iter()
        .map(|user| Disponibilidad {
            user_id: *user,
            ocupado: merge_intervals(
                rows.iter()
                    .filter(|(u, _, _)| u == user)
                    .map(|(_, inicio, fin)| Intervalo {
                        inicio: (*inicio).max(query.desde),
                        fin: (*fin).min(query.hasta),
                    })
                    .collect(),
            ),
        })
        .collect();
    (
        StatusCode::OK,
        Json(DisponibilidadResponse {
            success: true,
            message: "Disponibilidad consultada.".to_string(),
            usuarios: Some(usuarios),
        }),
    )
}

// ─── DELETE /nodos/{id}/reuniones/{reunion_id}(?serie=true) ─────────────

pub async fn delete_reunion(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path((nodo_id, reunion_id)): Path<(Uuid, Uuid)>,
    Query(query): Query<DeleteQuery>,
) -> (StatusCode, Json<ReunionResponse>) {
    let serie = query.serie;
    let is_creator_or_admin = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(
            SELECT 1 FROM reuniones r
            JOIN nodo_miembros nm ON nm.nodo_id = r.nodo_id AND nm.user_id = $2
            WHERE r.id = $1 AND r.nodo_id = $3
            AND NOT EXISTS (SELECT 1 FROM nodo_baneos b WHERE b.nodo_id = r.nodo_id AND b.user_id = $2)
            AND (r.creado_por = $2 OR (nm.rol IN ('ADMIN', 'OWNER', 'MODERATOR') AND NOT r.privada))
        )",
    )
    .bind(reunion_id)
    .bind(auth_user.user_id)
    .bind(nodo_id)
    .fetch_one(&state.pool)
    .await
    .unwrap_or(false);

    if !is_creator_or_admin {
        return (
            StatusCode::FORBIDDEN,
            ReunionResponse::failure("No tienes permiso para cancelar esta reunión."),
        );
    }

    // Con `serie`, se cancelan también las demás reuniones aún programadas de
    // la serie; las ya celebradas se conservan por su asistencia.
    let result = sqlx::query(
        "DELETE FROM reuniones r USING reuniones base
         WHERE base.id = $1 AND base.nodo_id = $2 AND r.nodo_id = $2
         AND (r.id = base.id OR ($3 AND base.serie_id IS NOT NULL
              AND r.serie_id = base.serie_id AND r.rtc_estado = 'scheduled'))",
    )
    .bind(reunion_id)
    .bind(nodo_id)
    .bind(serie)
    .execute(&state.pool)
    .await;

    match result {
        Ok(r) => {
            if r.rows_affected() == 0 {
                (
                    StatusCode::NOT_FOUND,
                    ReunionResponse::failure("Reunión no encontrada."),
                )
            } else {
                (
                    StatusCode::OK,
                    Json(ReunionResponse {
                        success: true,
                        message: if r.rows_affected() > 1 {
                            format!("Se cancelaron {} reuniones.", r.rows_affected())
                        } else {
                            "Reunión cancelada exitosamente.".to_string()
                        },
                        ocurrencias: Some(r.rows_affected() as usize),
                        ..Default::default()
                    }),
                )
            }
        }
        Err(e) => {
            eprintln!("Error al eliminar reunión: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                ReunionResponse::failure("Error interno al cancelar la reunión."),
            )
        }
    }
}

crate::response::failure_response!(ReunionResponse, DisponibilidadResponse);

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(y: i32, m: u32, d: u32, h: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(y, m, d, h, 0, 0).unwrap()
    }

    #[test]
    fn recurrences_keep_local_time_and_duration() {
        // Viernes 2 oct 2026 a las 18:00 en El Salvador (UTC−6) = 00:00 UTC del sábado.
        let start = at(2026, 10, 3, 0);
        let end = Some(start + Duration::minutes(45));
        let weekdays = occurrences(start, end, "weekdays", 3, -360).unwrap();
        // Viernes, lunes y martes locales: el fin de semana local se salta.
        assert_eq!(
            weekdays.iter().map(|(s, _)| *s).collect::<Vec<_>>(),
            vec![start, at(2026, 10, 6, 0), at(2026, 10, 7, 0)]
        );
        assert!(
            weekdays
                .iter()
                .all(|(s, e)| *e == Some(*s + Duration::minutes(45)))
        );
        let weekly = occurrences(start, None, "biweekly", 2, 0).unwrap();
        assert_eq!(weekly[1].0, start + Duration::days(14));
        // 31 de enero → 28 de febrero (fin de mes), sin saltar meses.
        let monthly = occurrences(at(2027, 1, 31, 15), None, "monthly", 3, -360).unwrap();
        assert_eq!(monthly[1].0, at(2027, 2, 28, 15));
        assert_eq!(monthly[2].0, at(2027, 3, 31, 15));
    }

    #[test]
    fn all_day_events_span_the_local_day() {
        // 2 oct 2026 a las 23:30 en UTC−6 = 05:30 UTC del 3 de octubre.
        let late = Utc.with_ymd_and_hms(2026, 10, 3, 5, 30, 0).unwrap();
        let (start, end) = all_day_bounds(late, -360);
        // Medianoche local del 2 de octubre = 06:00 UTC.
        assert_eq!(start, at(2026, 10, 2, 6));
        assert_eq!(end, at(2026, 10, 3, 6));
        assert_eq!(all_day_bounds(at(2026, 10, 2, 15), 0).0, at(2026, 10, 2, 0));
    }

    #[test]
    fn rescheduling_keeps_duration_and_all_day() {
        let base = (at(2026, 10, 5, 15), Some(at(2026, 10, 5, 16)));
        assert_eq!(reschedule(base, false, None, None, None, 0), None);
        // Solo cambia el inicio: se conserva la hora de duración.
        assert_eq!(
            reschedule(base, false, Some(at(2026, 10, 5, 17)), None, None, 0),
            Some((at(2026, 10, 5, 17), Some(at(2026, 10, 5, 18))))
        );
        assert_eq!(
            reschedule(
                base,
                false,
                None,
                Some(at(2026, 10, 5, 15) + Duration::minutes(30)),
                None,
                0
            ),
            Some((
                at(2026, 10, 5, 15),
                Some(at(2026, 10, 5, 15) + Duration::minutes(30))
            ))
        );
        // Pasar a todo el día: de medianoche a medianoche local (UTC−6).
        assert_eq!(
            reschedule(base, false, None, None, Some(true), -360),
            Some((at(2026, 10, 5, 6), Some(at(2026, 10, 6, 6))))
        );
    }

    #[test]
    fn edit_inputs_are_validated() {
        assert_eq!(edit_scope(None), Ok("una"));
        assert_eq!(edit_scope(Some("siguientes")), Ok("siguientes"));
        assert_eq!(edit_scope(Some("serie")), Ok("serie"));
        assert!(edit_scope(Some("todas")).is_err());
        assert_eq!(clean_location(Some("  Sala 2 ")), Ok(Some("Sala 2")));
        assert_eq!(clean_location(Some("")), Ok(Some("")));
        assert_eq!(clean_location(None), Ok(None));
        assert!(clean_location(Some(&"x".repeat(201))).is_err());
        assert!(clean_location(Some(&"á".repeat(200))).is_ok());
    }

    #[test]
    fn availability_users_and_intervals() {
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        assert_eq!(parse_users(&format!("{a}, {b},{a},")), Ok(vec![a, b]));
        assert!(parse_users("").is_err());
        assert!(parse_users("no-es-uuid").is_err());
        let many = (0..21)
            .map(|_| Uuid::new_v4().to_string())
            .collect::<Vec<_>>();
        assert!(parse_users(&many.join(",")).is_err());
        let iv = |s: u32, e: u32| Intervalo {
            inicio: at(2026, 10, 5, s),
            fin: at(2026, 10, 5, e),
        };
        // Solapados y contiguos se unen; los separados no.
        assert_eq!(
            merge_intervals(vec![iv(14, 15), iv(9, 11), iv(10, 12), iv(12, 13)]),
            vec![iv(9, 13), iv(14, 15)]
        );
        assert!(merge_intervals(vec![]).is_empty());
    }

    #[test]
    fn invalid_recurrences_are_rejected() {
        let start = at(2026, 10, 3, 0);
        assert!(occurrences(start, None, "weekly", 0, 0).is_err());
        assert!(occurrences(start, None, "weekly", 53, 0).is_err());
        assert!(occurrences(start, None, "hourly", 2, 0).is_err());
        assert!(occurrences(start, None, "none", 2, 0).is_err());
        assert!(occurrences(start, None, "daily", 2, 15 * 60).is_err());
        assert_eq!(occurrences(start, None, "none", 1, 0).unwrap().len(), 1);
    }
}
