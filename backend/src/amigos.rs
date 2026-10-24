//! Búsqueda de personas y amistades al estilo de Discord: solicitudes
//! pendientes (recibidas y enviadas), aceptar, ignorar, cancelar, eliminar,
//! bloquear y el ajuste de quién puede enviarte solicitudes.
//!
//! Reglas de privacidad:
//! - Por nombre se busca por coincidencia parcial; por correo, solo con el
//!   correo completo (nunca se devuelve el correo ni el teléfono).
//! - Rechazar es ignorar: desaparece para quien la recibe, quien la envió
//!   la sigue viendo como enviada y no puede reenviarla durante 30 días.
//! - Un bloqueo no se revela: quien está bloqueado no encuentra a la otra
//!   persona y recibe respuestas genéricas.
//!
//! El chat entre amigos (sin nodo en común) está en [`crate::amigos_chat`].
use std::{collections::HashMap, sync::Arc};

use axum::{
    Extension, Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    auth::{middleware::AuthUser, verification::AppState},
    rtc::server::RoomHub,
};

type ApiResult = (StatusCode, Json<Value>);

/// Solicitudes que una cuenta puede enviar por hora.
pub const MAX_SOLICITUDES_POR_HORA: i64 = 30;
/// Búsquedas de personas por minuto y cuenta.
pub const MAX_BUSQUEDAS_POR_MINUTO: i64 = 60;
const MAX_RESULTADOS: i64 = 20;

/// Respuesta común a bloqueo, privacidad y solicitud ignorada: no revela
/// cuál de las tres impidió el envío.
pub const SOLICITUD_NO_DISPONIBLE: &str =
    "No se pudo enviar la solicitud de amistad a esta persona.";

fn failure(status: StatusCode, message: &str) -> ApiResult {
    (status, Json(json!({"success": false, "message": message})))
}

fn unavailable() -> ApiResult {
    failure(
        StatusCode::SERVICE_UNAVAILABLE,
        "No se pudo completar la operación. Inténtalo de nuevo.",
    )
}

/// Escapa los comodines de LIKE para buscar el texto literal.
fn like_literal(text: &str) -> String {
    text.replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

/// Una consulta con «@» se trata como correo: solo coincidencia exacta.
fn es_correo(text: &str) -> bool {
    text.contains('@')
}

#[derive(Deserialize)]
pub struct BuscarQuery {
    q: Option<String>,
}

#[derive(Serialize, sqlx::FromRow)]
struct PersonaEncontrada {
    id: Uuid,
    nombre: String,
    avatar_url: Option<String>,
    avatar_color: Option<String>,
    /// `ninguna`, `enviada`, `recibida` o `amigos`.
    amistad: String,
    solicitud_id: Option<Uuid>,
    comparte_nodo: bool,
    /// La persona que busca la tiene bloqueada (puede desbloquearla).
    bloqueado: bool,
}

/// Cuenta la búsqueda y responde si se superó el límite por minuto.
async fn registrar_busqueda(pool: &sqlx::PgPool, user: Uuid) -> Result<bool, sqlx::Error> {
    let recientes = sqlx::query_scalar::<_, i64>(
        "WITH viejas AS (DELETE FROM busquedas_personas WHERE user_id = $1 \
                         AND created_at <= NOW() - INTERVAL '1 minute') \
         SELECT COUNT(*) FROM busquedas_personas WHERE user_id = $1 \
         AND created_at > NOW() - INTERVAL '1 minute'",
    )
    .bind(user)
    .fetch_one(pool)
    .await?;
    if recientes >= MAX_BUSQUEDAS_POR_MINUTO {
        return Ok(false);
    }
    sqlx::query("INSERT INTO busquedas_personas (user_id) VALUES ($1)")
        .bind(user)
        .execute(pool)
        .await?;
    Ok(true)
}

/// `GET /usuarios/buscar?q=`: personas activas por nombre (parcial) o por
/// correo completo (exacto). El correo nunca se devuelve (ni el teléfono).
/// Quien te bloqueó no aparece.
pub async fn buscar(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Query(query): Query<BuscarQuery>,
) -> ApiResult {
    let text = query.q.unwrap_or_default().trim().to_string();
    let length = text.chars().count();
    if length < 2 {
        return failure(
            StatusCode::BAD_REQUEST,
            "Escribe al menos 2 caracteres para buscar personas.",
        );
    }
    if length > 100 {
        return failure(
            StatusCode::BAD_REQUEST,
            "La búsqueda no puede superar los 100 caracteres.",
        );
    }
    match registrar_busqueda(&state.pool, auth.user_id).await {
        Ok(true) => {}
        Ok(false) => {
            return failure(
                StatusCode::TOO_MANY_REQUESTS,
                "Hiciste demasiadas búsquedas. Espera un momento e inténtalo de nuevo.",
            );
        }
        Err(_) => return unavailable(),
    }
    // «Comparte nodo»: ambos en un nodo activo sin baneo para ninguno. Las
    // dos consultas se repiten literales (SQLx 0.9 no admite SQL construido).
    let result = if es_correo(&text) {
        sqlx::query_as::<_, PersonaEncontrada>(
            "SELECT u.id, u.name AS nombre, u.avatar_url, u.avatar_color, \
             CASE WHEN a.estado = 'ignorada' AND a.solicitante <> $1 THEN NULL ELSE a.id END AS solicitud_id, \
             CASE WHEN a.id IS NULL THEN 'ninguna' WHEN a.estado = 'aceptada' THEN 'amigos' \
                  WHEN a.solicitante = $1 THEN 'enviada' WHEN a.estado = 'pendiente' THEN 'recibida' \
                  ELSE 'ninguna' END AS amistad, \
             EXISTS (SELECT 1 FROM nodo_miembros me \
                     JOIN nodos n ON n.id = me.nodo_id AND n.estado = 'active' \
                     JOIN nodo_miembros o ON o.nodo_id = n.id AND o.user_id = u.id \
                     WHERE me.user_id = $1 AND NOT EXISTS (SELECT 1 FROM nodo_baneos b \
                           WHERE b.nodo_id = n.id AND b.user_id IN ($1, u.id))) AS comparte_nodo, \
             EXISTS (SELECT 1 FROM bloqueos bl WHERE bl.bloqueador = $1 AND bl.bloqueado = u.id) AS bloqueado \
             FROM users u \
             LEFT JOIN amistades a ON (a.solicitante = $1 AND a.destinatario = u.id) \
                                   OR (a.solicitante = u.id AND a.destinatario = $1) \
             WHERE u.estado = 'ACTIVE' AND u.id <> $1 AND lower(u.email) = lower($2) \
               AND NOT EXISTS (SELECT 1 FROM bloqueos bl WHERE bl.bloqueador = u.id AND bl.bloqueado = $1) \
             LIMIT 1",
        )
        .bind(auth.user_id)
        .bind(&text)
        .fetch_all(&state.pool)
        .await
    } else {
        let literal = like_literal(&text);
        sqlx::query_as::<_, PersonaEncontrada>(
            "SELECT u.id, u.name AS nombre, u.avatar_url, u.avatar_color, \
             CASE WHEN a.estado = 'ignorada' AND a.solicitante <> $1 THEN NULL ELSE a.id END AS solicitud_id, \
             CASE WHEN a.id IS NULL THEN 'ninguna' WHEN a.estado = 'aceptada' THEN 'amigos' \
                  WHEN a.solicitante = $1 THEN 'enviada' WHEN a.estado = 'pendiente' THEN 'recibida' \
                  ELSE 'ninguna' END AS amistad, \
             EXISTS (SELECT 1 FROM nodo_miembros me \
                     JOIN nodos n ON n.id = me.nodo_id AND n.estado = 'active' \
                     JOIN nodo_miembros o ON o.nodo_id = n.id AND o.user_id = u.id \
                     WHERE me.user_id = $1 AND NOT EXISTS (SELECT 1 FROM nodo_baneos b \
                           WHERE b.nodo_id = n.id AND b.user_id IN ($1, u.id))) AS comparte_nodo, \
             EXISTS (SELECT 1 FROM bloqueos bl WHERE bl.bloqueador = $1 AND bl.bloqueado = u.id) AS bloqueado \
             FROM users u \
             LEFT JOIN amistades a ON (a.solicitante = $1 AND a.destinatario = u.id) \
                                   OR (a.solicitante = u.id AND a.destinatario = $1) \
             WHERE u.estado = 'ACTIVE' AND u.id <> $1 AND u.name ILIKE $2 ESCAPE '\\' \
               AND NOT EXISTS (SELECT 1 FROM bloqueos bl WHERE bl.bloqueador = u.id AND bl.bloqueado = $1) \
             ORDER BY (a.estado = 'aceptada') IS TRUE DESC, comparte_nodo DESC, \
                      (u.name ILIKE $3 ESCAPE '\\') DESC, lower(u.name), u.id \
             LIMIT $4",
        )
        .bind(auth.user_id)
        .bind(format!("%{literal}%"))
        .bind(format!("{literal}%"))
        .bind(MAX_RESULTADOS)
        .fetch_all(&state.pool)
        .await
    };
    match result {
        Ok(usuarios) => (
            StatusCode::OK,
            Json(json!({"success": true, "usuarios": usuarios})),
        ),
        Err(_) => unavailable(),
    }
}

#[derive(Serialize, sqlx::FromRow)]
struct Amigo {
    id: Uuid,
    nombre: String,
    avatar_url: Option<String>,
    avatar_color: Option<String>,
    status_text: Option<String>,
    desde: Option<DateTime<Utc>>,
    #[sqlx(skip)]
    nodos_comunes: Vec<NodoComun>,
}

#[derive(Serialize, Clone)]
struct NodoComun {
    id: Uuid,
    nombre: String,
}

/// `GET /amigos`: amistades aceptadas con los nodos que se comparten.
pub async fn listar(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
) -> ApiResult {
    let amigos = sqlx::query_as::<_, Amigo>(
        "SELECT u.id, u.name AS nombre, u.avatar_url, u.avatar_color, u.status_text, \
                a.responded_at AS desde \
         FROM amistades a \
         JOIN users u ON u.id = CASE WHEN a.solicitante = $1 THEN a.destinatario ELSE a.solicitante END \
         WHERE a.estado = 'aceptada' AND $1 IN (a.solicitante, a.destinatario) \
           AND u.estado = 'ACTIVE' \
         ORDER BY lower(u.name), u.id LIMIT 500",
    )
    .bind(auth.user_id)
    .fetch_all(&state.pool)
    .await;
    let Ok(mut amigos) = amigos else {
        return unavailable();
    };
    let ids: Vec<Uuid> = amigos.iter().map(|a| a.id).collect();
    let comunes = sqlx::query_as::<_, (Uuid, Uuid, String)>(
        "SELECT o.user_id, n.id, n.nombre FROM nodo_miembros me \
         JOIN nodos n ON n.id = me.nodo_id AND n.estado = 'active' \
         JOIN nodo_miembros o ON o.nodo_id = n.id AND o.user_id = ANY($2) \
         WHERE me.user_id = $1 AND NOT EXISTS (SELECT 1 FROM nodo_baneos b \
               WHERE b.nodo_id = n.id AND b.user_id IN ($1, o.user_id)) \
         ORDER BY lower(n.nombre), n.id",
    )
    .bind(auth.user_id)
    .bind(ids)
    .fetch_all(&state.pool)
    .await;
    let Ok(comunes) = comunes else {
        return unavailable();
    };
    let mut por_amigo: HashMap<Uuid, Vec<NodoComun>> = HashMap::new();
    for (user, id, nombre) in comunes {
        por_amigo
            .entry(user)
            .or_default()
            .push(NodoComun { id, nombre });
    }
    for amigo in &mut amigos {
        amigo.nodos_comunes = por_amigo.remove(&amigo.id).unwrap_or_default();
    }
    (
        StatusCode::OK,
        Json(json!({"success": true, "amigos": amigos})),
    )
}

#[derive(Serialize, sqlx::FromRow)]
struct Solicitud {
    id: Uuid,
    user_id: Uuid,
    nombre: String,
    avatar_url: Option<String>,
    avatar_color: Option<String>,
    comparte_nodo: bool,
    created_at: DateTime<Utc>,
    #[serde(skip)]
    enviada: bool,
}

/// `GET /amigos/solicitudes`: pendientes recibidas y enviadas. Una enviada
/// que la otra persona ignoró se sigue mostrando como enviada.
pub async fn solicitudes(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
) -> ApiResult {
    let result = sqlx::query_as::<_, Solicitud>(
        "SELECT a.id, u.id AS user_id, u.name AS nombre, u.avatar_url, u.avatar_color, \
                a.created_at, (a.solicitante = $1) AS enviada, \
         EXISTS (SELECT 1 FROM nodo_miembros me \
                 JOIN nodos n ON n.id = me.nodo_id AND n.estado = 'active' \
                 JOIN nodo_miembros o ON o.nodo_id = n.id AND o.user_id = u.id \
                 WHERE me.user_id = $1 AND NOT EXISTS (SELECT 1 FROM nodo_baneos b \
                       WHERE b.nodo_id = n.id AND b.user_id IN ($1, u.id))) AS comparte_nodo \
         FROM amistades a \
         JOIN users u ON u.id = CASE WHEN a.solicitante = $1 THEN a.destinatario ELSE a.solicitante END \
         WHERE $1 IN (a.solicitante, a.destinatario) AND u.estado = 'ACTIVE' \
           AND (a.estado = 'pendiente' OR (a.estado = 'ignorada' AND a.solicitante = $1)) \
         ORDER BY a.created_at DESC, a.id LIMIT 400",
    )
    .bind(auth.user_id)
    .fetch_all(&state.pool)
    .await;
    let Ok(all) = result else {
        return unavailable();
    };
    let (enviadas, recibidas): (Vec<_>, Vec<_>) = all.into_iter().partition(|s| s.enviada);
    (
        StatusCode::OK,
        Json(json!({"success": true, "recibidas": recibidas, "enviadas": enviadas})),
    )
}

/// Pendientes recibidas de cuentas activas, para el canal en vivo.
pub async fn pendientes_recibidas(pool: &sqlx::PgPool, user: Uuid) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM amistades a JOIN users u ON u.id = a.solicitante AND u.estado = 'ACTIVE' \
         WHERE a.destinatario = $1 AND a.estado = 'pendiente'",
    )
    .bind(user)
    .fetch_one(pool)
    .await
}

/// Amistades aceptadas y solicitudes enviadas aún pendientes. Viajan en la
/// instantánea en vivo para que quien envió una solicitud vea el cambio
/// cuando la otra persona la acepta o la rechaza (IRL-FULL-002).
pub async fn resumen_relaciones(
    pool: &sqlx::PgPool,
    user: Uuid,
) -> Result<(i64, i64), sqlx::Error> {
    sqlx::query_as(
        "SELECT COUNT(*) FILTER (WHERE estado = 'aceptada'), \
                COUNT(*) FILTER (WHERE estado = 'pendiente' AND solicitante = $1) \
         FROM amistades WHERE solicitante = $1 OR destinatario = $1",
    )
    .bind(user)
    .fetch_one(pool)
    .await
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnviarSolicitud {
    user_id: Uuid,
}

enum Envio {
    Creada(Uuid),
    Aceptada(Uuid),
    Conflicto(&'static str),
    /// Ignorada hace menos de 30 días o privacidad del destinatario.
    NoDisponible,
    Reintentar,
}

async fn intentar_envio(
    pool: &sqlx::PgPool,
    own: Uuid,
    target: Uuid,
) -> Result<Envio, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let existing = sqlx::query_as::<_, (Uuid, Uuid, String)>(
        "SELECT id, solicitante, estado FROM amistades \
         WHERE (solicitante = $1 AND destinatario = $2) OR (solicitante = $2 AND destinatario = $1) \
         FOR UPDATE",
    )
    .bind(own)
    .bind(target)
    .fetch_optional(&mut *tx)
    .await?;
    let outcome = match existing {
        Some((_, _, estado)) if estado == "aceptada" => Envio::Conflicto("Ya son amigos."),
        // Pendiente o ignorada: para quien la envió sigue «enviada».
        Some((_, from, _)) if from == own => {
            Envio::Conflicto("Ya enviaste una solicitud a esta persona.")
        }
        // La otra persona ya te la había enviado (aunque la ignoraras): se
        // acepta sin duplicar y se olvidan los rechazos de la pareja.
        Some((id, _, _)) => {
            sqlx::query(
                "UPDATE amistades SET estado = 'aceptada', responded_at = NOW() WHERE id = $1",
            )
            .bind(id)
            .execute(&mut *tx)
            .await?;
            sqlx::query(
                "DELETE FROM amistad_rechazos WHERE (solicitante = $1 AND destinatario = $2) \
                 OR (solicitante = $2 AND destinatario = $1)",
            )
            .bind(own)
            .bind(target)
            .execute(&mut *tx)
            .await?;
            Envio::Aceptada(id)
        }
        None => {
            // Privacidad del destinatario y rechazos de los últimos 30 días.
            let permitido = sqlx::query_scalar::<_, bool>(
                "SELECT NOT EXISTS (SELECT 1 FROM amistad_rechazos r WHERE r.solicitante = $1 \
                        AND r.destinatario = $2 AND r.created_at > NOW() - INTERVAL '30 days') \
                 AND CASE COALESCE((SELECT p.solicitudes_de FROM privacidad_social p \
                                    WHERE p.user_id = $2), 'todos') \
                     WHEN 'todos' THEN TRUE \
                     WHEN 'nodos' THEN EXISTS (SELECT 1 FROM nodo_miembros me \
                          JOIN nodos n ON n.id = me.nodo_id AND n.estado = 'active' \
                          JOIN nodo_miembros o ON o.nodo_id = n.id AND o.user_id = $2 \
                          WHERE me.user_id = $1 AND NOT EXISTS (SELECT 1 FROM nodo_baneos b \
                                WHERE b.nodo_id = n.id AND b.user_id IN ($1, $2))) \
                     ELSE FALSE END",
            )
            .bind(own)
            .bind(target)
            .fetch_one(&mut *tx)
            .await?;
            if !permitido {
                Envio::NoDisponible
            } else {
                let id = sqlx::query_scalar::<_, Uuid>(
                    "INSERT INTO amistades (solicitante, destinatario) VALUES ($1, $2) \
                     ON CONFLICT DO NOTHING RETURNING id",
                )
                .bind(own)
                .bind(target)
                .fetch_optional(&mut *tx)
                .await?;
                match id {
                    Some(id) => {
                        sqlx::query("INSERT INTO amistad_envios (user_id) VALUES ($1)")
                            .bind(own)
                            .execute(&mut *tx)
                            .await?;
                        Envio::Creada(id)
                    }
                    // Otra petición creó la fila a la vez: se vuelve a evaluar.
                    None => Envio::Reintentar,
                }
            }
        }
    };
    tx.commit().await?;
    Ok(outcome)
}

/// Bloqueos entre dos personas: (yo bloqueé, me bloquearon).
async fn bloqueos_entre(
    pool: &sqlx::PgPool,
    own: Uuid,
    other: Uuid,
) -> Result<(bool, bool), sqlx::Error> {
    sqlx::query_as::<_, (bool, bool)>(
        "SELECT EXISTS (SELECT 1 FROM bloqueos WHERE bloqueador = $1 AND bloqueado = $2), \
                EXISTS (SELECT 1 FROM bloqueos WHERE bloqueador = $2 AND bloqueado = $1)",
    )
    .bind(own)
    .bind(other)
    .fetch_one(pool)
    .await
}

/// ¿Hay un bloqueo en cualquier sentido? Lo usan también los chats.
pub async fn hay_bloqueo(pool: &sqlx::PgPool, a: Uuid, b: Uuid) -> Result<bool, sqlx::Error> {
    sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM bloqueos WHERE (bloqueador = $1 AND bloqueado = $2) \
                OR (bloqueador = $2 AND bloqueado = $1))",
    )
    .bind(a)
    .bind(b)
    .fetch_one(pool)
    .await
}

/// `POST /amigos/solicitudes` `{user_id}`.
pub async fn enviar(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Json(payload): Json<EnviarSolicitud>,
) -> ApiResult {
    let target = payload.user_id;
    if target == auth.user_id {
        return failure(
            StatusCode::BAD_REQUEST,
            "No puedes enviarte una solicitud de amistad a ti mismo.",
        );
    }
    let active = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM users WHERE id = $1 AND estado = 'ACTIVE')",
    )
    .bind(target)
    .fetch_one(&state.pool)
    .await;
    match active {
        Ok(true) => {}
        Ok(false) => return failure(StatusCode::NOT_FOUND, "No se encontró a esa persona."),
        Err(_) => return unavailable(),
    }
    match bloqueos_entre(&state.pool, auth.user_id, target).await {
        Ok((true, _)) => {
            return failure(
                StatusCode::CONFLICT,
                "Desbloquea a esta persona para enviarle una solicitud.",
            );
        }
        Ok((false, true)) => return failure(StatusCode::FORBIDDEN, SOLICITUD_NO_DISPONIBLE),
        Ok(_) => {}
        Err(_) => return unavailable(),
    }
    let recent = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM amistad_envios WHERE user_id = $1 \
         AND created_at > NOW() - INTERVAL '1 hour'",
    )
    .bind(auth.user_id)
    .fetch_one(&state.pool)
    .await;
    match recent {
        Ok(count) if count >= MAX_SOLICITUDES_POR_HORA => {
            return failure(
                StatusCode::TOO_MANY_REQUESTS,
                "Enviaste demasiadas solicitudes. Inténtalo de nuevo más tarde.",
            );
        }
        Ok(_) => {}
        Err(_) => return unavailable(),
    }
    for _ in 0..2 {
        let outcome = match intentar_envio(&state.pool, auth.user_id, target).await {
            Ok(outcome) => outcome,
            Err(_) => return unavailable(),
        };
        return match outcome {
            Envio::Creada(id) => {
                hub.changed();
                (
                    StatusCode::CREATED,
                    Json(json!({"success": true, "estado": "pendiente", "solicitud_id": id})),
                )
            }
            Envio::Aceptada(id) => {
                hub.changed();
                (
                    StatusCode::OK,
                    Json(json!({"success": true, "estado": "aceptada", "solicitud_id": id})),
                )
            }
            Envio::Conflicto(message) => failure(StatusCode::CONFLICT, message),
            Envio::NoDisponible => failure(StatusCode::FORBIDDEN, SOLICITUD_NO_DISPONIBLE),
            Envio::Reintentar => continue,
        };
    }
    unavailable()
}

/// `POST /amigos/solicitudes/{id}/aceptar`: solo quien la recibió.
pub async fn aceptar(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path(id): Path<Uuid>,
) -> ApiResult {
    let result = sqlx::query_scalar::<_, i64>(
        "WITH ok AS (UPDATE amistades a SET estado = 'aceptada', responded_at = NOW() \
                     FROM users u WHERE a.id = $1 AND a.destinatario = $2 AND a.estado = 'pendiente' \
                     AND u.id = a.solicitante AND u.estado = 'ACTIVE' \
                     RETURNING a.solicitante, a.destinatario), \
              limpio AS (DELETE FROM amistad_rechazos r USING ok \
                     WHERE (r.solicitante = ok.solicitante AND r.destinatario = ok.destinatario) \
                        OR (r.solicitante = ok.destinatario AND r.destinatario = ok.solicitante)) \
         SELECT COUNT(*) FROM ok",
    )
    .bind(id)
    .bind(auth.user_id)
    .fetch_one(&state.pool)
    .await;
    respond(result, &hub, "aceptada")
}

/// `POST /amigos/solicitudes/{id}/rechazar`: solo quien la recibió. Se
/// ignora: desaparece para quien la recibe y quien la envió no recibe aviso
/// (la sigue viendo como enviada) ni puede reenviarla durante 30 días.
pub async fn rechazar(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path(id): Path<Uuid>,
) -> ApiResult {
    let result = sqlx::query_scalar::<_, i64>(
        "WITH r AS (UPDATE amistades SET estado = 'ignorada', responded_at = NOW() \
                    WHERE id = $1 AND destinatario = $2 AND estado = 'pendiente' \
                    RETURNING solicitante, destinatario), \
              registro AS (INSERT INTO amistad_rechazos (solicitante, destinatario) \
                    SELECT solicitante, destinatario FROM r \
                    ON CONFLICT (solicitante, destinatario) DO UPDATE SET created_at = NOW()) \
         SELECT COUNT(*) FROM r",
    )
    .bind(id)
    .bind(auth.user_id)
    .fetch_one(&state.pool)
    .await;
    respond(result, &hub, "rechazada")
}

/// `DELETE /amigos/solicitudes/{id}`: cancela una solicitud propia (también
/// si la otra persona la ignoró; el plazo de 30 días se mantiene).
pub async fn cancelar(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path(id): Path<Uuid>,
) -> ApiResult {
    let result = sqlx::query_scalar::<_, i64>(
        "WITH d AS (DELETE FROM amistades WHERE id = $1 AND solicitante = $2 \
                    AND estado IN ('pendiente', 'ignorada') RETURNING id) \
         SELECT COUNT(*) FROM d",
    )
    .bind(id)
    .bind(auth.user_id)
    .fetch_one(&state.pool)
    .await;
    respond(result, &hub, "cancelada")
}

/// `DELETE /amigos/{user_id}`: termina la amistad para ambas personas.
pub async fn eliminar(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path(friend): Path<Uuid>,
) -> ApiResult {
    let result = sqlx::query(
        "DELETE FROM amistades WHERE estado = 'aceptada' AND \
         ((solicitante = $1 AND destinatario = $2) OR (solicitante = $2 AND destinatario = $1))",
    )
    .bind(auth.user_id)
    .bind(friend)
    .execute(&state.pool)
    .await;
    match result {
        Ok(done) if done.rows_affected() == 1 => {
            hub.changed();
            (
                StatusCode::OK,
                Json(json!({"success": true, "estado": "eliminada"})),
            )
        }
        Ok(_) => failure(StatusCode::NOT_FOUND, "Esa persona no está en tus amigos."),
        Err(_) => unavailable(),
    }
}

fn respond(result: Result<i64, sqlx::Error>, hub: &RoomHub, estado: &str) -> ApiResult {
    match result {
        Ok(1) => {
            hub.changed();
            (
                StatusCode::OK,
                Json(json!({"success": true, "estado": estado})),
            )
        }
        Ok(_) => failure(StatusCode::NOT_FOUND, "La solicitud ya no está pendiente."),
        Err(_) => unavailable(),
    }
}

#[derive(Serialize, sqlx::FromRow)]
struct Bloqueado {
    id: Uuid,
    nombre: String,
    avatar_url: Option<String>,
    avatar_color: Option<String>,
    desde: DateTime<Utc>,
}

/// `GET /bloqueados`: personas que bloqueaste.
pub async fn bloqueados(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
) -> ApiResult {
    let result = sqlx::query_as::<_, Bloqueado>(
        "SELECT u.id, u.name AS nombre, u.avatar_url, u.avatar_color, b.created_at AS desde \
         FROM bloqueos b JOIN users u ON u.id = b.bloqueado \
         WHERE b.bloqueador = $1 ORDER BY lower(u.name), u.id LIMIT 500",
    )
    .bind(auth.user_id)
    .fetch_all(&state.pool)
    .await;
    match result {
        Ok(list) => (
            StatusCode::OK,
            Json(json!({"success": true, "bloqueados": list})),
        ),
        Err(_) => unavailable(),
    }
}

async fn guardar_bloqueo(pool: &sqlx::PgPool, own: Uuid, target: Uuid) -> Result<(), sqlx::Error> {
    let mut tx = pool.begin().await?;
    sqlx::query(
        "INSERT INTO bloqueos (bloqueador, bloqueado) VALUES ($1, $2) ON CONFLICT DO NOTHING",
    )
    .bind(own)
    .bind(target)
    .execute(&mut *tx)
    .await?;
    // Bloquear termina la amistad y borra las solicitudes en ambos sentidos.
    sqlx::query(
        "DELETE FROM amistades WHERE (solicitante = $1 AND destinatario = $2) \
         OR (solicitante = $2 AND destinatario = $1)",
    )
    .bind(own)
    .bind(target)
    .execute(&mut *tx)
    .await?;
    tx.commit().await
}

/// `PUT /bloqueados/{user_id}`: bloquea (idempotente).
pub async fn bloquear(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path(target): Path<Uuid>,
) -> ApiResult {
    if target == auth.user_id {
        return failure(StatusCode::BAD_REQUEST, "No puedes bloquearte a ti mismo.");
    }
    let exists = sqlx::query_scalar::<_, bool>("SELECT EXISTS (SELECT 1 FROM users WHERE id = $1)")
        .bind(target)
        .fetch_one(&state.pool)
        .await;
    match exists {
        Ok(true) => {}
        Ok(false) => return failure(StatusCode::NOT_FOUND, "No se encontró a esa persona."),
        Err(_) => return unavailable(),
    }
    match guardar_bloqueo(&state.pool, auth.user_id, target).await {
        Ok(()) => {
            hub.changed();
            (
                StatusCode::OK,
                Json(json!({"success": true, "estado": "bloqueado"})),
            )
        }
        Err(_) => unavailable(),
    }
}

/// `DELETE /bloqueados/{user_id}`: desbloquea. La amistad no se restaura.
pub async fn desbloquear(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Extension(hub): Extension<Arc<RoomHub>>,
    Path(target): Path<Uuid>,
) -> ApiResult {
    let result = sqlx::query("DELETE FROM bloqueos WHERE bloqueador = $1 AND bloqueado = $2")
        .bind(auth.user_id)
        .bind(target)
        .execute(&state.pool)
        .await;
    match result {
        Ok(done) if done.rows_affected() == 1 => {
            hub.changed();
            (
                StatusCode::OK,
                Json(json!({"success": true, "estado": "desbloqueado"})),
            )
        }
        Ok(_) => failure(StatusCode::NOT_FOUND, "Esa persona no está bloqueada."),
        Err(_) => unavailable(),
    }
}

const PRIVACIDAD_VALIDA: [&str; 3] = ["todos", "nodos", "nadie"];

/// `GET /amigos/privacidad`: quién puede enviarte solicitudes.
pub async fn privacidad(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
) -> ApiResult {
    let result = sqlx::query_scalar::<_, String>(
        "SELECT COALESCE((SELECT solicitudes_de FROM privacidad_social WHERE user_id = $1), 'todos')",
    )
    .bind(auth.user_id)
    .fetch_one(&state.pool)
    .await;
    match result {
        Ok(value) => (
            StatusCode::OK,
            Json(json!({"success": true, "solicitudes_de": value})),
        ),
        Err(_) => unavailable(),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Privacidad {
    solicitudes_de: String,
}

/// `PUT /amigos/privacidad` `{solicitudes_de: todos|nodos|nadie}`.
pub async fn guardar_privacidad(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Json(payload): Json<Privacidad>,
) -> ApiResult {
    let value = payload.solicitudes_de.trim().to_lowercase();
    if !PRIVACIDAD_VALIDA.contains(&value.as_str()) {
        return failure(StatusCode::BAD_REQUEST, "Elige «todos», «nodos» o «nadie».");
    }
    let result = sqlx::query(
        "INSERT INTO privacidad_social (user_id, solicitudes_de) VALUES ($1, $2) \
         ON CONFLICT (user_id) DO UPDATE SET solicitudes_de = EXCLUDED.solicitudes_de, \
         updated_at = NOW()",
    )
    .bind(auth.user_id)
    .bind(&value)
    .execute(&state.pool)
    .await;
    match result {
        Ok(_) => (
            StatusCode::OK,
            Json(json!({"success": true, "solicitudes_de": value})),
        ),
        Err(_) => unavailable(),
    }
}

#[cfg(test)]
mod tests {
    use super::{es_correo, like_literal};

    #[test]
    fn like_wildcards_are_literal() {
        assert_eq!(like_literal("50%_a\\b"), "50\\%\\_a\\\\b");
        assert_eq!(like_literal("Ana"), "Ana");
    }

    #[test]
    fn at_sign_means_exact_email() {
        assert!(es_correo("ana@example.com"));
        assert!(es_correo("ana@"));
        assert!(!es_correo("Ana Mena"));
    }
}
