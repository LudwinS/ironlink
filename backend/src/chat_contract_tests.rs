//! Contratos de chat sin base de datos ni servicios externos.
use axum::{
    Extension, Json,
    extract::{Path, State},
    http::StatusCode,
};
use serde_json::json;
use sqlx::postgres::PgPoolOptions;
use std::sync::Arc;
use uuid::Uuid;

use crate::chat::{
    models::{MensajeResponse, SendMensajeDto},
    service,
};
use crate::{
    auth::{middleware::AuthUser, verification::AppState},
    config::AppConfig,
};

async fn closed_state() -> AppState {
    let pool = PgPoolOptions::new()
        .connect_lazy("postgres://test:test@127.0.0.1:1/test")
        .unwrap();
    pool.close().await;
    AppState {
        pool,
        config: Arc::new(AppConfig {
            jwt_secret: "test-only".into(),
            smtp_username: String::new(),
            smtp_password: String::new(),
            smtp_from: "test@example.invalid".into(),
            app_base_url: "http://localhost".into(),
            app_public_url: None,
            server_host: "127.0.0.1".into(),
            server_port: 0,
        }),
        mailer: lettre::AsyncSmtpTransport::<lettre::Tokio1Executor>::builder_dangerous(
            "localhost",
        )
        .build(),
    }
}

fn member() -> AuthUser {
    AuthUser {
        user_id: Uuid::nil(),
        role: "MEMBER".into(),
        session_version: 0,
    }
}

#[test]
fn general_channel_payload_does_not_require_subgroup() {
    let dto: SendMensajeDto = serde_json::from_value(json!({"contenido":"Hola"})).unwrap();
    assert_eq!(dto.contenido, "Hola");
    assert_eq!(dto.subgrupo_id, None);
    assert!(
        serde_json::from_value::<SendMensajeDto>(
            json!({"contenido":"Hola","subgrupo_id":"invalid"})
        )
        .is_err()
    );
}

#[test]
fn message_response_preserves_optional_json_fields() {
    let response = MensajeResponse {
        success: true,
        message: "ok".into(),
        mensaje: None,
        mensajes: Some(vec![]),
        incremental: None,
    };
    assert_eq!(
        serde_json::to_value(response).unwrap(),
        json!({"success":true,"message":"ok","mensajes":[]})
    );
}

#[tokio::test]
async fn blank_message_is_rejected_before_database_access() {
    let (status, Json(body)) = service::send_mensaje(
        State(closed_state().await),
        Extension(member()),
        Path(Uuid::nil()),
        Json(SendMensajeDto {
            contenido: " \n\t ".into(),
            subgrupo_id: None,
        }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        serde_json::to_value(body).unwrap(),
        json!({"success":false,"message":"El contenido del mensaje no puede estar vacío."})
    );
}

#[tokio::test]
async fn unread_database_failure_is_not_reported_as_success() {
    let (status, Json(body)) = service::get_unread_count(
        State(closed_state().await),
        Extension(member()),
        Path(Uuid::nil()),
    )
    .await;
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert!(!body.success);
    assert_eq!(body.unread_count, 0);
    assert_eq!(body.last_read_at, None);
}

#[tokio::test]
async fn mark_read_database_failure_is_not_reported_as_success() {
    let (status, Json(body)) = service::mark_as_read(
        State(closed_state().await),
        Extension(member()),
        Path(Uuid::nil()),
    )
    .await;
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert!(!body.success);
    assert_eq!(body.last_read_at, None);
}
