use axum::{
    Json,
    extract::Request,
    http::StatusCode,
    middleware::Next,
    response::{IntoResponse, Response},
};
use serde_json::json;

use crate::auth::jwt::{Claims, validate_token};
use crate::config::AppConfig;

/// Datos del usuario autenticado, disponibles como extensión en las rutas protegidas
#[derive(Clone, Debug)]
pub struct AuthUser {
    pub user_id: uuid::Uuid,
    pub role: String,
    /// Versión de sesión del JWT (`ver`), ya comprobada contra la vigente.
    pub session_version: i32,
}

/// Middleware de autenticación JWT.
/// Extrae el token del header Authorization: Bearer <token>,
/// lo valida y agrega AuthUser como extensión del request.
pub async fn jwt_auth(request: Request, next: Next) -> Response {
    // Obtener la configuración del estado de la app
    let config = request.extensions().get::<std::sync::Arc<AppConfig>>();

    let config = match config {
        Some(c) => c,
        None => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({
                    "success": false,
                    "message": "Error interno: configuración no disponible"
                })),
            )
                .into_response();
        }
    };

    // Extraer el header Authorization
    let auth_header = request
        .headers()
        .get("Authorization")
        .and_then(|v| v.to_str().ok());

    let token = match auth_header {
        Some(h) if h.starts_with("Bearer ") => &h[7..],
        _ => {
            println!("JWT Auth - ERROR: Header Authorization faltante o malformado");
            return (
                StatusCode::UNAUTHORIZED,
                Json(json!({
                    "success": false,
                    "message": "Token de autenticación requerido"
                })),
            )
                .into_response();
        }
    };

    // Validar el token
    match validate_token(token, &config.jwt_secret) {
        Ok(token_data) => {
            let claims: Claims = token_data.claims;
            let user_id = match uuid::Uuid::parse_str(&claims.sub) {
                Ok(id) => id,
                Err(_) => {
                    println!(
                        "JWT Auth - ERROR: ID de usuario malformado en claims: {}",
                        claims.sub
                    );
                    return (
                        StatusCode::UNAUTHORIZED,
                        Json(json!({
                            "success": false,
                            "message": "Token inválido: ID de usuario malformado"
                        })),
                    )
                        .into_response();
                }
            };

            // El JWT prueba la identidad, pero el rol y el estado se leen en
            // vivo: un administrador degradado o una cuenta suspendida no deben
            // conservar permisos hasta que venza su token (15 minutos).
            let Some(pool) = request.extensions().get::<sqlx::PgPool>().cloned() else {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "success": false,
                        "message": "Error interno: base de datos no disponible"
                    })),
                )
                    .into_response();
            };
            let current = sqlx::query_as::<_, (String, String, i32)>(
                "SELECT rol::TEXT, estado::TEXT, version_sesion FROM users WHERE id = $1",
            )
            .bind(user_id)
            .fetch_optional(&pool)
            .await;
            let role = match current {
                // Cerrar sesión o cambiar la contraseña incrementa la versión e
                // invalida los accesos emitidos antes, aunque sea en el mismo
                // segundo; quien conserve un refresh token renueva.
                Ok(Some((_, _, version))) if version != claims.ver => {
                    return (
                        StatusCode::UNAUTHORIZED,
                        Json(json!({
                            "success": false,
                            "message": "La sesión se cerró. Vuelve a iniciar sesión.",
                            "code": "invalid_access_token"
                        })),
                    )
                        .into_response();
                }
                Ok(Some((role, estado, _))) if estado == "ACTIVE" => role,
                Ok(_) => {
                    // Mismo código que un token vencido: el cliente intenta
                    // renovar, la renovación también se rechaza y cierra sesión.
                    return (
                        StatusCode::UNAUTHORIZED,
                        Json(json!({
                            "success": false,
                            "message": "La cuenta no está activa.",
                            "code": "invalid_access_token"
                        })),
                    )
                        .into_response();
                }
                Err(_) => {
                    return (
                        StatusCode::SERVICE_UNAVAILABLE,
                        Json(json!({
                            "success": false,
                            "message": "No se pudo validar la sesión. Intenta nuevamente."
                        })),
                    )
                        .into_response();
                }
            };
            let auth_user = AuthUser {
                user_id,
                role,
                session_version: claims.ver,
            };

            // Inyectar el usuario autenticado como extensión
            let mut request = request;
            request.extensions_mut().insert(auth_user);

            next.run(request).await
        }
        Err(e) => {
            println!(
                "JWT Auth - ERROR: Token inválido o expirado. Detalle: {:?}",
                e
            );
            (
                StatusCode::UNAUTHORIZED,
                Json(json!({
                    "success": false,
                    "message": "Token inválido o expirado",
                    "code": "invalid_access_token"
                })),
            )
                .into_response()
        }
    }
}

/// Middleware que verifica que el usuario tenga rol de administrador
pub async fn require_admin(request: Request, next: Next) -> Response {
    let auth_user = request.extensions().get::<AuthUser>().cloned();

    match auth_user {
        Some(user) if user.role == "ADMIN" => next.run(request).await,
        Some(_) => (
            StatusCode::FORBIDDEN,
            Json(json!({
                "success": false,
                "message": "Acceso denegado: se requiere rol de administrador"
            })),
        )
            .into_response(),
        None => (
            StatusCode::UNAUTHORIZED,
            Json(json!({
                "success": false,
                "message": "No autenticado"
            })),
        )
            .into_response(),
    }
}
