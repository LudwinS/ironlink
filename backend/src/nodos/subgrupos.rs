use axum::Json;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::auth::verification::AppState;

// ─── DTOs ────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct CreateSubgrupoDto {
    pub nombre: String,
    pub descripcion: Option<String>,
    pub es_privado: Option<bool>,
}

#[derive(Serialize, Clone)]
pub struct SubgrupoInfo {
    pub id: Uuid,
    pub nodo_id: Uuid,
    pub nombre: String,
    pub descripcion: Option<String>,
    pub es_privado: bool,
    pub creado_por: Uuid,
    pub created_at: DateTime<Utc>,
    pub miembros_count: i64,
    pub is_member: bool,
    pub unread_count: i64,
}

#[derive(Serialize, Default)]
pub struct SubgrupoResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subgrupo: Option<SubgrupoInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subgrupos: Option<Vec<SubgrupoInfo>>,
}

#[derive(Serialize)]
pub struct SubgrupoMiembroInfo {
    pub user_id: Uuid,
    pub name: String,
    pub email: String,
    pub avatar_color: Option<String>,
    pub status_text: Option<String>,
    pub avatar_url: Option<String>,
    pub joined_at: DateTime<Utc>,
}

#[derive(Serialize, Default)]
pub struct SubgrupoMiembrosResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub miembros: Option<Vec<SubgrupoMiembroInfo>>,
}

// ─── POST /nodos/{id}/subgrupos ──────────────────────────────────────────

pub async fn create_subgrupo(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path(nodo_id): Path<Uuid>,
    Json(payload): Json<CreateSubgrupoDto>,
) -> (StatusCode, Json<SubgrupoResponse>) {
    // 1. Validar que el usuario pertenezca al nodo
    let is_member = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2)",
    )
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_one(&state.pool)
    .await
    .unwrap_or(false);

    if !is_member {
        return (
            StatusCode::FORBIDDEN,
            SubgrupoResponse::failure("No tienes permiso para crear subgrupos en este nodo."),
        );
    }

    let nombre = match super::validate_name(&payload.nombre, "subgrupo") {
        Ok(nombre) => nombre,
        Err(message) => return (StatusCode::BAD_REQUEST, SubgrupoResponse::failure(message)),
    };

    let es_privado = payload.es_privado.unwrap_or(false);

    // 2. Iniciar transacción
    let mut tx = match state.pool.begin().await {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Error iniciando tx en create_subgrupo: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                SubgrupoResponse::failure("Error interno al iniciar la creación del subgrupo."),
            );
        }
    };

    let insert_res = sqlx::query_as::<
        _,
        (
            Uuid,
            Uuid,
            String,
            Option<String>,
            bool,
            Uuid,
            DateTime<Utc>,
        ),
    >(
        "INSERT INTO subgrupos (nodo_id, nombre, descripcion, es_privado, creado_por) 
         VALUES ($1, $2, $3, $4, $5) 
         RETURNING id, nodo_id, nombre, descripcion, es_privado, creado_por, created_at",
    )
    .bind(nodo_id)
    .bind(nombre)
    .bind(&payload.descripcion)
    .bind(es_privado)
    .bind(auth_user.user_id)
    .fetch_one(&mut *tx)
    .await;

    match insert_res {
        Ok((id, n_id, nom, desc, priv_flag, creador, created_at)) => {
            // Añadir al creador como miembro del subgrupo
            if let Err(e) = sqlx::query(
                "INSERT INTO subgrupo_miembros (subgrupo_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING"
            )
            .bind(id)
            .bind(auth_user.user_id)
            .execute(&mut *tx)
            .await {
                eprintln!("Error agregando creador al subgrupo: {}", e);
                let _ = tx.rollback().await;
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    SubgrupoResponse::failure("Error al asociar al creador con el subgrupo."),
                );
            }

            if let Err(e) = tx.commit().await {
                eprintln!("Error al confirmar transacción de subgrupo: {}", e);
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    SubgrupoResponse::failure("Error al guardar el subgrupo."),
                );
            }

            (
                StatusCode::CREATED,
                Json(SubgrupoResponse {
                    success: true,
                    message: "Subgrupo creado exitosamente.".to_string(),
                    subgrupo: Some(SubgrupoInfo {
                        id,
                        nodo_id: n_id,
                        nombre: nom,
                        descripcion: desc,
                        es_privado: priv_flag,
                        creado_por: creador,
                        created_at,
                        miembros_count: 1,
                        is_member: true,
                        unread_count: 0,
                    }),
                    subgrupos: None,
                }),
            )
        }
        Err(e) => {
            eprintln!("Error al insertar subgrupo: {}", e);
            let _ = tx.rollback().await;
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                SubgrupoResponse::failure("Error interno al crear el subgrupo."),
            )
        }
    }
}

// ─── GET /nodos/{id}/subgrupos ───────────────────────────────────────────

pub async fn list_subgrupos(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path(nodo_id): Path<Uuid>,
) -> (StatusCode, Json<SubgrupoResponse>) {
    // 1. Validar que el usuario sea miembro del nodo
    let is_member = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2)",
    )
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_one(&state.pool)
    .await
    .unwrap_or(false);

    if !is_member {
        return (
            StatusCode::FORBIDDEN,
            SubgrupoResponse::failure("No perteneces a este nodo."),
        );
    }

    let query = "
        SELECT 
            s.id, 
            s.nodo_id, 
            s.nombre, 
            s.descripcion, 
            s.es_privado, 
            s.creado_por, 
            s.created_at,
            (SELECT COUNT(*) FROM subgrupo_miembros sm WHERE sm.subgrupo_id = s.id) AS miembros_count,
            EXISTS(SELECT 1 FROM subgrupo_miembros sm WHERE sm.subgrupo_id = s.id AND sm.user_id = $2) AS is_member,
            (
                SELECT COUNT(*)
                FROM mensajes m
                WHERE m.subgrupo_id = s.id
                  AND m.user_id != $2
                  AND m.created_at > COALESCE(
                      (SELECT sm.last_read_at FROM subgrupo_miembros sm WHERE sm.subgrupo_id = s.id AND sm.user_id = $2),
                      '1970-01-01'::timestamptz
                  )
            ) AS unread_count
        FROM subgrupos s
        WHERE s.nodo_id = $1 AND s.is_archived = FALSE
        ORDER BY s.created_at ASC
    ";

    let rows = sqlx::query_as::<
        _,
        (
            Uuid,
            Uuid,
            String,
            Option<String>,
            bool,
            Uuid,
            DateTime<Utc>,
            i64,
            bool,
            i64,
        ),
    >(query)
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_all(&state.pool)
    .await;

    match rows {
        Ok(list) => {
            let subgrupos = list
                .into_iter()
                .map(
                    |(
                        id,
                        n_id,
                        nom,
                        desc,
                        priv_flag,
                        creador,
                        created_at,
                        count,
                        is_mem,
                        unread,
                    )| SubgrupoInfo {
                        id,
                        nodo_id: n_id,
                        nombre: nom,
                        descripcion: desc,
                        es_privado: priv_flag,
                        creado_por: creador,
                        created_at,
                        miembros_count: count,
                        is_member: is_mem,
                        unread_count: unread,
                    },
                )
                .collect();

            (
                StatusCode::OK,
                Json(SubgrupoResponse {
                    success: true,
                    message: "Subgrupos listados exitosamente.".to_string(),
                    subgrupo: None,
                    subgrupos: Some(subgrupos),
                }),
            )
        }
        Err(e) => {
            eprintln!("Error al listar subgrupos: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                SubgrupoResponse::failure("Error interno al cargar los subgrupos."),
            )
        }
    }
}

// ─── POST /nodos/{id}/subgrupos/{subgrupo_id}/join ──────────────────────

pub async fn join_subgrupo(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path((nodo_id, subgrupo_id)): Path<(Uuid, Uuid)>,
) -> (StatusCode, Json<SubgrupoResponse>) {
    // 1. Validar que el usuario sea miembro del nodo principal
    let is_node_member = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2)",
    )
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_one(&state.pool)
    .await
    .unwrap_or(false);

    if !is_node_member {
        return (
            StatusCode::FORBIDDEN,
            SubgrupoResponse::failure("No perteneces al nodo principal."),
        );
    }

    // 2. BUG-S2-09 & BUG-S2-06: Verificar existencia del subgrupo, pertenencia al nodo, estado de archivo y privacidad
    let subgrupo = sqlx::query_as::<_, (bool, bool, Uuid)>(
        "SELECT es_privado, is_archived, creado_por FROM subgrupos WHERE id = $1 AND nodo_id = $2",
    )
    .bind(subgrupo_id)
    .bind(nodo_id)
    .fetch_optional(&state.pool)
    .await;

    match subgrupo {
        Ok(Some((_, true, _))) => {
            return (
                StatusCode::NOT_FOUND,
                SubgrupoResponse::failure("El subgrupo no existe o ha sido archivado."),
            );
        }
        Ok(Some((true, false, creado_por))) => {
            // Validar si el usuario es el creador o ADMIN/OWNER del nodo
            let is_admin_or_owner = sqlx::query_scalar::<_, bool>(
                "SELECT EXISTS(SELECT 1 FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2 AND rol IN ('ADMIN', 'OWNER'))"
            )
            .bind(nodo_id)
            .bind(auth_user.user_id)
            .fetch_one(&state.pool)
            .await
            .unwrap_or(false);

            if auth_user.user_id != creado_por && !is_admin_or_owner {
                return (
                    StatusCode::FORBIDDEN,
                    SubgrupoResponse::failure(
                        "Este subgrupo es privado y no permite la auto-adhesión directa sin invitación previa.",
                    ),
                );
            }
        }
        Ok(Some((false, false, _))) => {
            // Subgrupo público: acceso permitido
        }
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                SubgrupoResponse::failure("Subgrupo no encontrado en este nodo."),
            );
        }
        Err(e) => {
            eprintln!("Error al verificar subgrupo: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                SubgrupoResponse::failure("Error interno al verificar el subgrupo."),
            );
        }
    }

    // 3. Insertar en subgrupo_miembros
    let result = sqlx::query(
        "INSERT INTO subgrupo_miembros (subgrupo_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING"
    )
    .bind(subgrupo_id)
    .bind(auth_user.user_id)
    .execute(&state.pool)
    .await;

    match result {
        Ok(_) => (
            StatusCode::OK,
            Json(SubgrupoResponse {
                success: true,
                message: "Te has unido al subgrupo exitosamente.".to_string(),
                subgrupo: None,
                subgrupos: None,
            }),
        ),
        Err(e) => {
            eprintln!("Error al unirse al subgrupo: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                SubgrupoResponse::failure("Error interno al unirse al subgrupo."),
            )
        }
    }
}

// ─── POST /nodos/{id}/subgrupos/{subgrupo_id}/leave ─────────────────────

pub async fn leave_subgrupo(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path((_nodo_id, subgrupo_id)): Path<(Uuid, Uuid)>,
) -> (StatusCode, Json<SubgrupoResponse>) {
    let result =
        sqlx::query("DELETE FROM subgrupo_miembros WHERE subgrupo_id = $1 AND user_id = $2")
            .bind(subgrupo_id)
            .bind(auth_user.user_id)
            .execute(&state.pool)
            .await;

    match result {
        Ok(_) => (
            StatusCode::OK,
            Json(SubgrupoResponse {
                success: true,
                message: "Has salido del subgrupo.".to_string(),
                subgrupo: None,
                subgrupos: None,
            }),
        ),
        Err(e) => {
            eprintln!("Error al salir del subgrupo: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                SubgrupoResponse::failure("Error interno al salir del subgrupo."),
            )
        }
    }
}

// ─── DELETE /nodos/{id}/subgrupos/{subgrupo_id} ─────────────────────────

pub async fn delete_subgrupo(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path((nodo_id, subgrupo_id)): Path<(Uuid, Uuid)>,
) -> (StatusCode, Json<SubgrupoResponse>) {
    // 1. Validar que el usuario sea el creador del subgrupo o ADMIN/OWNER del nodo
    let is_creator_or_admin = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(
            SELECT 1 FROM subgrupos s 
            LEFT JOIN nodo_miembros nm ON nm.nodo_id = s.nodo_id AND nm.user_id = $2
            WHERE s.id = $1 AND (s.creado_por = $2 OR nm.rol IN ('ADMIN', 'OWNER')) AND s.is_archived = FALSE
        )"
    )
    .bind(subgrupo_id)
    .bind(auth_user.user_id)
    .fetch_one(&state.pool)
    .await
    .unwrap_or(false);

    if !is_creator_or_admin {
        return (
            StatusCode::FORBIDDEN,
            SubgrupoResponse::failure(
                "No tienes permiso para eliminar este subgrupo o ya fue archivado.",
            ),
        );
    }

    // 2. BUG-S2-06: Soft-delete (archivado lógico) en lugar de DELETE directo para auditoría histórica
    let result = sqlx::query(
        "UPDATE subgrupos SET is_archived = TRUE WHERE id = $1 AND nodo_id = $2 AND is_archived = FALSE"
    )
    .bind(subgrupo_id)
    .bind(nodo_id)
    .execute(&state.pool)
    .await;

    match result {
        Ok(r) => {
            if r.rows_affected() == 0 {
                (
                    StatusCode::NOT_FOUND,
                    SubgrupoResponse::failure("Subgrupo no encontrado o ya archivado."),
                )
            } else {
                (
                    StatusCode::OK,
                    Json(SubgrupoResponse {
                        success: true,
                        message: "Subgrupo eliminado exitosamente.".to_string(),
                        subgrupo: None,
                        subgrupos: None,
                    }),
                )
            }
        }
        Err(e) => {
            eprintln!("Error al eliminar/archivar subgrupo: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                SubgrupoResponse::failure("Error interno al eliminar el subgrupo."),
            )
        }
    }
}

// ─── GET /nodos/{id}/subgrupos/{subgrupo_id}/miembros ───────────────────

pub async fn list_subgrupo_miembros(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path((nodo_id, subgrupo_id)): Path<(Uuid, Uuid)>,
) -> (StatusCode, Json<SubgrupoMiembrosResponse>) {
    // 1. Validar que el usuario pertenezca al nodo
    let is_member = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2)",
    )
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_one(&state.pool)
    .await
    .unwrap_or(false);

    if !is_member {
        return (
            StatusCode::FORBIDDEN,
            SubgrupoMiembrosResponse::failure("No perteneces a este nodo."),
        );
    }

    let rows = sqlx::query_as::<
        _,
        (
            Uuid,
            String,
            String,
            Option<String>,
            Option<String>,
            Option<String>,
            DateTime<Utc>,
        ),
    >(
        "SELECT u.id, u.name, u.email, u.avatar_color, u.status_text, u.avatar_url, sm.created_at
         FROM subgrupo_miembros sm
         JOIN users u ON sm.user_id = u.id
         JOIN subgrupos s ON s.id = sm.subgrupo_id AND s.nodo_id = $2 AND s.is_archived = FALSE
         WHERE sm.subgrupo_id = $1
         -- Un subgrupo privado solo muestra sus miembros a quien pertenece o administra el nodo.
         AND (NOT s.es_privado
              OR EXISTS (SELECT 1 FROM subgrupo_miembros me WHERE me.subgrupo_id = s.id AND me.user_id = $3)
              OR EXISTS (SELECT 1 FROM nodo_miembros nm WHERE nm.nodo_id = s.nodo_id AND nm.user_id = $3 AND nm.rol IN ('ADMIN', 'OWNER')))
         ORDER BY sm.created_at ASC",
    )
    .bind(subgrupo_id)
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_all(&state.pool)
    .await;

    match rows {
        Ok(list) => {
            let miembros = list
                .into_iter()
                .map(
                    |(uid, name, email, color, status, url, joined)| SubgrupoMiembroInfo {
                        user_id: uid,
                        name,
                        email,
                        avatar_color: color,
                        status_text: status,
                        avatar_url: url,
                        joined_at: joined,
                    },
                )
                .collect();

            (
                StatusCode::OK,
                Json(SubgrupoMiembrosResponse {
                    success: true,
                    message: "Miembros del subgrupo listados exitosamente.".to_string(),
                    miembros: Some(miembros),
                }),
            )
        }
        Err(e) => {
            eprintln!("Error al listar miembros de subgrupo: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                SubgrupoMiembrosResponse::failure(
                    "Error interno al cargar los miembros del subgrupo.",
                ),
            )
        }
    }
}

// ─── DTOs de Actualización y Asignación de Miembros (IRL-WKS-US-02) ────────

#[derive(Deserialize)]
pub struct UpdateSubgrupoDto {
    pub nombre: Option<String>,
    pub descripcion: Option<String>,
}

#[derive(Deserialize)]
pub struct AsignarMiembrosDto {
    pub user_ids: Vec<Uuid>,
}

#[derive(Serialize)]
pub struct AsignarMiembrosResponse {
    pub success: bool,
    pub message: String,
    pub asignados_count: usize,
}

// ─── PUT /nodos/{id}/subgrupos/{subgrupo_id} ──────────────────────────────

pub async fn update_subgrupo(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path((nodo_id, subgrupo_id)): Path<(Uuid, Uuid)>,
    Json(payload): Json<UpdateSubgrupoDto>,
) -> (StatusCode, Json<SubgrupoResponse>) {
    // 1. Validar que el usuario sea creador del subgrupo, o OWNER/ADMIN del nodo
    let member_role = sqlx::query_scalar::<_, String>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await
    .unwrap_or(None);

    let sub_creator = sqlx::query_scalar::<_, Uuid>(
        "SELECT creado_por FROM subgrupos WHERE id = $1 AND nodo_id = $2 AND is_archived = FALSE",
    )
    .bind(subgrupo_id)
    .bind(nodo_id)
    .fetch_optional(&state.pool)
    .await
    .unwrap_or(None);

    let sub_creator_id = match sub_creator {
        Some(cid) => cid,
        None => {
            return (
                StatusCode::NOT_FOUND,
                SubgrupoResponse::failure("El subgrupo no existe o ha sido archivado."),
            );
        }
    };

    let nodo_creator = sqlx::query_scalar::<_, Uuid>("SELECT creador_id FROM nodos WHERE id = $1")
        .bind(nodo_id)
        .fetch_optional(&state.pool)
        .await
        .unwrap_or(None);

    let can_edit = auth_user.role == "ADMIN"
        || sub_creator_id == auth_user.user_id
        || nodo_creator == Some(auth_user.user_id)
        || member_role.as_deref() == Some("OWNER")
        || member_role.as_deref() == Some("ADMIN");

    if !can_edit {
        return (
            StatusCode::FORBIDDEN,
            SubgrupoResponse::failure("No tienes permisos para editar este subgrupo."),
        );
    }

    let nombre = match payload
        .nombre
        .as_deref()
        .map(|nombre| super::validate_name(nombre, "subgrupo"))
        .transpose()
    {
        Ok(nombre) => nombre,
        Err(message) => return (StatusCode::BAD_REQUEST, SubgrupoResponse::failure(message)),
    };
    let descripcion = payload.descripcion.as_deref().map(str::trim);

    let update = sqlx::query_as::<
        _,
        (
            Uuid,
            Uuid,
            String,
            Option<String>,
            bool,
            Uuid,
            DateTime<Utc>,
        ),
    >(
        r#"
        UPDATE subgrupos
        SET nombre = COALESCE($1, nombre),
            descripcion = COALESCE($2, descripcion)
        WHERE id = $3 AND nodo_id = $4 AND is_archived = FALSE
        RETURNING id, nodo_id, nombre, descripcion, es_privado, creado_por, created_at
        "#,
    )
    .bind(nombre)
    .bind(descripcion)
    .bind(subgrupo_id)
    .bind(nodo_id)
    .fetch_optional(&state.pool)
    .await;

    match update {
        Ok(Some((id, nid, nom, desc, es_priv, creado, cat))) => {
            let m_count = sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM subgrupo_miembros WHERE subgrupo_id = $1",
            )
            .bind(id)
            .fetch_one(&state.pool)
            .await
            .unwrap_or(0);

            let is_member = sqlx::query_scalar::<_, bool>(
                "SELECT EXISTS(SELECT 1 FROM subgrupo_miembros WHERE subgrupo_id = $1 AND user_id = $2)"
            )
            .bind(id)
            .bind(auth_user.user_id)
            .fetch_one(&state.pool)
            .await
            .unwrap_or(false);

            (
                StatusCode::OK,
                Json(SubgrupoResponse {
                    success: true,
                    message: "Subgrupo actualizado exitosamente.".to_string(),
                    subgrupo: Some(SubgrupoInfo {
                        id,
                        nodo_id: nid,
                        nombre: nom,
                        descripcion: desc,
                        es_privado: es_priv,
                        creado_por: creado,
                        created_at: cat,
                        miembros_count: m_count,
                        is_member,
                        unread_count: 0,
                    }),
                    subgrupos: None,
                }),
            )
        }
        Ok(None) => (
            StatusCode::NOT_FOUND,
            SubgrupoResponse::failure("Subgrupo no encontrado."),
        ),
        Err(e) => {
            eprintln!("Error al actualizar subgrupo: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                SubgrupoResponse::failure("Error interno al actualizar subgrupo."),
            )
        }
    }
}

// ─── POST /nodos/{id}/subgrupos/{subgrupo_id}/asignar-miembros ────────────

pub async fn asignar_miembros_subgrupo(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Path((nodo_id, subgrupo_id)): Path<(Uuid, Uuid)>,
    Json(payload): Json<AsignarMiembrosDto>,
) -> (StatusCode, Json<AsignarMiembrosResponse>) {
    // 1. Validar permisos (creador del subgrupo, OWNER/ADMIN del nodo o Global Admin)
    let member_role = sqlx::query_scalar::<_, String>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await
    .unwrap_or(None);

    let sub_creator = sqlx::query_scalar::<_, Uuid>(
        "SELECT creado_por FROM subgrupos WHERE id = $1 AND nodo_id = $2 AND is_archived = FALSE",
    )
    .bind(subgrupo_id)
    .bind(nodo_id)
    .fetch_optional(&state.pool)
    .await
    .unwrap_or(None);

    let sub_creator_id = match sub_creator {
        Some(cid) => cid,
        None => {
            return (
                StatusCode::NOT_FOUND,
                Json(AsignarMiembrosResponse {
                    success: false,
                    message: "El subgrupo no existe o está archivado.".to_string(),
                    asignados_count: 0,
                }),
            );
        }
    };

    let can_assign = auth_user.role == "ADMIN"
        || sub_creator_id == auth_user.user_id
        || member_role.as_deref() == Some("OWNER")
        || member_role.as_deref() == Some("ADMIN");

    if !can_assign {
        return (
            StatusCode::FORBIDDEN,
            Json(AsignarMiembrosResponse {
                success: false,
                message: "No tienes permisos para asignar miembros a este subgrupo.".to_string(),
                asignados_count: 0,
            }),
        );
    }

    // Una sola sentencia: atómica (todo o nada) y solo con integrantes del
    // nodo. Antes eran dos consultas por persona sin transacción, que dejaban
    // asignaciones a medias y respondían «éxito» aunque fallara la base.
    let added = match sqlx::query(
        "INSERT INTO subgrupo_miembros (subgrupo_id, user_id, created_at)
         SELECT $1, nm.user_id, NOW() FROM nodo_miembros nm
         WHERE nm.nodo_id = $2 AND nm.user_id = ANY($3)
         ON CONFLICT DO NOTHING",
    )
    .bind(subgrupo_id)
    .bind(nodo_id)
    .bind(&payload.user_ids)
    .execute(&state.pool)
    .await
    {
        Ok(result) => result.rows_affected() as _,
        Err(e) => {
            eprintln!("Error al asignar miembros al subgrupo: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(AsignarMiembrosResponse {
                    success: false,
                    message: "No se pudieron asignar los miembros.".to_string(),
                    asignados_count: 0,
                }),
            );
        }
    };

    (
        StatusCode::OK,
        Json(AsignarMiembrosResponse {
            success: true,
            message: format!("Se han asignado {} miembros al subgrupo.", added),
            asignados_count: added,
        }),
    )
}

crate::response::failure_response!(SubgrupoResponse, SubgrupoMiembrosResponse);
