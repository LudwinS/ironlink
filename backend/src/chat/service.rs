use super::models::*;
use crate::auth::{middleware::AuthUser, verification::AppState};
use axum::{
    Json,
    extract::{Query, State},
    http::StatusCode,
};
use uuid::Uuid;

// ─── POST /nodos/{id}/mensajes ───────────────────────────────────────────

pub async fn send_mensaje(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::extract::Path(id): axum::extract::Path<Uuid>,
    Json(payload): Json<SendMensajeDto>,
) -> (StatusCode, Json<MensajeResponse>) {
    let contenido = payload.contenido.trim();
    if contenido.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            MensajeResponse::failure("El contenido del mensaje no puede estar vacío."),
        );
    }

    // 1. Verificar si el usuario es miembro del nodo
    let member_check = sqlx::query_as::<_, (String,)>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await;

    let user_node_role = match member_check {
        Ok(Some((rol,))) => Some(rol),
        _ => {
            if auth_user.role == "ADMIN" {
                Some("GLOBAL_ADMIN".to_string())
            } else {
                None
            }
        }
    };

    let user_role_str = match user_node_role {
        Some(r) => r,
        None => {
            return (
                StatusCode::FORBIDDEN,
                MensajeResponse::failure(
                    "No tienes permiso para enviar mensajes en este nodo ya que no eres miembro.",
                ),
            );
        }
    };

    // 2. Si es para un subgrupo, validar que exista en este nodo y si es privado validar membresía
    if let Some(subgrupo_id) = payload.subgrupo_id {
        let sub_check = sqlx::query_as::<_, (bool,)>(
            "SELECT es_privado FROM subgrupos WHERE id = $1 AND nodo_id = $2 AND is_archived = FALSE"
        )
        .bind(subgrupo_id)
        .bind(id)
        .fetch_optional(&state.pool)
        .await;

        match sub_check {
            Ok(Some((es_privado,))) => {
                if es_privado && user_role_str != "OWNER" && user_role_str != "GLOBAL_ADMIN" {
                    let is_sub_member = sqlx::query_scalar::<_, bool>(
                        "SELECT EXISTS(SELECT 1 FROM subgrupo_miembros WHERE subgrupo_id = $1 AND user_id = $2)"
                    )
                    .bind(subgrupo_id)
                    .bind(auth_user.user_id)
                    .fetch_one(&state.pool)
                    .await
                    .unwrap_or(false);

                    if !is_sub_member {
                        return (
                            StatusCode::FORBIDDEN,
                            MensajeResponse::failure(
                                "Debes unirte a este subgrupo privado para enviar mensajes.",
                            ),
                        );
                    }
                }
            }
            Ok(None) => {
                return (
                    StatusCode::NOT_FOUND,
                    MensajeResponse::failure("El subgrupo especificado no existe en este nodo."),
                );
            }
            Err(e) => {
                eprintln!("Error al validar subgrupo: {}", e);
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    MensajeResponse::failure("Error interno al validar el subgrupo."),
                );
            }
        }
    }

    // 3. Insertar mensaje en la base de datos
    let insert = sqlx::query_as::<
        _,
        (
            Uuid,
            Uuid,
            Uuid,
            String,
            chrono::DateTime<chrono::Utc>,
            Option<Uuid>,
        ),
    >(
        r#"
        INSERT INTO mensajes (nodo_id, user_id, contenido, subgrupo_id) VALUES ($1, $2, $3, $4)
        RETURNING id, nodo_id, user_id, contenido, created_at, subgrupo_id
        "#,
    )
    .bind(id)
    .bind(auth_user.user_id)
    .bind(contenido)
    .bind(payload.subgrupo_id)
    .fetch_one(&state.pool)
    .await;

    match insert {
        Ok((msg_id, nodo_id, user_id, contenido, created_at, subgrupo_id)) => {
            // Obtener datos del perfil del usuario (nombre, avatar y estado)
            let user_info =
                sqlx::query_as::<_, (String, Option<String>, Option<String>, Option<String>)>(
                    "SELECT name, avatar_url, avatar_color, status_text FROM users WHERE id = $1",
                )
                .bind(user_id)
                .fetch_one(&state.pool)
                .await;

            let (user_name, avatar_url, avatar_color, status_text) = match user_info {
                Ok((n, u, c, s)) => (n, u, c, s),
                Err(_) => ("Usuario".to_string(), None, None, None),
            };

            (
                StatusCode::CREATED,
                Json(MensajeResponse {
                    success: true,
                    message: "Mensaje enviado exitosamente.".to_string(),
                    mensaje: Some(MensajeInfo {
                        id: msg_id,
                        nodo_id,
                        user_id,
                        user_name,
                        contenido,
                        created_at,
                        subgrupo_id,
                        avatar_url,
                        avatar_color,
                        status_text,
                    }),
                    mensajes: None,
                    incremental: None,
                }),
            )
        }
        Err(e) => {
            eprintln!("Error al enviar mensaje en DB: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                MensajeResponse::failure("Error interno al enviar el mensaje."),
            )
        }
    }
}

/// Fila de un mensaje con los datos de su autor.
type MensajeRow = (
    Uuid,
    Uuid,
    Uuid,
    String,
    String,
    chrono::DateTime<chrono::Utc>,
    Option<Uuid>,
    Option<String>,
    Option<String>,
    Option<String>,
);

// ─── GET /nodos/{id}/mensajes ────────────────────────────────────────────

pub async fn list_mensajes(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::extract::Path(id): axum::extract::Path<Uuid>,
    Query(query): Query<ListMensajesQuery>,
) -> (StatusCode, Json<MensajeResponse>) {
    // 1. Verificar si el usuario es miembro del nodo
    let member_check = sqlx::query_as::<_, (String,)>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await;

    let user_node_role = match member_check {
        Ok(Some((rol,))) => Some(rol),
        _ => {
            if auth_user.role == "ADMIN" {
                Some("GLOBAL_ADMIN".to_string())
            } else {
                None
            }
        }
    };

    let user_role_str = match user_node_role {
        Some(r) => r,
        None => {
            return (
                StatusCode::FORBIDDEN,
                MensajeResponse::failure(
                    "No tienes permiso para ver los mensajes de este nodo ya que no eres miembro.",
                ),
            );
        }
    };

    // 2. Si es para un subgrupo, validar permisos y si es privado validar membresía
    if let Some(subgrupo_id) = query.subgrupo_id {
        let sub_check = sqlx::query_as::<_, (bool,)>(
            "SELECT es_privado FROM subgrupos WHERE id = $1 AND nodo_id = $2 AND is_archived = FALSE"
        )
        .bind(subgrupo_id)
        .bind(id)
        .fetch_optional(&state.pool)
        .await;

        match sub_check {
            Ok(Some((es_privado,))) => {
                if es_privado && user_role_str != "OWNER" && user_role_str != "GLOBAL_ADMIN" {
                    let is_sub_member = sqlx::query_scalar::<_, bool>(
                        "SELECT EXISTS(SELECT 1 FROM subgrupo_miembros WHERE subgrupo_id = $1 AND user_id = $2)"
                    )
                    .bind(subgrupo_id)
                    .bind(auth_user.user_id)
                    .fetch_one(&state.pool)
                    .await
                    .unwrap_or(false);

                    if !is_sub_member {
                        return (
                            StatusCode::FORBIDDEN,
                            MensajeResponse::failure("No tienes acceso a este subgrupo privado."),
                        );
                    }
                }
            }
            Ok(None) => {
                return (
                    StatusCode::NOT_FOUND,
                    MensajeResponse::failure("El subgrupo especificado no existe en este nodo."),
                );
            }
            Err(e) => {
                eprintln!("Error al validar subgrupo: {}", e);
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    MensajeResponse::failure("Error interno al validar el subgrupo."),
                );
            }
        }
    }

    // 3. Obtener lista de mensajes con perfil del autor según subgrupo_id o general
    // Con `despues_de` (sondeo cada 2 s) solo viajan los mensajes posteriores
    // a ese, con 10 s de solape por si una inserción concurrente terminó con
    // una hora anterior; el cliente descarta los repetidos por id. Antes cada
    // sondeo devolvía los 100 últimos con la foto en base64 de cada autor.
    let cursor = match query.despues_de {
        Some(after) => match sqlx::query_scalar::<_, chrono::DateTime<chrono::Utc>>(
            "SELECT created_at FROM mensajes WHERE id = $1 AND nodo_id = $2 AND subgrupo_id IS NOT DISTINCT FROM $3",
        )
        .bind(after)
        .bind(id)
        .bind(query.subgrupo_id)
        .fetch_optional(&state.pool)
        .await
        {
            Ok(found) => found,
            Err(e) => {
                eprintln!("Error al cargar mensajes: {}", e);
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    MensajeResponse::failure("Error interno al cargar los mensajes."),
                );
            }
        },
        None => None,
    };
    let rows = match cursor {
        Some(since) => {
            sqlx::query_as::<_, MensajeRow>(
                r#"
                SELECT m.id, m.nodo_id, m.user_id, u.name as user_name, m.contenido, m.created_at, m.subgrupo_id, u.avatar_url, u.avatar_color, u.status_text
                FROM mensajes m
                INNER JOIN users u ON m.user_id = u.id
                WHERE m.nodo_id = $1 AND m.subgrupo_id IS NOT DISTINCT FROM $2
                  AND m.created_at > $3 - INTERVAL '10 seconds' AND m.id <> $4
                ORDER BY m.created_at, m.id
                LIMIT 100
                "#,
            )
            .bind(id)
            .bind(query.subgrupo_id)
            .bind(since)
            .bind(query.despues_de)
            .fetch_all(&state.pool)
            .await
        }
        // Los 100 mensajes más recientes del canal general o del subgrupo, en
        // orden cronológico. Antes se tomaban los 100 más antiguos y los
        // nuevos dejaban de verse al superar ese número.
        None => {
            sqlx::query_as::<_, MensajeRow>(
                r#"
                SELECT * FROM (
                    SELECT m.id, m.nodo_id, m.user_id, u.name as user_name, m.contenido, m.created_at, m.subgrupo_id, u.avatar_url, u.avatar_color, u.status_text
                    FROM mensajes m
                    INNER JOIN users u ON m.user_id = u.id
                    WHERE m.nodo_id = $1 AND m.subgrupo_id IS NOT DISTINCT FROM $2
                    ORDER BY m.created_at DESC, m.id DESC
                    LIMIT 100
                ) recientes
                ORDER BY created_at, id
                "#,
            )
            .bind(id)
            .bind(query.subgrupo_id)
            .fetch_all(&state.pool)
            .await
        }
    };

    match rows {
        Ok(msgs) => {
            let list: Vec<MensajeInfo> = msgs
                .into_iter()
                .map(
                    |(
                        msg_id,
                        nodo_id,
                        user_id,
                        user_name,
                        contenido,
                        created_at,
                        subgrupo_id,
                        avatar_url,
                        avatar_color,
                        status_text,
                    )| {
                        MensajeInfo {
                            id: msg_id,
                            nodo_id,
                            user_id,
                            user_name,
                            contenido,
                            created_at,
                            subgrupo_id,
                            avatar_url,
                            avatar_color,
                            status_text,
                        }
                    },
                )
                .collect();

            // Limpieza del badge al abrir el chat (IRL-WKS-US-03): se marca
            // como leído hasta el último mensaje DEVUELTO, no hasta NOW(). Un
            // mensaje que llegue entre la consulta y esta actualización sigue
            // contando como no leído. Nunca retrocede la marca.
            if let Some(newest) = list.last().map(|m| m.created_at) {
                let _ = if let Some(sub_id) = query.subgrupo_id {
                    sqlx::query(
                        "UPDATE subgrupo_miembros SET last_read_at = GREATEST(COALESCE(last_read_at, $3), $3)
                         WHERE subgrupo_id = $1 AND user_id = $2",
                    )
                    .bind(sub_id)
                    .bind(auth_user.user_id)
                    .bind(newest)
                    .execute(&state.pool)
                    .await
                } else {
                    sqlx::query(
                        "UPDATE nodo_miembros SET last_read_at = GREATEST(COALESCE(last_read_at, $3), $3)
                         WHERE nodo_id = $1 AND user_id = $2",
                    )
                    .bind(id)
                    .bind(auth_user.user_id)
                    .bind(newest)
                    .execute(&state.pool)
                    .await
                };
            }

            (
                StatusCode::OK,
                Json(MensajeResponse {
                    success: true,
                    message: "Mensajes cargados exitosamente.".to_string(),
                    mensaje: None,
                    mensajes: Some(list),
                    incremental: cursor.map(|_| true),
                }),
            )
        }
        Err(e) => {
            eprintln!("Error al cargar mensajes: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                MensajeResponse::failure("Error interno al cargar los mensajes."),
            )
        }
    }
}

// ─── GET /nodos/{id}/unread-count y /api/node/{id}/unread-count ───────────

pub async fn get_unread_count(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::extract::Path(id): axum::extract::Path<Uuid>,
) -> (StatusCode, Json<UnreadCountResponse>) {
    // 1. Obtener last_read_at del miembro en el nodo
    let member = sqlx::query_as::<_, (Option<chrono::DateTime<chrono::Utc>>,)>(
        "SELECT last_read_at FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await;

    let last_read_at = match member {
        Ok(Some((lr,))) => lr,
        Ok(None) => {
            if auth_user.role != "ADMIN" {
                return (
                    StatusCode::FORBIDDEN,
                    Json(UnreadCountResponse {
                        success: false,
                        message: "No eres miembro de este nodo.".to_string(),
                        unread_count: 0,
                        last_read_at: None,
                    }),
                );
            }
            None
        }
        Err(e) => {
            eprintln!("Error al consultar membresía para unread_count: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(UnreadCountResponse {
                    success: false,
                    message: "Error interno al verificar estado de lectura.".to_string(),
                    unread_count: 0,
                    last_read_at: None,
                }),
            );
        }
    };

    // 2. Contar mensajes pendientes no leídos en el canal general del nodo
    let count_res = match last_read_at {
        Some(read_time) => {
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM mensajes WHERE nodo_id = $1 AND subgrupo_id IS NULL AND created_at > $2 AND user_id != $3"
            )
            .bind(id)
            .bind(read_time)
            .bind(auth_user.user_id)
            .fetch_one(&state.pool)
            .await
        }
        None => {
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM mensajes WHERE nodo_id = $1 AND subgrupo_id IS NULL AND user_id != $2"
            )
            .bind(id)
            .bind(auth_user.user_id)
            .fetch_one(&state.pool)
            .await
        }
    };

    match count_res {
        Ok(unread_count) => (
            StatusCode::OK,
            Json(UnreadCountResponse {
                success: true,
                message: "Contador de mensajes no leídos obtenido.".to_string(),
                unread_count,
                last_read_at,
            }),
        ),
        Err(e) => {
            eprintln!("Error al contar mensajes no leídos: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(UnreadCountResponse {
                    success: false,
                    message: "Error interno al calcular mensajes no leídos.".to_string(),
                    unread_count: 0,
                    last_read_at,
                }),
            )
        }
    }
}

// ─── POST /nodos/{id}/read y /api/node/{id}/check_read_status ─────────────

pub async fn mark_as_read(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::extract::Path(id): axum::extract::Path<Uuid>,
) -> (StatusCode, Json<MarkReadResponse>) {
    let now = chrono::Utc::now();
    // Hasta el último mensaje existente del canal general (no hasta la hora
    // actual del servidor), y sin retroceder una marca posterior.
    let res = sqlx::query(
        "UPDATE nodo_miembros SET last_read_at = GREATEST(
             COALESCE(last_read_at, '-infinity'),
             COALESCE((SELECT MAX(created_at) FROM mensajes WHERE nodo_id = $2 AND subgrupo_id IS NULL), $1))
         WHERE nodo_id = $2 AND user_id = $3",
    )
    .bind(now)
    .bind(id)
    .bind(auth_user.user_id)
    .execute(&state.pool)
    .await;

    match res {
        Ok(r) => {
            if r.rows_affected() == 0 && auth_user.role != "ADMIN" {
                return (
                    StatusCode::FORBIDDEN,
                    MarkReadResponse::failure("No perteneces a este nodo."),
                );
            }
            (
                StatusCode::OK,
                Json(MarkReadResponse {
                    success: true,
                    message: "Registro de lectura actualizado exitosamente.".to_string(),
                    last_read_at: Some(now),
                }),
            )
        }
        Err(e) => {
            eprintln!("Error al actualizar last_read_at: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                MarkReadResponse::failure("Error interno al actualizar estado de lectura."),
            )
        }
    }
}
