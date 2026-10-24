use serde::{Deserialize, Serialize};
use uuid::Uuid;

// ─── DTOs y Estructuras para Chat ────────────────────────────────────────

#[derive(Deserialize)]
pub struct SendMensajeDto {
    pub contenido: String,
    pub subgrupo_id: Option<Uuid>,
}

#[derive(Deserialize)]
pub struct ListMensajesQuery {
    pub subgrupo_id: Option<Uuid>,
    /// Último mensaje que el cliente ya tiene: el sondeo solo pide lo nuevo.
    pub despues_de: Option<Uuid>,
}

#[derive(Serialize, Clone)]
pub struct MensajeInfo {
    pub id: Uuid,
    pub nodo_id: Uuid,
    pub user_id: Uuid,
    pub user_name: String,
    pub contenido: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub subgrupo_id: Option<Uuid>,
    pub avatar_url: Option<String>,
    pub avatar_color: Option<String>,
    pub status_text: Option<String>,
}

#[derive(Serialize, Default)]
pub struct MensajeResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mensaje: Option<MensajeInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mensajes: Option<Vec<MensajeInfo>>,
    /// `true` cuando `mensajes` contiene solo lo posterior a `despues_de`
    /// (más un pequeño solape); el cliente los añade en lugar de reemplazar.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub incremental: Option<bool>,
}

// ─── DTOs de Contador de Mensajes No Leídos (IRL-WKS-US-03) ────────────────

#[derive(Serialize)]
pub struct UnreadCountResponse {
    pub success: bool,
    pub message: String,
    pub unread_count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_read_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Serialize, Default)]
pub struct MarkReadResponse {
    pub success: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_read_at: Option<chrono::DateTime<chrono::Utc>>,
}

crate::response::failure_response!(MensajeResponse, MarkReadResponse);
