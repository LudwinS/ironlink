//! Sprint 4 (IRL-SEC-US-01/02): registro automático de asistencia y tiempo de
//! participación. Solo el servidor RTC escribe filas, al admitir y al cerrar
//! cada WebSocket; los clientes no pueden declarar su propia asistencia.
use crate::auth::{middleware::AuthUser, verification::AppState};
use crate::rtc::server::can_manage;
use axum::{
    Extension, Json,
    extract::{Path, State},
    http::{StatusCode, header},
    response::{IntoResponse, Response},
};
use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::json;
use sqlx::PgPool;
use std::collections::BTreeMap;
use uuid::Uuid;

/// Motivo de salida guardado con cada sesión.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Exit {
    Left,
    Lost,
    Kicked,
    Replaced,
    Unauthorized,
    SessionLimit,
}

impl Exit {
    fn code(self) -> &'static str {
        match self {
            Exit::Left => "salio",
            Exit::Lost => "conexion_perdida",
            Exit::Kicked => "expulsado",
            Exit::Replaced => "reemplazada",
            Exit::Unauthorized => "sin_autorizacion",
            Exit::SessionLimit => "limite_sesion",
        }
    }
}

/// Abre la sesión de una conexión admitida en la sala.
pub async fn open(pool: &PgPool, room: Uuid, user: Uuid, connection: Uuid, sala: Option<Uuid>) {
    if let Err(e) = sqlx::query(
        "INSERT INTO reunion_asistencia (reunion_id, user_id, connection_id, sala_id) VALUES ($1, $2, $3, $4)",
    )
    .bind(room)
    .bind(user)
    .bind(connection)
    .bind(sala)
    .execute(pool)
    .await
    {
        // La llamada no se bloquea por el registro, pero el fallo queda en el log.
        eprintln!("Asistencia: no se pudo registrar la entrada: {e}");
    }
}

/// Latido: deja constancia de que la conexión seguía activa.
pub async fn touch(pool: &PgPool, connection: Uuid) {
    let _ = sqlx::query(
        "UPDATE reunion_asistencia SET last_seen_at = NOW()
         WHERE connection_id = $1 AND left_at IS NULL",
    )
    .bind(connection)
    .execute(pool)
    .await;
}

/// Cierra la sesión. No sobrescribe un cierre previo (p. ej. fin de reunión).
pub async fn close(pool: &PgPool, connection: Uuid, exit: Exit) {
    if let Err(e) = sqlx::query(
        "UPDATE reunion_asistencia SET left_at = GREATEST(NOW(), joined_at), last_seen_at = NOW(), salida = $2
         WHERE connection_id = $1 AND left_at IS NULL",
    )
    .bind(connection)
    .bind(exit.code())
    .execute(pool)
    .await
    {
        eprintln!("Asistencia: no se pudo registrar la salida: {e}");
    }
}

/// Al finalizar la reunión se cierran todas sus sesiones a la misma hora.
pub async fn close_meeting(pool: &PgPool, room: Uuid) {
    let _ = sqlx::query(
        "UPDATE reunion_asistencia SET left_at = GREATEST(NOW(), joined_at), salida = 'reunion_finalizada'
         WHERE reunion_id = $1 AND left_at IS NULL",
    )
    .bind(room)
    .execute(pool)
    .await;
}

/// Al arrancar, ninguna conexión sigue viva: las sesiones abiertas se cierran
/// con su último latido, la hora real hasta la que hubo evidencia.
pub async fn recover(pool: &PgPool) -> Result<u64, sqlx::Error> {
    Ok(sqlx::query(
        "UPDATE reunion_asistencia SET left_at = last_seen_at, salida = 'servidor_reiniciado'
         WHERE left_at IS NULL",
    )
    .execute(pool)
    .await?
    .rows_affected())
}

#[derive(sqlx::FromRow)]
struct Row {
    user_id: Uuid,
    nombre: String,
    correo: String,
    joined_at: DateTime<Utc>,
    left_at: Option<DateTime<Utc>>,
    salida: Option<String>,
    hasta: DateTime<Utc>,
    sala: Option<String>,
}

#[derive(Serialize, Debug)]
pub struct Session {
    user_id: Uuid,
    nombre: String,
    correo: String,
    joined_at: DateTime<Utc>,
    left_at: Option<DateTime<Utc>>,
    salida: Option<String>,
    segundos: i64,
    /// Sala de trabajo de la conexión; `None` es la sala principal.
    sala: Option<String>,
}

#[derive(Serialize, Debug)]
pub struct Participant {
    user_id: Uuid,
    nombre: String,
    correo: String,
    sesiones: usize,
    primera_entrada: DateTime<Utc>,
    ultima_salida: Option<DateTime<Utc>>,
    conectado_ahora: bool,
    /// Unión de sus intervalos: reconectarse o entrar desde dos dispositivos
    /// no cuenta dos veces el mismo tiempo.
    segundos_conectado: i64,
    /// Porcentaje de la duración real de la reunión, si ya empezó.
    porcentaje: Option<f64>,
}

#[derive(Serialize, Debug)]
pub struct Report {
    reunion_id: Uuid,
    titulo: String,
    estado: String,
    inicio: Option<DateTime<Utc>>,
    fin: Option<DateTime<Utc>>,
    duracion_segundos: Option<i64>,
    participantes: Vec<Participant>,
    sesiones: Vec<Session>,
}

/// Suma la unión de intervalos `[inicio, fin)`.
fn union_seconds(mut spans: Vec<(DateTime<Utc>, DateTime<Utc>)>) -> i64 {
    spans.sort();
    let mut total = 0;
    let mut current: Option<(DateTime<Utc>, DateTime<Utc>)> = None;
    for (start, end) in spans {
        match current {
            Some((s, e)) if start <= e => current = Some((s, e.max(end))),
            Some((s, e)) => {
                total += (e - s).num_seconds();
                current = Some((start, end));
            }
            None => current = Some((start, end)),
        }
    }
    if let Some((s, e)) = current {
        total += (e - s).num_seconds();
    }
    total.max(0)
}

pub async fn report(pool: &PgPool, room: Uuid) -> Result<Option<Report>, sqlx::Error> {
    let meeting = sqlx::query_as::<_, (String, String, Option<DateTime<Utc>>, Option<DateTime<Utc>>, DateTime<Utc>)>(
        "SELECT titulo, rtc_estado, rtc_started_at, rtc_ended_at, NOW() FROM reuniones WHERE id = $1",
    )
    .bind(room)
    .fetch_optional(pool)
    .await?;
    let Some((titulo, estado, inicio, fin, now)) = meeting else {
        return Ok(None);
    };
    let rows = sqlx::query_as::<_, Row>(
        "SELECT a.user_id, u.name AS nombre, u.email AS correo, a.joined_at, a.left_at, a.salida,
                COALESCE(a.left_at, NOW()) AS hasta, s.nombre AS sala
         FROM reunion_asistencia a JOIN users u ON u.id = a.user_id
         LEFT JOIN reunion_salas s ON s.id = a.sala_id
         WHERE a.reunion_id = $1 ORDER BY a.joined_at, a.id",
    )
    .bind(room)
    .fetch_all(pool)
    .await?;
    let duration = inicio.map(|s| (fin.unwrap_or(now) - s).num_seconds().max(0));
    let mut by_user: BTreeMap<Uuid, Vec<&Row>> = BTreeMap::new();
    for row in &rows {
        by_user.entry(row.user_id).or_default().push(row);
    }
    let mut participantes: Vec<Participant> = by_user
        .into_values()
        .map(|own| {
            let first = own[0];
            let seconds = union_seconds(own.iter().map(|r| (r.joined_at, r.hasta)).collect());
            let open = own.iter().any(|r| r.left_at.is_none());
            Participant {
                user_id: first.user_id,
                nombre: first.nombre.clone(),
                correo: first.correo.clone(),
                sesiones: own.len(),
                primera_entrada: own.iter().map(|r| r.joined_at).min().unwrap(),
                ultima_salida: if open {
                    None
                } else {
                    own.iter().filter_map(|r| r.left_at).max()
                },
                conectado_ahora: open,
                segundos_conectado: seconds,
                porcentaje: duration
                    .filter(|d| *d > 0)
                    .map(|d| ((seconds as f64 / d as f64) * 1000.0).round().min(1000.0) / 10.0),
            }
        })
        .collect();
    participantes.sort_by(|a, b| {
        b.segundos_conectado
            .cmp(&a.segundos_conectado)
            .then_with(|| a.nombre.cmp(&b.nombre))
    });
    let sesiones = rows
        .into_iter()
        .map(|r| Session {
            segundos: (r.hasta - r.joined_at).num_seconds().max(0),
            user_id: r.user_id,
            nombre: r.nombre,
            correo: r.correo,
            joined_at: r.joined_at,
            left_at: r.left_at,
            salida: r.salida,
            sala: r.sala,
        })
        .collect();
    Ok(Some(Report {
        reunion_id: room,
        titulo,
        estado,
        inicio,
        fin,
        duracion_segundos: duration,
        participantes,
        sesiones,
    }))
}

/// Campo CSV entre comillas. Un valor que empieza por = + - @ o un control se
/// prefija con ' para que una hoja de cálculo no lo ejecute como fórmula.
fn csv_field(value: &str) -> String {
    let safe = if value.starts_with(['=', '+', '-', '@', '\t', '\r']) {
        format!("'{value}")
    } else {
        value.to_string()
    };
    format!("\"{}\"", safe.replace('"', "\"\""))
}

pub fn to_csv(report: &Report) -> String {
    let totals: BTreeMap<Uuid, i64> = report
        .participantes
        .iter()
        .map(|p| (p.user_id, p.segundos_conectado))
        .collect();
    let mut out = String::from(
        "nombre,correo,sala,entrada_utc,salida_utc,duracion_sesion_segundos,motivo_salida,total_participante_segundos\r\n",
    );
    for s in &report.sesiones {
        let row = [
            csv_field(&s.nombre),
            csv_field(&s.correo),
            csv_field(s.sala.as_deref().unwrap_or("Principal")),
            csv_field(&s.joined_at.to_rfc3339()),
            csv_field(&s.left_at.map(|t| t.to_rfc3339()).unwrap_or_default()),
            csv_field(&s.segundos.to_string()),
            csv_field(s.salida.as_deref().unwrap_or("conectado")),
            csv_field(&totals.get(&s.user_id).copied().unwrap_or(0).to_string()),
        ];
        out.push_str(&row.join(","));
        out.push_str("\r\n");
    }
    out
}

async fn authorized_report(
    state: &AppState,
    user: Uuid,
    node: Uuid,
    room: Uuid,
) -> Result<Report, (StatusCode, &'static str)> {
    match can_manage(&state.pool, node, room, user).await {
        Ok(true) => {}
        // Igual que el calendario: no se revela si la reunión existe.
        Ok(false) => {
            return Err((
                StatusCode::NOT_FOUND,
                "La reunión no existe o no puedes ver su asistencia.",
            ));
        }
        Err(_) => {
            return Err((
                StatusCode::SERVICE_UNAVAILABLE,
                "No se pudo cargar la asistencia.",
            ));
        }
    }
    match report(&state.pool, room).await {
        Ok(Some(report)) => Ok(report),
        Ok(None) => Err((
            StatusCode::NOT_FOUND,
            "La reunión no existe o no puedes ver su asistencia.",
        )),
        Err(_) => Err((
            StatusCode::SERVICE_UNAVAILABLE,
            "No se pudo cargar la asistencia.",
        )),
    }
}

/// `GET /nodos/{id}/reuniones/{reunion_id}/asistencia` — solo moderadores.
pub async fn get_report(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Path((node, room)): Path<(Uuid, Uuid)>,
) -> Response {
    match authorized_report(&state, user.user_id, node, room).await {
        Ok(report) => (StatusCode::OK, Json(json!({ "asistencia": report }))).into_response(),
        Err((status, message)) => (status, Json(json!({ "message": message }))).into_response(),
    }
}

/// `GET /nodos/{id}/reuniones/{reunion_id}/asistencia.csv` — solo moderadores.
pub async fn get_csv(
    State(state): State<AppState>,
    Extension(user): Extension<AuthUser>,
    Path((node, room)): Path<(Uuid, Uuid)>,
) -> Response {
    match authorized_report(&state, user.user_id, node, room).await {
        Ok(report) => (
            StatusCode::OK,
            [
                (header::CONTENT_TYPE, "text/csv; charset=utf-8"),
                (
                    header::CONTENT_DISPOSITION,
                    "attachment; filename=\"asistencia.csv\"",
                ),
                (header::CACHE_CONTROL, "no-store"),
            ],
            // BOM para que Excel abra bien los acentos.
            format!("\u{feff}{}", to_csv(&report)),
        )
            .into_response(),
        Err((status, message)) => (status, Json(json!({ "message": message }))).into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn at(minutes: i64) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-10-01T15:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
            + Duration::minutes(minutes)
    }

    #[test]
    fn overlapping_and_repeated_sessions_count_once() {
        assert_eq!(union_seconds(vec![]), 0);
        // Dos dispositivos a la vez y una reconexión posterior.
        let spans = vec![(at(0), at(10)), (at(5), at(12)), (at(20), at(25))];
        assert_eq!(union_seconds(spans), (12 + 5) * 60);
        // Intervalos contiguos se unen sin hueco.
        assert_eq!(union_seconds(vec![(at(0), at(5)), (at(5), at(9))]), 9 * 60);
    }

    #[test]
    fn csv_fields_are_quoted_and_neutralize_formulas() {
        assert_eq!(csv_field("Ana \"Ana\" Rivas"), "\"Ana \"\"Ana\"\" Rivas\"");
        assert_eq!(csv_field("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"");
        assert_eq!(csv_field("+503 7000"), "\"'+503 7000\"");
        assert_eq!(csv_field("ana@ironlink.dev"), "\"ana@ironlink.dev\"");
    }

    #[tokio::test]
    #[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
    async fn attendance_is_recorded_closed_and_recovered() {
        let pool = PgPool::connect(&std::env::var("IRONLINK_TEST_DATABASE_URL").unwrap())
            .await
            .unwrap();
        for file in [
            include_str!("../migrations/001_sprint1_complete.sql"),
            include_str!("../migrations/002_sprint2_fixes.sql"),
            include_str!("../migrations/003_sprint3_rtc.sql"),
            include_str!("../migrations/005_rtc_moderation.sql"),
            include_str!("../migrations/008_attendance.sql"),
            include_str!("../migrations/010_breakout_rooms.sql"),
        ] {
            sqlx::raw_sql(sqlx::AssertSqlSafe(file))
                .execute(&pool)
                .await
                .unwrap();
        }
        let (owner, ana, beto) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
        for (id, name) in [(owner, "Owner"), (ana, "=Ana"), (beto, "Beto")] {
            sqlx::query("INSERT INTO users(id,name,email,password,telefono,estado) VALUES($1,$2,$3,'test-only',$4,'ACTIVE')")
                .bind(id).bind(name).bind(format!("{id}@example.invalid")).bind(id.to_string())
                .execute(&pool).await.unwrap();
        }
        let node = Uuid::new_v4();
        sqlx::query(
            "INSERT INTO nodos(id,nombre,token_acceso,creador_id) VALUES($1,'Asistencia',$2,$3)",
        )
        .bind(node)
        .bind(node.to_string()[..32].to_string())
        .bind(owner)
        .execute(&pool)
        .await
        .unwrap();
        let room = Uuid::new_v4();
        sqlx::query("INSERT INTO reuniones(id,nodo_id,titulo,enlace,fecha_inicio,creado_por,rtc_estado,rtc_started_at) VALUES($1,$2,'Daily','',NOW(),$3,'active',NOW() - INTERVAL '10 minutes')")
            .bind(room).bind(node).bind(owner)
            .execute(&pool).await.unwrap();

        let (a1, a2, b1) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
        open(&pool, room, ana, a1, None).await;
        open(&pool, room, ana, a2, None).await;
        open(&pool, room, beto, b1, None).await;
        // Ana entró 6 min antes desde un dispositivo y 4 min antes desde otro.
        for (conn, minutes) in [(a1, 6), (a2, 4), (b1, 2)] {
            sqlx::query("UPDATE reunion_asistencia SET joined_at = NOW() - make_interval(mins => $2), last_seen_at = NOW() - make_interval(mins => $2) WHERE connection_id = $1")
                .bind(conn).bind(minutes).execute(&pool).await.unwrap();
        }
        close(&pool, a1, Exit::Left).await;
        // Un segundo cierre no reescribe el primero.
        close(&pool, a1, Exit::Kicked).await;
        touch(&pool, b1).await;

        let report = report(&pool, room).await.unwrap().unwrap();
        assert_eq!(report.sesiones.len(), 3);
        assert_eq!(report.sesiones[0].salida.as_deref(), Some("salio"));
        let ana_row = report
            .participantes
            .iter()
            .find(|p| p.user_id == ana)
            .unwrap();
        assert_eq!(ana_row.sesiones, 2);
        assert!(ana_row.conectado_ahora);
        // Unión de [−6, 0] y [−4, ahora]: unos 6 minutos, no 10.
        assert!((355..=365).contains(&ana_row.segundos_conectado));
        assert!(ana_row.porcentaje.unwrap() <= 100.0);
        let csv = to_csv(&report);
        assert!(csv.contains("\"'=Ana\""));
        assert_eq!(csv.lines().count(), 4);

        // Reinicio del servidor: Beto se cierra con su último latido.
        sqlx::query("UPDATE reunion_asistencia SET last_seen_at = NOW() - INTERVAL '1 minute' WHERE connection_id = $1")
            .bind(b1).execute(&pool).await.unwrap();
        assert_eq!(recover(&pool).await.unwrap(), 2);
        let report = super::report(&pool, room).await.unwrap().unwrap();
        let beto_row = report
            .participantes
            .iter()
            .find(|p| p.user_id == beto)
            .unwrap();
        assert!(!beto_row.conectado_ahora);
        assert!((55..=65).contains(&beto_row.segundos_conectado));

        // Fin de reunión con alguien conectado.
        let a3 = Uuid::new_v4();
        open(&pool, room, ana, a3, None).await;
        close_meeting(&pool, room).await;
        close(&pool, a3, Exit::Replaced).await;
        let salida: String =
            sqlx::query_scalar("SELECT salida FROM reunion_asistencia WHERE connection_id = $1")
                .bind(a3)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(salida, "reunion_finalizada");
    }
}
