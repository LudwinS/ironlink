use chrono::{Duration, Utc};
use jsonwebtoken::{DecodingKey, EncodingKey, Header, TokenData, Validation, decode, encode};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Claims que se incluyen en el JWT access token
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Claims {
    pub sub: String,  // user_id como string
    pub role: String, // rol del usuario (e.g. "USER", "ADMIN")
    pub exp: usize,   // timestamp de expiración (UNIX epoch)
    pub iat: usize,   // timestamp de emisión
    /// Versión de sesión del usuario al emitirlo (`users.version_sesion`).
    /// Un JWT anterior sin este campo no se puede decodificar: 401.
    pub ver: i32,
}

/// Genera un JWT access token con duración de 15 minutos
pub fn generate_access_token(
    user_id: Uuid,
    role: &str,
    session_version: i32,
    secret: &str,
) -> Result<String, jsonwebtoken::errors::Error> {
    let now = Utc::now();
    let expires_at = now + Duration::minutes(15);

    let claims = Claims {
        sub: user_id.to_string(),
        role: role.to_string(),
        exp: expires_at.timestamp() as usize,
        iat: now.timestamp() as usize,
        ver: session_version,
    };

    encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
}

/// Valida un JWT access token y retorna los claims
pub fn validate_token(
    token: &str,
    secret: &str,
) -> Result<TokenData<Claims>, jsonwebtoken::errors::Error> {
    decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &Validation::default(),
    )
}
