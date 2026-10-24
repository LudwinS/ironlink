use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use rand::Rng;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::middleware::AuthUser;
use crate::auth::verification::AppState;

// ─── DTOs ────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct CreateNodoDto {
    pub nombre: String,
    pub descripcion: Option<String>,
}

#[derive(Serialize, Default)]
pub struct NodoResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nodo: Option<NodoInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nodos: Option<Vec<NodoInfo>>,
}

#[derive(Serialize, Clone)]
pub struct NodoInfo {
    pub id: Uuid,
    pub nombre: String,
    pub descripcion: Option<String>,
    pub token_acceso: String,
    pub creador_id: Uuid,
    pub estado: String,
    pub rol: Option<String>,
    pub miembros_count: i64,
}

/// Genera un token de acceso aleatorio de 32 caracteres hexadecimales
fn generate_access_token() -> String {
    let mut rng = rand::thread_rng();
    let mut bytes = [0u8; 16];
    rng.fill(&mut bytes);
    hex::encode(bytes)
}

// ─── POST /nodos ─────────────────────────────────────────────────────────

pub async fn create_nodo(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    Json(payload): Json<CreateNodoDto>,
) -> (StatusCode, Json<NodoResponse>) {
    let nombre = match super::validate_name(&payload.nombre, "nodo") {
        Ok(nombre) => nombre,
        Err(message) => return (StatusCode::BAD_REQUEST, NodoResponse::failure(message)),
    };
    let token_acceso = generate_access_token();

    // Iniciar transacción
    let mut tx = match state.pool.begin().await {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Error al iniciar transacción al crear nodo: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                NodoResponse::failure("Error interno al iniciar la creación del nodo."),
            );
        }
    };

    let result = sqlx::query_as::<_, (Uuid, String, Option<String>, String, Uuid, String)>(
        "INSERT INTO nodos (nombre, descripcion, token_acceso, creador_id) VALUES ($1, $2, $3, $4) RETURNING id, nombre, descripcion, token_acceso, creador_id, estado"
    )
    .bind(nombre)
    .bind(&payload.descripcion)
    .bind(&token_acceso)
    .bind(auth_user.user_id)
    .fetch_one(&mut *tx)
    .await;

    match result {
        Ok((id, nombre, descripcion, token_acceso, creador_id, estado)) => {
            // También agregar al creador como miembro con rol OWNER
            let member_result = sqlx::query(
                "INSERT INTO nodo_miembros (nodo_id, user_id, rol) VALUES ($1, $2, 'OWNER')",
            )
            .bind(id)
            .bind(auth_user.user_id)
            .execute(&mut *tx)
            .await;

            if let Err(e) = member_result {
                eprintln!("Error al asociar miembro creador: {}", e);
                let _ = tx.rollback().await;
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    NodoResponse::failure("Error interno al asociar el creador al nodo."),
                );
            }

            if let Err(e) = tx.commit().await {
                eprintln!("Error al confirmar transacción del nodo: {}", e);
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    NodoResponse::failure("Error interno al confirmar la creación del nodo."),
                );
            }

            (
                StatusCode::CREATED,
                Json(NodoResponse {
                    success: true,
                    message: "Nodo creado exitosamente.".to_string(),
                    nodo: Some(NodoInfo {
                        id,
                        nombre,
                        descripcion,
                        token_acceso,
                        creador_id,
                        estado,
                        rol: Some("OWNER".to_string()),
                        miembros_count: 1,
                    }),
                    nodos: None,
                }),
            )
        }
        Err(e) => {
            eprintln!("Error al crear nodo: {}", e);
            let _ = tx.rollback().await;
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                NodoResponse::failure("Error interno al crear el nodo."),
            )
        }
    }
}

// ─── GET /nodos ──────────────────────────────────────────────────────────

pub async fn list_nodos(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
) -> (StatusCode, Json<NodoResponse>) {
    // Obtener nodos donde el usuario es miembro o creador, contando sus participantes
    let rows = sqlx::query_as::<
        _,
        (
            Uuid,
            String,
            Option<String>,
            String,
            Uuid,
            String,
            String,
            i64,
        ),
    >(
        r#"
        SELECT n.id, n.nombre, n.descripcion, n.token_acceso, n.creador_id, n.estado, nm.rol,
               (SELECT COUNT(*) FROM nodo_miembros WHERE nodo_id = n.id) as miembros_count
        FROM nodos n
        INNER JOIN nodo_miembros nm ON n.id = nm.nodo_id
        WHERE nm.user_id = $1
        ORDER BY n.created_at DESC
        "#,
    )
    .bind(auth_user.user_id)
    .fetch_all(&state.pool)
    .await;

    match rows {
        Ok(nodos) => {
            let nodo_list: Vec<NodoInfo> = nodos
                .into_iter()
                .map(
                    |(
                        id,
                        nombre,
                        descripcion,
                        token_acceso,
                        creador_id,
                        estado,
                        rol,
                        miembros_count,
                    )| {
                        NodoInfo {
                            id,
                            nombre,
                            descripcion,
                            token_acceso,
                            creador_id,
                            estado,
                            rol: Some(rol),
                            miembros_count,
                        }
                    },
                )
                .collect();

            (
                StatusCode::OK,
                Json(NodoResponse {
                    success: true,
                    message: format!("Se encontraron {} nodo(s).", nodo_list.len()),
                    nodo: None,
                    nodos: Some(nodo_list),
                }),
            )
        }
        Err(e) => {
            eprintln!("Error al listar nodos: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                NodoResponse::failure("Error interno al listar los nodos."),
            )
        }
    }
}

// ─── POST /nodos/join/:token ─────────────────────────────────────────────

pub async fn join_nodo(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::extract::Path(token): axum::extract::Path<String>,
) -> (StatusCode, Json<NodoResponse>) {
    // 1. Buscar nodo por token de acceso
    let nodo = sqlx::query_as::<_, (Uuid, String, Option<String>, String, Uuid, String)>(
        "SELECT id, nombre, descripcion, token_acceso, creador_id, estado FROM nodos WHERE token_acceso = $1 AND estado = 'active'"
    )
    .bind(&token)
    .fetch_optional(&state.pool)
    .await;

    let (nodo_id, nombre, descripcion, token_acceso, creador_id, estado) = match nodo {
        Ok(Some(n)) => n,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                NodoResponse::failure("No se encontró un nodo activo con ese token de acceso."),
            );
        }
        Err(e) => {
            eprintln!("Error al buscar nodo: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                NodoResponse::failure("Error interno al buscar el nodo."),
            );
        }
    };

    // 1.5. Verificar si el usuario está baneado de este nodo
    let ban_check = sqlx::query_as::<_, (Uuid,)>(
        "SELECT user_id FROM nodo_baneos WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await;

    if let Ok(Some(_)) = ban_check {
        return (
            StatusCode::FORBIDDEN,
            NodoResponse::failure("Has sido baneado de este nodo y no puedes volver a unirte."),
        );
    }

    // 2. Verificar si ya es miembro
    let existing = sqlx::query_as::<_, (String,)>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await;

    if let Ok(Some(_)) = existing {
        return (
            StatusCode::CONFLICT,
            NodoResponse::failure("Ya eres miembro de este nodo."),
        );
    }

    // 3. Agregar como miembro
    let insert =
        sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id, rol) VALUES ($1, $2, 'MEMBER')")
            .bind(nodo_id)
            .bind(auth_user.user_id)
            .execute(&state.pool)
            .await;

    match insert {
        Ok(_) => {
            // Contar el número total de miembros después de unirse
            let count_row = sqlx::query_as::<_, (i64,)>(
                "SELECT COUNT(*) FROM nodo_miembros WHERE nodo_id = $1",
            )
            .bind(nodo_id)
            .fetch_one(&state.pool)
            .await;

            let miembros_count = count_row.map(|r| r.0).unwrap_or(1);

            (
                StatusCode::OK,
                Json(NodoResponse {
                    success: true,
                    message: "Te has unido al nodo exitosamente.".to_string(),
                    nodo: Some(NodoInfo {
                        id: nodo_id,
                        nombre,
                        descripcion,
                        token_acceso,
                        creador_id,
                        estado,
                        rol: Some("MEMBER".to_string()),
                        miembros_count,
                    }),
                    nodos: None,
                }),
            )
        }
        Err(e) => {
            eprintln!("Error al unirse al nodo: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                NodoResponse::failure("Error interno al unirse al nodo."),
            )
        }
    }
}

// ─── DELETE /nodos/{id} ──────────────────────────────────────────────────

pub async fn delete_nodo(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::extract::Path(id): axum::extract::Path<Uuid>,
) -> (StatusCode, Json<NodoResponse>) {
    // 1. Verificar si el nodo existe y quién es el creador
    let creator_check = sqlx::query_as::<_, (Uuid,)>("SELECT creador_id FROM nodos WHERE id = $1")
        .bind(id)
        .fetch_optional(&state.pool)
        .await;

    let creador_id = match creator_check {
        Ok(Some((c_id,))) => c_id,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                NodoResponse::failure("No se encontró el nodo especificado."),
            );
        }
        Err(e) => {
            eprintln!("Error al verificar el creador del nodo: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                NodoResponse::failure("Error interno al verificar el nodo."),
            );
        }
    };

    // 2. Comprobar permisos (Creador del nodo, rol OWNER en nodo_miembros, o ADMIN global)
    let is_owner = creador_id == auth_user.user_id;
    let is_global_admin = auth_user.role == "ADMIN";

    let member_role = sqlx::query_scalar::<_, String>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await
    .unwrap_or(None);

    let is_node_owner = member_role.as_deref() == Some("OWNER") || is_owner || is_global_admin;

    if !is_node_owner {
        return (
            StatusCode::FORBIDDEN,
            NodoResponse::failure(
                "Solo el propietario (OWNER) de este nodo o un administrador puede eliminarlo.",
            ),
        );
    }

    // 3. Eliminar el nodo (el ON DELETE CASCADE se encargará de nodo_miembros)
    let delete_result = sqlx::query("DELETE FROM nodos WHERE id = $1")
        .bind(id)
        .execute(&state.pool)
        .await;

    match delete_result {
        Ok(_) => (
            StatusCode::OK,
            Json(NodoResponse {
                success: true,
                message: "Nodo eliminado exitosamente.".to_string(),
                nodo: None,
                nodos: None,
            }),
        ),
        Err(e) => {
            eprintln!("Error al eliminar el nodo: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                NodoResponse::failure("Error interno al eliminar el nodo."),
            )
        }
    }
}

// ─── DTOs de miembros y roles ────────────────────────────────────────────

#[derive(Serialize)]
pub struct NodoMiembroInfo {
    pub user_id: Uuid,
    pub name: String,
    pub email: String,
    pub rol: String,
    pub avatar_color: Option<String>,
    pub status_text: Option<String>,
    pub avatar_url: Option<String>,
}

#[derive(Serialize)]
pub struct MiembrosResponse {
    pub success: bool,
    pub message: String,
    pub miembros: Vec<NodoMiembroInfo>,
}

#[derive(Deserialize)]
pub struct UpdateRolDto {
    pub rol: String,
}

#[derive(Serialize, Default)]
pub struct UpdateRolResponse {
    pub success: bool,
    pub message: String,
}

// ─── GET /nodos/{id}/miembros ─────────────────────────────────────────────

pub async fn list_miembros(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::extract::Path(id): axum::extract::Path<Uuid>,
) -> (StatusCode, Json<MiembrosResponse>) {
    // 1. Verificar si el usuario actual es miembro del nodo
    let member_check = sqlx::query_as::<_, (String,)>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await;

    if let Err(e) = member_check {
        eprintln!("Error al verificar membresía: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(MiembrosResponse {
                success: false,
                message: "Error interno al verificar permisos.".to_string(),
                miembros: vec![],
            }),
        );
    }

    let is_member = member_check.unwrap();
    if is_member.is_none() && auth_user.role != "ADMIN" {
        return (
            StatusCode::FORBIDDEN,
            Json(MiembrosResponse {
                success: false,
                message: "No tienes permiso para ver los miembros de este nodo.".to_string(),
                miembros: vec![],
            }),
        );
    }

    // 2. Obtener lista de miembros con avatar y estado de presencia
    let rows = sqlx::query_as::<
        _,
        (
            Uuid,
            String,
            String,
            String,
            Option<String>,
            Option<String>,
            Option<String>,
        ),
    >(
        r#"
        SELECT u.id, u.name, u.email, nm.rol, u.avatar_color, u.status_text, u.avatar_url
        FROM nodo_miembros nm
        INNER JOIN users u ON nm.user_id = u.id
        WHERE nm.nodo_id = $1
        ORDER BY 
            CASE nm.rol
                WHEN 'OWNER' THEN 1
                WHEN 'ADMIN' THEN 2
                ELSE 3
            END,
            u.name ASC
        "#,
    )
    .bind(id)
    .fetch_all(&state.pool)
    .await;

    match rows {
        Ok(miembros) => {
            let list = miembros
                .into_iter()
                .map(
                    |(user_id, name, email, rol, avatar_color, status_text, avatar_url)| {
                        NodoMiembroInfo {
                            user_id,
                            name,
                            email,
                            rol,
                            avatar_color,
                            status_text,
                            avatar_url,
                        }
                    },
                )
                .collect();

            (
                StatusCode::OK,
                Json(MiembrosResponse {
                    success: true,
                    message: "Miembros cargados exitosamente.".to_string(),
                    miembros: list,
                }),
            )
        }
        Err(e) => {
            eprintln!("Error al obtener miembros del nodo: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(MiembrosResponse {
                    success: false,
                    message: "Error interno al obtener la lista de miembros.".to_string(),
                    miembros: vec![],
                }),
            )
        }
    }
}

// ─── PUT /nodos/{id}/miembros/{target_user_id}/rol ─────────────────────────

pub async fn update_miembro_rol(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::extract::Path((nodo_id, target_user_id)): axum::extract::Path<(Uuid, Uuid)>,
    Json(payload): Json<UpdateRolDto>,
) -> (StatusCode, Json<UpdateRolResponse>) {
    // 1. Validar el rol solicitado (solo ADMIN o MEMBER se pueden asignar)
    let nuevo_rol = payload.rol.trim().to_uppercase();
    if nuevo_rol != "ADMIN" && nuevo_rol != "MEMBER" {
        return (
            StatusCode::BAD_REQUEST,
            UpdateRolResponse::failure("Rol no permitido. Solo se puede asignar ADMIN o MEMBER."),
        );
    }

    // 2. Verificar que el usuario actual sea el OWNER del nodo o un administrador global
    let current_user_check = sqlx::query_as::<_, (String,)>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await;

    let can_update = match current_user_check {
        Ok(Some((rol,))) => rol == "OWNER" || auth_user.role == "ADMIN",
        _ => auth_user.role == "ADMIN",
    };

    if !can_update {
        return (
            StatusCode::FORBIDDEN,
            UpdateRolResponse::failure("Solo el creador (OWNER) del nodo puede designar roles."),
        );
    }

    // 3. Verificar que el usuario objetivo pertenezca al nodo y no sea el OWNER
    let target_user_check = sqlx::query_as::<_, (String,)>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(nodo_id)
    .bind(target_user_id)
    .fetch_optional(&state.pool)
    .await;

    match target_user_check {
        Ok(Some((rol,))) => {
            if rol == "OWNER" {
                return (
                    StatusCode::BAD_REQUEST,
                    UpdateRolResponse::failure(
                        "No se puede modificar el rol del creador del nodo.",
                    ),
                );
            }
        }
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                UpdateRolResponse::failure("El usuario objetivo no es miembro de este nodo."),
            );
        }
        Err(e) => {
            eprintln!("Error al verificar usuario objetivo: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                UpdateRolResponse::failure("Error interno al verificar el miembro."),
            );
        }
    }

    // 4. Actualizar el rol
    let update_result =
        sqlx::query("UPDATE nodo_miembros SET rol = $1 WHERE nodo_id = $2 AND user_id = $3")
            .bind(&nuevo_rol)
            .bind(nodo_id)
            .bind(target_user_id)
            .execute(&state.pool)
            .await;

    match update_result {
        Ok(_) => (
            StatusCode::OK,
            Json(UpdateRolResponse {
                success: true,
                message: format!("Rol actualizado a {} exitosamente.", nuevo_rol),
            }),
        ),
        Err(e) => {
            eprintln!("Error al actualizar el rol del miembro: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                UpdateRolResponse::failure("Error interno al actualizar el rol."),
            )
        }
    }
}

// ─── POST /nodos/{id}/leave ──────────────────────────────────────────────

/// Quita a una persona del nodo y de todos sus subgrupos en la misma
/// transacción. Sin esto, al volver a unirse con el token recuperaba el
/// acceso a subgrupos privados sin invitación.
async fn remove_membership(
    conn: &mut sqlx::PgConnection,
    nodo: Uuid,
    user: Uuid,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "DELETE FROM subgrupo_miembros sm USING subgrupos s
         WHERE sm.subgrupo_id = s.id AND s.nodo_id = $1 AND sm.user_id = $2",
    )
    .bind(nodo)
    .bind(user)
    .execute(&mut *conn)
    .await?;
    sqlx::query("DELETE FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2")
        .bind(nodo)
        .bind(user)
        .execute(&mut *conn)
        .await?;
    Ok(())
}

/// `remove_membership` en su propia transacción.
async fn remove_membership_tx(
    pool: &sqlx::PgPool,
    nodo: Uuid,
    user: Uuid,
) -> Result<(), sqlx::Error> {
    let mut tx = pool.begin().await?;
    remove_membership(&mut tx, nodo, user).await?;
    tx.commit().await
}

pub async fn leave_nodo(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::extract::Path(id): axum::extract::Path<Uuid>,
) -> (StatusCode, Json<NodoResponse>) {
    // 1. Verificar si el usuario es miembro y obtener su rol
    let member_check = sqlx::query_as::<_, (String,)>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await;

    let rol = match member_check {
        Ok(Some((r,))) => r,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                NodoResponse::failure("No eres miembro de este nodo."),
            );
        }
        Err(e) => {
            eprintln!("Error al verificar membresía para salir del nodo: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                NodoResponse::failure("Error interno al verificar membresía."),
            );
        }
    };

    // 2. Si es OWNER, no puede salir de esta forma (debe eliminar el nodo o transferir propiedad)
    if rol == "OWNER" {
        return (
            StatusCode::BAD_REQUEST,
            NodoResponse::failure(
                "El creador/propietario no puede salir del nodo. Debes eliminar el nodo.",
            ),
        );
    }

    // 3. Eliminar de nodo_miembros
    let delete_result = remove_membership_tx(&state.pool, id, auth_user.user_id).await;

    match delete_result {
        Ok(_) => (
            StatusCode::OK,
            Json(NodoResponse {
                success: true,
                message: "Has salido del nodo exitosamente.".to_string(),
                nodo: None,
                nodos: None,
            }),
        ),
        Err(e) => {
            eprintln!("Error al salir del nodo: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                NodoResponse::failure("Error interno al salir del nodo."),
            )
        }
    }
}

// ─── DELETE /nodos/{id}/miembros/{user_id} ────────────────────────────────

pub async fn kick_miembro(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::extract::Path((nodo_id, target_user_id)): axum::extract::Path<(Uuid, Uuid)>,
) -> (StatusCode, Json<UpdateRolResponse>) {
    // 1. No se puede expulsar a sí mismo
    if auth_user.user_id == target_user_id {
        return (
            StatusCode::BAD_REQUEST,
            UpdateRolResponse::failure(
                "No puedes expulsarte a ti mismo del nodo. Debes usar la opción de salir.",
            ),
        );
    }

    // 2. Obtener rol del usuario actual en el nodo
    let current_user_check = sqlx::query_as::<_, (String,)>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await;

    let current_rol = match current_user_check {
        Ok(Some((rol,))) => rol,
        _ => {
            if auth_user.role == "ADMIN" {
                "GLOBAL_ADMIN".to_string()
            } else {
                return (
                    StatusCode::FORBIDDEN,
                    UpdateRolResponse::failure(
                        "No eres miembro de este nodo ni administrador global.",
                    ),
                );
            }
        }
    };

    // 3. Obtener rol del usuario objetivo
    let target_user_check = sqlx::query_as::<_, (String,)>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(nodo_id)
    .bind(target_user_id)
    .fetch_optional(&state.pool)
    .await;

    let target_rol = match target_user_check {
        Ok(Some((rol,))) => rol,
        Ok(None) => {
            return (
                StatusCode::NOT_FOUND,
                UpdateRolResponse::failure("El usuario objetivo no es miembro de este nodo."),
            );
        }
        Err(e) => {
            eprintln!("Error al verificar usuario objetivo para expulsar: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                UpdateRolResponse::failure("Error interno al verificar el miembro."),
            );
        }
    };

    // 4. Validar permisos de jerarquía
    // - El OWNER o ADMIN GLOBAL puede expulsar a cualquiera
    // - Un ADMIN de nodo puede expulsar a un MEMBER, pero no a otro ADMIN ni al OWNER
    let is_authorized = if current_rol == "OWNER" || current_rol == "GLOBAL_ADMIN" {
        true
    } else if current_rol == "ADMIN" {
        target_rol == "MEMBER"
    } else {
        false
    };

    if !is_authorized {
        return (
            StatusCode::FORBIDDEN,
            UpdateRolResponse::failure(
                "No tienes permisos suficientes para expulsar a este usuario.",
            ),
        );
    }

    // 5. Eliminar de la base de datos
    let delete_result = remove_membership_tx(&state.pool, nodo_id, target_user_id).await;

    match delete_result {
        Ok(_) => (
            StatusCode::OK,
            Json(UpdateRolResponse {
                success: true,
                message: "Miembro expulsado del nodo exitosamente.".to_string(),
            }),
        ),
        Err(e) => {
            eprintln!("Error al expulsar miembro: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                UpdateRolResponse::failure("Error interno al expulsar al miembro."),
            )
        }
    }
}

// ─── POST /nodos/{id}/miembros/{user_id}/ban ─────────────────────────────

pub async fn ban_miembro(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::extract::Path((nodo_id, target_user_id)): axum::extract::Path<(Uuid, Uuid)>,
) -> (StatusCode, Json<UpdateRolResponse>) {
    // 1. No se puede banear a sí mismo
    if auth_user.user_id == target_user_id {
        return (
            StatusCode::BAD_REQUEST,
            UpdateRolResponse::failure("No puedes banearte a ti mismo del nodo."),
        );
    }

    // 2. Obtener rol del usuario actual en el nodo
    let current_user_check = sqlx::query_as::<_, (String,)>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await;

    let current_rol = match current_user_check {
        Ok(Some((rol,))) => rol,
        _ => {
            if auth_user.role == "ADMIN" {
                "GLOBAL_ADMIN".to_string()
            } else {
                return (
                    StatusCode::FORBIDDEN,
                    UpdateRolResponse::failure(
                        "No eres miembro de este nodo ni administrador global.",
                    ),
                );
            }
        }
    };

    // 3. Obtener rol del usuario objetivo
    let target_user_check = sqlx::query_as::<_, (String,)>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(nodo_id)
    .bind(target_user_id)
    .fetch_optional(&state.pool)
    .await;

    let target_rol = match target_user_check {
        Ok(Some((rol,))) => rol,
        Ok(None) => {
            // El usuario podría no ser miembro pero queremos banearlo igual para evitar que entre
            "NONE".to_string()
        }
        Err(e) => {
            eprintln!("Error al verificar usuario objetivo para banear: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                UpdateRolResponse::failure("Error interno al verificar el miembro."),
            );
        }
    };

    // 4. Validar permisos de jerarquía
    let is_authorized = if current_rol == "OWNER" || current_rol == "GLOBAL_ADMIN" {
        target_rol != "OWNER" // El owner no puede ser baneado por nadie
    } else if current_rol == "ADMIN" {
        target_rol == "MEMBER" || target_rol == "NONE"
    } else {
        false
    };

    if !is_authorized {
        return (
            StatusCode::FORBIDDEN,
            UpdateRolResponse::failure(
                "No tienes permisos suficientes para banear a este usuario.",
            ),
        );
    }

    // Iniciar transacción para banear y eliminar membresía de manera atómica
    let mut tx = match state.pool.begin().await {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Error al iniciar transacción para baneo: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                UpdateRolResponse::failure("Error interno al iniciar baneo."),
            );
        }
    };

    // Insertar en la tabla de baneos
    let ban_result = sqlx::query(
        "INSERT INTO nodo_baneos (nodo_id, user_id, creado_por) VALUES ($1, $2, $3) ON CONFLICT (nodo_id, user_id) DO NOTHING"
    )
    .bind(nodo_id)
    .bind(target_user_id)
    .bind(auth_user.user_id)
    .execute(&mut *tx)
    .await;

    if let Err(e) = ban_result {
        eprintln!("Error al registrar baneo en DB: {}", e);
        let _ = tx.rollback().await;
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            UpdateRolResponse::failure("Error al registrar baneo en la base de datos."),
        );
    }

    // Eliminar de nodo_miembros
    let kick_result = remove_membership(&mut tx, nodo_id, target_user_id).await;

    if let Err(e) = kick_result {
        eprintln!("Error al remover membresía durante baneo: {}", e);
        let _ = tx.rollback().await;
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            UpdateRolResponse::failure("Error al remover membresía del usuario baneado."),
        );
    }

    if let Err(e) = tx.commit().await {
        eprintln!("Error al confirmar transacción de baneo: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            UpdateRolResponse::failure("Error al completar la operación de baneo."),
        );
    }

    (
        StatusCode::OK,
        Json(UpdateRolResponse {
            success: true,
            message: "Usuario baneado del nodo exitosamente.".to_string(),
        }),
    )
}

// ─── DELETE /nodos/{id}/baneos/{user_id} ─────────────────────────────────

pub async fn unban_miembro(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::extract::Path((nodo_id, target_user_id)): axum::extract::Path<(Uuid, Uuid)>,
) -> (StatusCode, Json<UpdateRolResponse>) {
    // 1. Obtener rol en el nodo
    let current_user_check = sqlx::query_as::<_, (String,)>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(nodo_id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await;

    let current_rol = match current_user_check {
        Ok(Some((rol,))) => rol,
        _ => {
            if auth_user.role == "ADMIN" {
                "GLOBAL_ADMIN".to_string()
            } else {
                return (
                    StatusCode::FORBIDDEN,
                    UpdateRolResponse::failure(
                        "No eres miembro de este nodo ni administrador global.",
                    ),
                );
            }
        }
    };

    // 2. Solo OWNER, ADMIN de nodo o ADMIN global pueden desbanear
    if current_rol != "OWNER" && current_rol != "ADMIN" && current_rol != "GLOBAL_ADMIN" {
        return (
            StatusCode::FORBIDDEN,
            UpdateRolResponse::failure("No tienes permisos suficientes para desbanear usuarios."),
        );
    }

    // 3. Eliminar de la tabla de baneos
    let delete_result = sqlx::query("DELETE FROM nodo_baneos WHERE nodo_id = $1 AND user_id = $2")
        .bind(nodo_id)
        .bind(target_user_id)
        .execute(&state.pool)
        .await;

    match delete_result {
        Ok(r) => {
            if r.rows_affected() == 0 {
                (
                    StatusCode::NOT_FOUND,
                    UpdateRolResponse::failure("Este usuario no está baneado en este nodo."),
                )
            } else {
                (
                    StatusCode::OK,
                    Json(UpdateRolResponse {
                        success: true,
                        message: "Baneo revocado exitosamente.".to_string(),
                    }),
                )
            }
        }
        Err(e) => {
            eprintln!("Error al remover baneo: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                UpdateRolResponse::failure("Error interno al remover el baneo."),
            )
        }
    }
}

#[derive(Serialize)]
pub struct NodoBaneoInfo {
    pub user_id: Uuid,
    pub name: String,
    pub email: String,
    pub creado_por_nombre: Option<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Serialize)]
pub struct BaneosResponse {
    pub success: bool,
    pub message: String,
    pub baneos: Vec<NodoBaneoInfo>,
}

// ─── GET /nodos/{id}/baneos ──────────────────────────────────────────────

pub async fn list_baneos(
    State(state): State<AppState>,
    axum::Extension(auth_user): axum::Extension<AuthUser>,
    axum::extract::Path(id): axum::extract::Path<Uuid>,
) -> (StatusCode, Json<BaneosResponse>) {
    // 1. Verificar si el usuario actual es miembro del nodo o admin global
    let member_check = sqlx::query_as::<_, (String,)>(
        "SELECT rol FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(auth_user.user_id)
    .fetch_optional(&state.pool)
    .await;

    let is_member = match member_check {
        Ok(Some((rol,))) => rol == "OWNER" || rol == "ADMIN",
        _ => auth_user.role == "ADMIN",
    };

    if !is_member {
        return (
            StatusCode::FORBIDDEN,
            Json(BaneosResponse {
                success: false,
                message: "No tienes permiso para ver los baneados de este nodo.".to_string(),
                baneos: vec![],
            }),
        );
    }

    // 2. Obtener lista de baneos
    let rows = sqlx::query_as::<
        _,
        (
            Uuid,
            String,
            String,
            Option<String>,
            chrono::DateTime<chrono::Utc>,
        ),
    >(
        r#"
        SELECT u.id, u.name, u.email, uc.name as creado_por_nombre, nb.created_at
        FROM nodo_baneos nb
        INNER JOIN users u ON nb.user_id = u.id
        LEFT JOIN users uc ON nb.creado_por = uc.id
        WHERE nb.nodo_id = $1
        ORDER BY nb.created_at DESC
        "#,
    )
    .bind(id)
    .fetch_all(&state.pool)
    .await;

    match rows {
        Ok(baneos) => {
            let list = baneos
                .into_iter()
                .map(
                    |(user_id, name, email, creado_por_nombre, created_at)| NodoBaneoInfo {
                        user_id,
                        name,
                        email,
                        creado_por_nombre,
                        created_at,
                    },
                )
                .collect();

            (
                StatusCode::OK,
                Json(BaneosResponse {
                    success: true,
                    message: "Baneos cargados exitosamente.".to_string(),
                    baneos: list,
                }),
            )
        }
        Err(e) => {
            eprintln!("Error al obtener baneos del nodo: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(BaneosResponse {
                    success: false,
                    message: "Error interno al obtener la lista de baneos.".to_string(),
                    baneos: vec![],
                }),
            )
        }
    }
}

crate::response::failure_response!(UpdateRolResponse, NodoResponse);
