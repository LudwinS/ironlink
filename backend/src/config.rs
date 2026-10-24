use std::env;

/// Configuración global de la aplicación cargada desde variables de entorno
#[derive(Clone)]
pub struct AppConfig {
    pub jwt_secret: String,
    pub smtp_username: String,
    pub smtp_password: String,
    pub smtp_from: String,
    pub app_base_url: String,
    pub app_public_url: Option<String>,
    pub server_host: String,
    pub server_port: u16,
}

impl std::fmt::Debug for AppConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AppConfig")
            .field("server_host", &self.server_host)
            .field("server_port", &self.server_port)
            .field("smtp_username", &self.smtp_username)
            .field("smtp_from", &self.smtp_from)
            .field("app_base_url", &self.app_base_url)
            .field("app_public_url", &self.app_public_url)
            .field("jwt_secret", &"[REDACTED]")
            .field("smtp_password", &"[REDACTED]")
            .finish()
    }
}

impl AppConfig {
    /// Carga la configuración desde las variables de entorno.
    /// Aborta el proceso si alguna variable requerida no está definida.
    pub fn from_env() -> Self {
        let server_host = env::var("SERVER_HOST").unwrap_or_else(|_| "0.0.0.0".to_string());

        let server_port = env::var("PORT")
            .or_else(|_| env::var("SERVER_PORT"))
            .ok()
            .and_then(|p| p.parse().ok())
            .unwrap_or(8080);

        Self {
            jwt_secret: env::var("JWT_SECRET")
                .expect("La variable de entorno JWT_SECRET no está definida"),
            smtp_username: env::var("SMTP_USERNAME")
                .expect("La variable de entorno SMTP_USERNAME no está definida"),
            smtp_password: env::var("SMTP_PASSWORD")
                .expect("La variable de entorno SMTP_PASSWORD no está definida"),
            smtp_from: env::var("SMTP_FROM")
                .expect("La variable de entorno SMTP_FROM no está definida"),
            app_public_url: env::var("APP_PUBLIC_URL").ok(),
            app_base_url: env::var("APP_BASE_URL")
                .unwrap_or_else(|_| "http://localhost:8080".to_string()),
            server_host,
            server_port,
        }
    }
}
