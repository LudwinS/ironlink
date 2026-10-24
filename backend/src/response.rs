//! Respuestas de error comunes de la API: `{"success": false, "message": ...}`.
//!
//! Antes cada handler escribía la estructura completa con todos sus campos
//! opcionales en `None` (142 veces). `Tipo::failure(mensaje)` produce el mismo
//! JSON en una línea.

/// Implementa `Tipo::failure(mensaje)` para respuestas con `success`,
/// `message` y campos opcionales (que quedan vacíos y no se serializan).
macro_rules! failure_response {
    ($($type:ty),+ $(,)?) => {
        $(
            impl $type {
                #[allow(clippy::needless_update)]
                pub fn failure(message: impl Into<String>) -> axum::Json<Self> {
                    axum::Json(Self {
                        success: false,
                        message: message.into(),
                        ..Default::default()
                    })
                }
            }
        )+
    };
}
pub(crate) use failure_response;
