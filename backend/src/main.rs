use axum::{
    Router, middleware,
    routing::{delete, get, post, put},
};
use std::net::SocketAddr;
use tower_http::cors::{Any, CorsLayer};

mod amigos;
mod amigos_chat;
mod attendance;
#[cfg(test)]
mod audit_tests;
mod auth;
mod breakout;
mod calendar;
mod chat;
mod config;
mod db;
mod live;
mod mailer;
mod nodos;
mod notifications;
mod response;
mod rtc;
mod whiteboard;

#[cfg(test)]
mod chat_contract_tests;

use auth::verification::AppState;

#[tokio::main]
async fn main() {
    // 1. Cargar variables de entorno
    dotenvy::dotenv().ok();

    println!("Inicializando IronLink Backend...");

    // 2. Cargar configuración desde variables de entorno
    let app_config = config::AppConfig::from_env();
    let app_config_arc = std::sync::Arc::new(app_config);
    println!("Configuración cargada correctamente.");

    // 3. Conectar a la base de datos (PgPool)
    let pool = db::conn::establish_connexion().await;
    println!("Conectado a la base de datos con éxito.");

    // Ejecutar migraciones SQL
    println!("Ejecutando migraciones SQL de IronLink...");
    let migration_files = [
        "migrations/001_sprint1_complete.sql",
        "migrations/002_sprint2_fixes.sql",
        "migrations/003_sprint3_rtc.sql",
        "migrations/004_direct_messages.sql",
        "migrations/005_rtc_moderation.sql",
        "migrations/006_live_updates.sql",
        "migrations/007_calendar_index.sql",
        "migrations/008_attendance.sql",
        "migrations/009_notifications.sql",
        "migrations/010_breakout_rooms.sql",
        "migrations/011_whiteboard.sql",
        "migrations/012_security_fixes.sql",
        "migrations/013_orphan_subgroup_members.sql",
        "migrations/014_session_cutoff.sql",
        "migrations/015_meeting_scheduling.sql",
        "migrations/016_friendships.sql",
        "migrations/017_calendar_details.sql",
        "migrations/018_social_privacy.sql",
        "migrations/019_session_version.sql",
        "migrations/020_ticket_session.sql",
    ];
    for m_file in migration_files {
        let sql = std::fs::read_to_string(m_file)
            .unwrap_or_else(|e| panic!("No se pudo leer la migración {m_file}: {e}"));
        sqlx::raw_sql(sqlx::AssertSqlSafe(sql))
            .execute(&pool)
            .await
            .unwrap_or_else(|e| panic!("No se pudo aplicar la migración {m_file}: {e}"));
        println!("Migración '{}' ejecutada/verificada con éxito.", m_file);
    }

    // IRL-SEC-US-01: ninguna conexión RTC sobrevive a un reinicio; las sesiones
    // de asistencia abiertas se cierran con su último latido registrado.
    match attendance::recover(&pool).await {
        Ok(0) => {}
        Ok(n) => println!("Asistencia: {n} sesión(es) abiertas cerradas tras el reinicio."),
        Err(e) => eprintln!("Asistencia: no se pudieron cerrar sesiones abiertas: {e}"),
    }

    // Inicializar el mailer SMTP global
    let mailer = mailer::create_mailer(&app_config_arc)
        .expect("Error crítico al inicializar el mailer SMTP global");

    // 4. Crear estado compartido de la aplicación
    let app_state = AppState {
        pool,
        config: app_config_arc.clone(),
        mailer,
    };
    let rtc_hub = std::sync::Arc::new(rtc::server::RoomHub::default());
    let ticket_cleanup_pool = app_state.pool.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(600));
        interval.tick().await;
        loop {
            interval.tick().await;
            if let Err(error) = sqlx::raw_sql("DELETE FROM rtc_tickets WHERE expires_at <= NOW(); DELETE FROM live_tickets WHERE expires_at <= NOW();")
                .execute(&ticket_cleanup_pool).await {
                eprintln!("No se pudieron limpiar pases RTC vencidos: {error}");
            }
        }
    });

    // IRL-NTF-US-01: genera recordatorios de 15 y 5 minutos. Cada 20 s basta
    // para avisar a tiempo; la clave única evita duplicados entre pasadas.
    let reminders_pool = app_state.pool.clone();
    let reminders_hub = rtc_hub.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(20));
        loop {
            interval.tick().await;
            match notifications::generate_reminders(&reminders_pool).await {
                // Empuja el nuevo contador por el canal en vivo sin esperar al latido.
                Ok(created) if created > 0 => reminders_hub.changed(),
                Ok(_) => {}
                Err(error) => {
                    eprintln!("Notificaciones: no se pudieron generar recordatorios: {error}")
                }
            }
        }
    });

    // 5. Configurar CORS. CORS_ALLOWED_ORIGINS (separados por comas) limita los
    // orígenes del cliente web en producción; sin definir se admite cualquiera
    // (desarrollo). La API se autentica con el header Authorization, no con
    // cookies, así que CORS no protege credenciales: solo acota quién la usa
    // desde un navegador.
    let cors = match std::env::var("CORS_ALLOWED_ORIGINS") {
        Ok(list) if !list.trim().is_empty() => {
            let origins: Vec<axum::http::HeaderValue> = list
                .split(',')
                .filter_map(|origin| origin.trim().parse().ok())
                .collect();
            println!("CORS restringido a {} origen(es).", origins.len());
            CorsLayer::new().allow_origin(origins)
        }
        _ => CorsLayer::new().allow_origin(Any),
    }
    .allow_methods(Any)
    .allow_headers(Any);

    // Rutas públicas que envían correo: además del límite por cuenta, un tope
    // por IP (ver auth::mail_guard).
    let mail_routes = Router::new()
        .route(
            "/request-verification",
            post(auth::verification::request_verification),
        )
        .route(
            "/forgot-password",
            post(auth::verification::forgot_password),
        )
        .route_layer(middleware::from_fn(auth::mail_guard::limit_by_ip));

    // 6. Rutas públicas (no requieren autenticación)
    let public_routes = Router::new()
        .route("/health", get(health_check_handler))
        .route("/api/health", get(health_check_handler))
        .route("/register", post(auth::service::register_user))
        .route("/login", post(auth::service::login))
        .route("/refresh", post(auth::session::refresh))
        .route("/logout", post(auth::session::logout))
        .route("/rtc/ws", get(rtc::server::websocket))
        .route("/live/ws", get(live::websocket))
        .route("/verify-email", post(auth::verification::verify_email))
        .route("/verify-link/{token}", get(auth::verification::verify_link))
        .route("/reset-password", post(auth::verification::reset_password))
        .merge(mail_routes);

    // 7. Rutas protegidas (requieren JWT válido)
    let protected_routes = Router::new()
        .route("/calendar/meetings", get(calendar::list))
        .route("/reuniones/{id}", get(calendar::shared))
        .route(
            "/nodos/{id}/reuniones/{reunion_id}/asistencia",
            get(attendance::get_report),
        )
        .route(
            "/nodos/{id}/reuniones/{reunion_id}/asistencia.csv",
            get(attendance::get_csv),
        )
        .route(
            "/nodos/{id}/reuniones/{reunion_id}/salas",
            get(breakout::get)
                .put(breakout::replace)
                .delete(breakout::close),
        )
        .route(
            "/nodos/{id}/reuniones/{reunion_id}/pizarra",
            get(whiteboard::get).delete(whiteboard::clear),
        )
        .route(
            "/nodos/{id}/reuniones/{reunion_id}/pizarra/trazos",
            post(whiteboard::add_stroke),
        )
        .route(
            "/nodos/{id}/reuniones/{reunion_id}/pizarra/trazos/{trazo_id}",
            delete(whiteboard::delete_stroke),
        )
        .route(
            "/nodos/{id}/reuniones/{reunion_id}/pizarra/permisos",
            put(whiteboard::set_permissions),
        )
        // Personas y amistades (solicitudes al estilo de Discord).
        .route("/usuarios/buscar", get(amigos::buscar))
        .route("/amigos", get(amigos::listar))
        .route(
            "/amigos/solicitudes",
            get(amigos::solicitudes).post(amigos::enviar),
        )
        .route("/amigos/solicitudes/{id}", delete(amigos::cancelar))
        .route("/amigos/solicitudes/{id}/aceptar", post(amigos::aceptar))
        .route("/amigos/solicitudes/{id}/rechazar", post(amigos::rechazar))
        .route("/amigos/{user_id}", delete(amigos::eliminar))
        .route(
            "/amigos/privacidad",
            get(amigos::privacidad).put(amigos::guardar_privacidad),
        )
        // Chat entre amigos, independiente de los nodos.
        .route("/amigos/conversaciones", get(amigos_chat::conversaciones))
        .route(
            "/amigos/{user_id}/mensajes",
            get(amigos_chat::historial).post(amigos_chat::enviar),
        )
        .route("/bloqueados", get(amigos::bloqueados))
        .route(
            "/bloqueados/{user_id}",
            put(amigos::bloquear).delete(amigos::desbloquear),
        )
        .route("/live/ticket", post(live::issue_ticket))
        .route("/notificaciones", get(notifications::list))
        .route("/notificaciones/leidas", post(notifications::mark_read))
        .route("/nodos", post(nodos::service::create_nodo))
        .route("/nodos", get(nodos::service::list_nodos))
        .route("/nodos/join/{token}", post(nodos::service::join_nodo))
        .route("/nodos/{id}", delete(nodos::service::delete_nodo))
        .route("/nodos/{id}/leave", post(nodos::service::leave_nodo))
        .route("/nodos/{id}/miembros", get(nodos::service::list_miembros))
        .route(
            "/nodos/{id}/miembros/{user_id}",
            delete(nodos::service::kick_miembro),
        )
        .route(
            "/nodos/{id}/miembros/{user_id}/ban",
            post(nodos::service::ban_miembro),
        )
        .route(
            "/nodos/{id}/miembros/{user_id}/rol",
            put(nodos::service::update_miembro_rol),
        )
        .route("/nodos/{id}/baneos", get(nodos::service::list_baneos))
        .route(
            "/nodos/{id}/baneos/{user_id}",
            delete(nodos::service::unban_miembro),
        )
        .route("/nodos/{id}/mensajes", post(chat::service::send_mensaje))
        .route("/nodos/{id}/mensajes", get(chat::service::list_mensajes))
        .route("/nodos/{id}/direct-messages", get(chat::direct::inbox))
        .route(
            "/nodos/{id}/direct-messages/{peer_id}",
            get(chat::direct::history),
        )
        .route(
            "/nodos/{id}/direct-messages/{peer_id}",
            post(chat::direct::send),
        )
        // ── Sprint 2: IRL-WKS-US-03 (Contador y Limpieza de Mensajes No Leídos) ──
        .route(
            "/nodos/{id}/unread-count",
            get(chat::service::get_unread_count),
        )
        .route(
            "/api/node/{id}/unread-count",
            get(chat::service::get_unread_count),
        )
        .route("/nodos/{id}/read", post(chat::service::mark_as_read))
        .route(
            "/api/node/{id}/check_read_status",
            post(chat::service::mark_as_read),
        )
        // ── Sprint 2: IRL-IAM-US-05 (Perfil de Usuario y Upload de Avatar con validación) ──
        .route("/users/me", get(auth::service::get_user_profile))
        .route("/users/me", put(auth::service::update_user_profile))
        .route("/users/me/avatar", post(auth::service::upload_avatar))
        .route("/api/users/me/avatar", post(auth::service::upload_avatar))
        .route(
            "/users/me/password",
            put(auth::service::change_user_password),
        )
        // ── Sprint 2: IRL-WKS-US-02 (Subgrupos: Creación, Edición en Caliente y Asignación) ──
        .route(
            "/nodos/{id}/subgrupos",
            post(nodos::subgrupos::create_subgrupo),
        )
        .route(
            "/nodos/{id}/subgrupos",
            get(nodos::subgrupos::list_subgrupos),
        )
        .route(
            "/nodos/{id}/subgrupos/{subgrupo_id}",
            put(nodos::subgrupos::update_subgrupo),
        )
        .route(
            "/nodos/{id}/subgrupos/{subgrupo_id}/join",
            post(nodos::subgrupos::join_subgrupo),
        )
        .route(
            "/nodos/{id}/subgrupos/{subgrupo_id}/leave",
            post(nodos::subgrupos::leave_subgrupo),
        )
        .route(
            "/nodos/{id}/subgrupos/{subgrupo_id}",
            delete(nodos::subgrupos::delete_subgrupo),
        )
        .route(
            "/nodos/{id}/subgrupos/{subgrupo_id}/miembros",
            get(nodos::subgrupos::list_subgrupo_miembros),
        )
        .route(
            "/nodos/{id}/subgrupos/{subgrupo_id}/miembros",
            post(nodos::subgrupos::asignar_miembros_subgrupo),
        )
        .route(
            "/nodos/{id}/subgrupos/{subgrupo_id}/asignar-miembros",
            post(nodos::subgrupos::asignar_miembros_subgrupo),
        )
        // ── Sprint 2: IRL-WKS-US-04 (Reuniones Programadas) ──
        .route(
            "/nodos/{id}/reuniones",
            post(nodos::reuniones::create_reunion),
        )
        .route(
            "/nodos/{id}/reuniones",
            get(nodos::reuniones::list_reuniones),
        )
        .route(
            "/nodos/{id}/reuniones/ahora",
            post(nodos::reuniones::meet_now),
        )
        .route(
            "/nodos/{id}/reuniones/{reunion_id}/respuesta",
            put(nodos::reuniones::respond),
        )
        .route(
            "/nodos/{id}/disponibilidad",
            get(nodos::reuniones::availability),
        )
        .route(
            "/nodos/{id}/reuniones/{reunion_id}",
            put(nodos::reuniones::update_reunion),
        )
        .route(
            "/nodos/{id}/reuniones/{reunion_id}",
            delete(nodos::reuniones::delete_reunion),
        )
        .route(
            "/nodos/{id}/reuniones/{reunion_id}/start",
            post(rtc::server::start_meeting),
        )
        .route(
            "/nodos/{id}/reuniones/{reunion_id}/end",
            post(rtc::server::end_meeting),
        )
        .route(
            "/nodos/{id}/reuniones/{reunion_id}/rtc-ticket",
            post(rtc::server::issue_ticket),
        )
        .route(
            "/nodos/{id}/reuniones/{reunion_id}/moderation",
            post(rtc::server::moderate).layer(axum::extract::DefaultBodyLimit::max(1024)),
        )
        .layer(middleware::from_fn(auth::middleware::jwt_auth));

    // 8. Rutas de administrador (requieren JWT + rol ADMIN)
    let admin_routes = Router::new()
        .route(
            "/admin/users/{id}/role",
            put(auth::service::change_user_role),
        )
        .layer(middleware::from_fn(auth::middleware::require_admin))
        .layer(middleware::from_fn(auth::middleware::jwt_auth));

    // 9. Combinar todas las rutas con Middlewares de Calidad ISO/IEC 25010:2023
    let app = Router::new()
        .merge(public_routes)
        .merge(protected_routes)
        .merge(admin_routes)
        .fallback(fallback_handler)
        .layer(middleware::from_fn(security_headers_middleware)) // ISO 3.6 Resistencia
        .layer(middleware::from_fn(request_logger_middleware)) // ISO 3.7 Analizabilidad
        .layer(cors)
        .layer(axum::Extension(rtc_hub))
        .layer(axum::Extension(app_state.pool.clone()))
        .layer(axum::Extension(app_config_arc.clone()))
        .with_state(app_state);

    // 10. Configurar dirección y puerto dinámico (ISO 3.8 Flexibilidad / Adaptabilidad)
    let host_ip: std::net::IpAddr = app_config_arc
        .server_host
        .parse()
        .unwrap_or(std::net::IpAddr::from([0, 0, 0, 0]));
    let addr = SocketAddr::from((host_ip, app_config_arc.server_port));
    println!("Servidor IronLink escuchando en: http://{}", addr);

    // 11. Enlazar el socket TCP y arrancar con apagado controlado (ISO 3.5 Fiabilidad)
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .unwrap_or_else(|e| {
            panic!(
                "Error crítico: No se pudo enlazar el socket TCP en {}: {}",
                addr, e
            )
        });

    // La IP del cliente la necesita el tope de auth::mail_guard.
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await
    .expect("Error al ejecutar el servidor web de Axum");
}

// ─────────────────────────────────────────────────────────────────────────────
// IMPLEMENTACIÓN DE ESTÁNDARES ISO/IEC 25010:2023 (CLÁUSULAS 3.4 A 3.8)
// ─────────────────────────────────────────────────────────────────────────────

/// ISO 3.5 Reliability (Disponibilidad y Tolerancia a Fallos)
/// Endpoint de salud que verifica el estado del proceso y la conexión al PgPool.
async fn health_check_handler(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> (axum::http::StatusCode, axum::Json<serde_json::Value>) {
    let db_status = match sqlx::query("SELECT 1").execute(&state.pool).await {
        Ok(_) => "connected",
        Err(_) => "disconnected",
    };

    let is_healthy = db_status == "connected";
    let status_code = if is_healthy {
        axum::http::StatusCode::OK
    } else {
        axum::http::StatusCode::SERVICE_UNAVAILABLE
    };

    (
        status_code,
        axum::Json(serde_json::json!({
            "status": if is_healthy { "healthy" } else { "degraded" },
            "service": "ironlink-backend",
            "version": "2.0",
            "database": db_status,
            "standards": {
                "framework": "ISO/IEC 25010:2023 (Ed. 2)",
                "clauses": [
                    "3.4 Interaction Capability (Error Protection)",
                    "3.5 Reliability (Fault Tolerance & Availability)",
                    "3.6 Security (Resistance & Confidentiality)",
                    "3.7 Maintainability (Analysability)",
                    "3.8 Flexibility (Scalability & Adaptability)"
                ]
            },
            "timestamp": chrono::Utc::now().to_rfc3339()
        })),
    )
}

/// ISO 3.6 Security (Resistencia ante Ataques Web / Cabeceras de Seguridad)
async fn security_headers_middleware(
    req: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let mut response = next.run(req).await;
    let headers = response.headers_mut();

    headers.insert(
        axum::http::header::HeaderName::from_static("x-content-type-options"),
        axum::http::HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        axum::http::header::HeaderName::from_static("x-frame-options"),
        axum::http::HeaderValue::from_static("DENY"),
    );
    headers.insert(
        axum::http::header::HeaderName::from_static("x-xss-protection"),
        axum::http::HeaderValue::from_static("1; mode=block"),
    );
    headers.insert(
        axum::http::header::HeaderName::from_static("referrer-policy"),
        axum::http::HeaderValue::from_static("strict-origin-when-cross-origin"),
    );
    headers.insert(
        axum::http::header::HeaderName::from_static("x-permitted-cross-domain-policies"),
        axum::http::HeaderValue::from_static("none"),
    );
    response
}

/// ISO 3.7 Maintainability (Analizabilidad / Logging Estructurado de Peticiones)
async fn request_logger_middleware(
    req: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let method = req.method().clone();
    let uri = req.uri().path().to_string();
    let start = std::time::Instant::now();

    let response = next.run(req).await;

    let elapsed = start.elapsed();
    println!(
        "[API ISO-3.7] {} {} -> Status: {} ({:.2?})",
        method,
        uri,
        response.status(),
        elapsed
    );

    response
}

/// ISO 3.4 Interaction Capability (Asistencia al Usuario y Manejo Seguro de Rutas 404)
async fn fallback_handler(
    uri: axum::http::Uri,
) -> (axum::http::StatusCode, axum::Json<serde_json::Value>) {
    (
        axum::http::StatusCode::NOT_FOUND,
        axum::Json(serde_json::json!({
            "success": false,
            "error": "Recurso no encontrado",
            "path": uri.path(),
            "message": "La ruta solicitada no existe en la API de IronLink.",
            "hint": "Consulte /health para comprobar el estado de los servicios."
        })),
    )
}

/// ISO 3.5 Reliability (Recuperabilidad y Apagado Seguro / Graceful Shutdown)
async fn shutdown_signal() {
    tokio::signal::ctrl_c()
        .await
        .expect("Fallo al registrar manejador de señal CTRL+C");
    println!(
        "\n[SHUTDOWN ISO-3.5] Señal de apagado recibida. Cerrando conexiones de IronLink limpiamente..."
    );
}
