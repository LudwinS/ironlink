//! Pruebas de regresión de la auditoría de código (1 de octubre de 2026).
//! Cada bloque reproduce un fallo encontrado y comprueba su corrección.
use crate::auth::middleware::AuthUser;
use crate::auth::verification::AppState;
use argon2::{
    Argon2,
    password_hash::{PasswordHasher, SaltString, rand_core::OsRng},
};
use axum::{
    Extension, Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde_json::{Value, json};
use sqlx::{PgPool, postgres::PgPoolOptions};
use std::sync::Arc;
use uuid::Uuid;

fn body<T: serde::Serialize>(response: (StatusCode, Json<T>)) -> (StatusCode, Value) {
    (response.0, serde_json::to_value(&response.1.0).unwrap())
}

/// Para los handlers que devuelven `Response` (p. ej. con `Retry-After`).
async fn response_body(response: axum::response::Response) -> (StatusCode, Value) {
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}

fn dto<T: serde::de::DeserializeOwned>(value: Value) -> T {
    serde_json::from_value(value).unwrap()
}

async fn setup() -> (PgPool, AppState) {
    let url = std::env::var("IRONLINK_TEST_DATABASE_URL").expect("disposable database required");
    let pool = PgPoolOptions::new()
        .max_connections(8)
        .connect(&url)
        .await
        .unwrap();
    for file in [
        include_str!("../migrations/001_sprint1_complete.sql"),
        include_str!("../migrations/002_sprint2_fixes.sql"),
        include_str!("../migrations/003_sprint3_rtc.sql"),
        include_str!("../migrations/004_direct_messages.sql"),
        include_str!("../migrations/005_rtc_moderation.sql"),
        include_str!("../migrations/009_notifications.sql"),
        include_str!("../migrations/012_security_fixes.sql"),
        include_str!("../migrations/014_session_cutoff.sql"),
        include_str!("../migrations/015_meeting_scheduling.sql"),
        include_str!("../migrations/016_friendships.sql"),
        include_str!("../migrations/017_calendar_details.sql"),
        include_str!("../migrations/018_social_privacy.sql"),
        include_str!("../migrations/019_session_version.sql"),
        include_str!("../migrations/020_ticket_session.sql"),
    ] {
        sqlx::raw_sql(sqlx::AssertSqlSafe(file))
            .execute(&pool)
            .await
            .unwrap();
    }
    let state = AppState {
        pool: pool.clone(),
        config: Arc::new(crate::config::AppConfig {
            jwt_secret: "test-only".into(),
            smtp_username: String::new(),
            smtp_password: String::new(),
            smtp_from: "test@example.invalid".into(),
            app_base_url: "http://localhost".into(),
            app_public_url: None,
            server_host: "127.0.0.1".into(),
            server_port: 0,
        }),
        // Sin servidor SMTP: los envíos fallan en silencio, como en producción.
        mailer: lettre::AsyncSmtpTransport::<lettre::Tokio1Executor>::builder_dangerous(
            "127.0.0.1",
        )
        .port(9)
        .build(),
    };
    (pool, state)
}

type Shared<T> = Arc<std::sync::Mutex<Vec<T>>>;

/// Servidor SMTP mínimo que acepta todo y anota el destinatario de cada
/// correo. Devuelve un estado que envía por él.
async fn with_working_smtp(state: &AppState) -> (AppState, Shared<String>) {
    let (state, inbox, _) = with_recording_smtp(state).await;
    (state, inbox)
}

/// Como [`with_working_smtp`], y además guarda el mensaje completo (cabeceras
/// y cuerpo MIME) de cada correo.
async fn with_recording_smtp(state: &AppState) -> (AppState, Shared<String>, Shared<String>) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let inbox = Arc::new(std::sync::Mutex::new(Vec::new()));
    let messages = Arc::new(std::sync::Mutex::new(Vec::new()));
    let (sink, log) = (inbox.clone(), messages.clone());
    tokio::spawn(async move {
        while let Ok((socket, _)) = listener.accept().await {
            let (sink, log) = (sink.clone(), log.clone());
            tokio::spawn(async move {
                let (read, mut write) = socket.into_split();
                let mut lines = BufReader::new(read).lines();
                let _ = write.write_all(b"220 test\r\n").await;
                let (mut recipient, mut in_data) = (String::new(), false);
                let mut data = String::new();
                while let Ok(Some(line)) = lines.next_line().await {
                    let reply: &[u8] = if in_data {
                        if line != "." {
                            data.push_str(line.strip_prefix('.').unwrap_or(&line));
                            data.push('\n');
                            continue;
                        }
                        in_data = false;
                        sink.lock().unwrap().push(std::mem::take(&mut recipient));
                        log.lock().unwrap().push(std::mem::take(&mut data));
                        b"250 ok\r\n"
                    } else if let Some(to) = line.strip_prefix("RCPT TO:") {
                        recipient = to.trim_matches(['<', '>', ' ']).to_string();
                        b"250 ok\r\n"
                    } else if line.starts_with("DATA") {
                        in_data = true;
                        b"354 go\r\n"
                    } else if line.starts_with("QUIT") {
                        let _ = write.write_all(b"221 bye\r\n").await;
                        break;
                    } else {
                        b"250 ok\r\n"
                    };
                    let _ = write.write_all(reply).await;
                }
            });
        }
    });
    let mailer =
        lettre::AsyncSmtpTransport::<lettre::Tokio1Executor>::builder_dangerous("127.0.0.1")
            .port(port)
            .build();
    (
        AppState {
            mailer,
            ..state.clone()
        },
        inbox,
        messages,
    )
}

async fn user(pool: &PgPool, email: &str, estado: &str, password: &str) -> Uuid {
    let hash = Argon2::default()
        .hash_password(password.as_bytes(), &SaltString::generate(&mut OsRng))
        .unwrap()
        .to_string();
    let id = Uuid::new_v4();
    sqlx::query("INSERT INTO users (id, name, email, password, telefono, estado) VALUES ($1, 'Auditoría', $2, $3, $4, $5::estados)")
        .bind(id)
        .bind(email)
        .bind(hash)
        .bind(format!("+503{}", &id.simple().to_string()[..8].chars().map(|c| ((c as u8) % 10 + b'0') as char).collect::<String>()))
        .bind(estado)
        .execute(pool)
        .await
        .unwrap();
    id
}

#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn authentication_audit_fixes() {
    use crate::auth::{service, verification};
    let (pool, state) = setup().await;
    let tag = Uuid::new_v4().simple().to_string();
    let email = format!("ana.{tag}@example.invalid");

    // 1. Un código de recuperación no admite fuerza bruta: al 5.º fallo deja de valer.
    let victim = user(&pool, &email, "ACTIVE", "Secreta1!").await;
    sqlx::query("INSERT INTO verification_tokens (user_id, code, method, expires_at) VALUES ($1, '123456', 'reset_code', NOW() + INTERVAL '15 minutes')")
        .bind(victim)
        .execute(&pool)
        .await
        .unwrap();
    for attempt in 1..=5 {
        let (status, json) = body(
            verification::reset_password(
                State(state.clone()),
                Json(dto(
                    json!({"email": email, "code": "000000", "new_password": "Nueva123!"}),
                )),
            )
            .await,
        );
        assert_eq!(status, StatusCode::BAD_REQUEST);
        // El contador avanza de uno en uno (si su consulta fallara, el
        // código nunca se invalidaría).
        let expected = if attempt < 5 {
            format!("Código incorrecto. Te quedan {} intento(s).", 5 - attempt)
        } else {
            "Demasiados intentos. Solicita un código nuevo.".to_string()
        };
        assert_eq!(json["message"], expected);
    }
    // Ni siquiera el código correcto sirve ya.
    let (status, _) = body(
        verification::reset_password(
            State(state.clone()),
            Json(dto(
                json!({"email": email, "code": "123456", "new_password": "Nueva123!"}),
            )),
        )
        .await,
    );
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // 2. Recuperar la contraseña no reactiva una cuenta suspendida.
    let suspended_email = format!("susp.{tag}@example.invalid");
    let suspended = user(&pool, &suspended_email, "SUSPENDED", "Secreta1!").await;
    sqlx::query("INSERT INTO verification_tokens (user_id, code, method, expires_at) VALUES ($1, '654321', 'reset_code', NOW() + INTERVAL '15 minutes')")
        .bind(suspended)
        .execute(&pool)
        .await
        .unwrap();
    let (status, _) = body(
        verification::reset_password(
            State(state.clone()),
            Json(dto(json!({"email": suspended_email.to_uppercase(), "code": "654321", "new_password": "Nueva123!"}))),
        )
        .await,
    );
    assert_eq!(status, StatusCode::OK);
    let estado: String = sqlx::query_scalar("SELECT estado::TEXT FROM users WHERE id = $1")
        .bind(suspended)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(estado, "SUSPENDED");

    // 3. El login de una cuenta suspendida lo dice, pero solo con la contraseña correcta.
    let login = |email: String, password: &'static str| {
        let state = state.clone();
        async move {
            body(
                service::login(
                    State(state),
                    Json(dto(json!({"email": email, "password": password}))),
                )
                .await,
            )
        }
    };
    assert_eq!(
        login(suspended_email.clone(), "mala").await.1["message"],
        "Credenciales inválidas."
    );
    assert_eq!(
        login(suspended_email.clone(), "Nueva123!").await.1["message"],
        "Tu cuenta está suspendida. Contacta a un administrador."
    );

    // 4. Intentos simultáneos no se saltan el bloqueo tras 5 fallos.
    let target = format!("lock.{tag}@example.invalid");
    let locked = user(&pool, &target, "ACTIVE", "Secreta1!").await;
    let attempts: Vec<_> = (0..12).map(|_| login(target.clone(), "mala")).collect();
    futures_util::future::join_all(attempts).await;
    let (fails, until): (i32, Option<chrono::DateTime<chrono::Utc>>) =
        sqlx::query_as("SELECT intentos_fallidos, bloqueado_hasta FROM users WHERE id = $1")
            .bind(locked)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(fails >= 5, "{fails}");
    assert!(until.is_some());
    assert_eq!(
        login(target.clone(), "Secreta1!").await.0,
        StatusCode::FORBIDDEN,
        "bloqueada"
    );

    // 5. Recuperación: mismo mensaje exista o no el correo, y como máximo 3 por hora.
    let (working, _) = with_working_smtp(&state).await;
    let forgot = |email: String| {
        let state = working.clone();
        async move {
            response_body(
                verification::forgot_password(State(state), Json(dto(json!({"email": email}))))
                    .await,
            )
            .await
        }
    };
    let unknown = forgot(format!("nadie.{tag}@example.invalid")).await.1["message"].clone();
    for _ in 0..4 {
        assert_eq!(forgot(email.clone()).await.1["message"], unknown);
    }
    let sent: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM verification_tokens WHERE user_id = $1 AND method = 'reset_code' AND created_at > NOW() - INTERVAL '1 hour'")
        .bind(victim)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(sent, 3, "solo 3 códigos por hora");

    // 6. Registrar el mismo correo con otras mayúsculas es un duplicado.
    let register = |email: String| {
        let state = state.clone();
        async move {
            body(service::register_user(State(state), Json(dto(json!({
                "name": "Ana Rivas", "email": email, "phone": format!("+5037{}", &Uuid::new_v4().as_u128().to_string()[..7]),
                "password": "Secreta1!"
            })))).await)
        }
    };
    let (status, json) = register(email.to_uppercase()).await;
    assert_eq!(status, StatusCode::CONFLICT, "{json}");

    // 7. Un administrador puede asignar los roles reales, incluido MEMBER.
    let admin = AuthUser {
        user_id: Uuid::new_v4(),
        role: "ADMIN".into(),
        session_version: 0,
    };
    for role in ["MODERATOR", "MEMBER"] {
        let (status, json) = body(
            service::change_user_role(
                State(state.clone()),
                Path(victim),
                Extension(admin.clone()),
                Json(dto(json!({"role": role}))),
            )
            .await,
        );
        assert_eq!(status, StatusCode::OK, "{role}: {json}");
    }
    assert_eq!(
        service::change_user_role(
            State(state.clone()),
            Path(victim),
            Extension(admin),
            Json(dto(json!({"role": "USER"})))
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );

    sqlx::query("DELETE FROM users WHERE email LIKE $1")
        .bind(format!("%{tag}%"))
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn nodes_audit_fixes() {
    use crate::{chat, nodos};
    let (pool, state) = setup().await;
    let tag = Uuid::new_v4().simple().to_string();
    let owner = user(&pool, &format!("o.{tag}@example.invalid"), "ACTIVE", "x").await;
    let author = user(&pool, &format!("a.{tag}@example.invalid"), "ACTIVE", "x").await;
    let outsider = user(&pool, &format!("x.{tag}@example.invalid"), "ACTIVE", "x").await;
    let auth = |user_id| AuthUser {
        user_id,
        role: "MEMBER".into(),
        session_version: 0,
    };
    let (node, other_node) = (Uuid::new_v4(), Uuid::new_v4());
    for (id, creator) in [(node, owner), (other_node, outsider)] {
        sqlx::query("INSERT INTO nodos (id, nombre, token_acceso, creador_id) VALUES ($1, 'Auditoría', $2, $3)")
            .bind(id).bind(id.to_string()[..32].to_string()).bind(creator).execute(&pool).await.unwrap();
    }
    for (n, u, rol) in [
        (node, owner, "OWNER"),
        (node, author, "MEMBER"),
        (other_node, outsider, "OWNER"),
    ] {
        sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id, rol) VALUES ($1, $2, $3)")
            .bind(n)
            .bind(u)
            .bind(rol)
            .execute(&pool)
            .await
            .unwrap();
    }

    // 8. Quien fue expulsado ya no edita ni borra las reuniones que creó.
    let meeting = Uuid::new_v4();
    sqlx::query("INSERT INTO reuniones (id, nodo_id, titulo, enlace, fecha_inicio, creado_por) VALUES ($1, $2, 'Daily', '', NOW(), $3)")
        .bind(meeting).bind(node).bind(author).execute(&pool).await.unwrap();
    let edit = |user: Uuid, payload: Value| {
        let state = state.clone();
        async move {
            nodos::reuniones::update_reunion(
                State(state),
                Extension(auth(user)),
                Path((node, meeting)),
                Json(dto(payload)),
            )
            .await
            .0
        }
    };
    assert_eq!(
        edit(author, json!({"titulo": "  "})).await,
        StatusCode::BAD_REQUEST,
        "título vacío"
    );
    assert_eq!(
        edit(author, json!({"titulo": "Daily 2"})).await,
        StatusCode::OK
    );
    sqlx::query("DELETE FROM nodo_miembros WHERE nodo_id = $1 AND user_id = $2")
        .bind(node)
        .bind(author)
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        edit(author, json!({"titulo": "Secuestrada"})).await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        nodos::reuniones::delete_reunion(
            State(state.clone()),
            Extension(auth(author)),
            Path((node, meeting)),
            Query(Default::default())
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );

    // 9. Los miembros de un subgrupo ajeno o privado no se pueden listar.
    let (private_sub, foreign_sub) = (Uuid::new_v4(), Uuid::new_v4());
    for (id, n, privado, creator) in [
        (private_sub, node, true, owner),
        (foreign_sub, other_node, false, outsider),
    ] {
        sqlx::query("INSERT INTO subgrupos (id, nodo_id, nombre, es_privado, creado_por) VALUES ($1, $2, 'Sub', $3, $4)")
            .bind(id).bind(n).bind(privado).bind(creator).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO subgrupo_miembros (subgrupo_id, user_id) VALUES ($1, $2)")
            .bind(id)
            .bind(creator)
            .execute(&pool)
            .await
            .unwrap();
    }
    sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id, rol) VALUES ($1, $2, 'MEMBER')")
        .bind(node)
        .bind(author)
        .execute(&pool)
        .await
        .unwrap();
    let members = |user: Uuid, n: Uuid, sub: Uuid| {
        let state = state.clone();
        async move {
            let (_, json) = body(
                nodos::subgrupos::list_subgrupo_miembros(
                    State(state),
                    Extension(auth(user)),
                    Path((n, sub)),
                )
                .await,
            );
            json["miembros"].as_array().map(Vec::len).unwrap_or(0)
        }
    };
    assert_eq!(
        members(author, node, foreign_sub).await,
        0,
        "subgrupo de otro nodo"
    );
    assert_eq!(
        members(author, node, private_sub).await,
        0,
        "privado sin pertenecer"
    );
    assert_eq!(members(owner, node, private_sub).await, 1);

    // 11. Asignar a un subgrupo solo incluye integrantes del nodo, todo o nada.
    let (_, json) = body(
        nodos::subgrupos::asignar_miembros_subgrupo(
            State(state.clone()),
            Extension(auth(owner)),
            Path((node, private_sub)),
            Json(dto(json!({"user_ids": [author, outsider]}))),
        )
        .await,
    );
    assert_eq!(json["asignados_count"], 1, "el ajeno al nodo no se asigna");
    assert_eq!(members(author, node, private_sub).await, 2);

    // 12. Expulsar quita también los subgrupos: al volver no recupera el privado.
    let kicked = nodos::service::kick_miembro(
        State(state.clone()),
        Extension(auth(owner)),
        Path((node, author)),
    )
    .await;
    assert_eq!(kicked.0, StatusCode::OK);
    let still: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM subgrupo_miembros WHERE subgrupo_id = $1 AND user_id = $2)",
    )
    .bind(private_sub)
    .bind(author)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert!(!still);
    sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id, rol) VALUES ($1, $2, 'MEMBER')")
        .bind(node)
        .bind(author)
        .execute(&pool)
        .await
        .unwrap();

    // 10. El chat devuelve los 100 mensajes más recientes, en orden.
    sqlx::query("INSERT INTO mensajes (nodo_id, user_id, contenido, created_at)
                 SELECT $1, $2, 'm' || g, NOW() - make_interval(secs => 200 - g) FROM generate_series(1, 150) g")
        .bind(node).bind(owner).execute(&pool).await.unwrap();
    let (_, json) = body(
        chat::service::list_mensajes(
            State(state.clone()),
            Extension(auth(owner)),
            Path(node),
            Query(dto(json!({}))),
        )
        .await,
    );
    let messages = json["mensajes"].as_array().unwrap();
    assert_eq!(messages.len(), 100);
    assert_eq!(messages.first().unwrap()["contenido"], "m51");
    assert_eq!(messages.last().unwrap()["contenido"], "m150");

    sqlx::query("DELETE FROM nodos WHERE id = ANY($1)")
        .bind(vec![node, other_node])
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE id = ANY($1)")
        .bind(vec![owner, author, outsider])
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

/// `Tipo::failure` debe producir exactamente el JSON que se escribía a mano.
#[test]
fn failure_responses_keep_the_same_json() {
    use crate::auth::service::{ApiResponse, LoginResponse};
    let manual = serde_json::to_value(ApiResponse {
        success: false,
        message: "Error".into(),
        field_errors: None,
    })
    .unwrap();
    assert_eq!(
        serde_json::to_value(ApiResponse::failure("Error").0).unwrap(),
        manual
    );
    let login = serde_json::to_value(LoginResponse::failure(format!("{} intentos", 3)).0).unwrap();
    assert_eq!(login["success"], false);
    assert_eq!(login["message"], "3 intentos");
    assert_eq!(login["access_token"], Value::Null);
}

/// Hallazgos de la segunda revisión: permisos en vivo, registros pendientes
/// y marca de leídos.
#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn second_review_fixes() {
    use crate::{auth, chat};
    use axum::{Router, middleware, routing::get};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let (pool, state) = setup().await;
    let tag = Uuid::new_v4().simple().to_string();

    // 13. El rol y el estado se leen en vivo, no del JWT.
    let admin = user(&pool, &format!("adm.{tag}@example.invalid"), "ACTIVE", "x").await;
    sqlx::query("UPDATE users SET rol = 'ADMIN' WHERE id = $1")
        .bind(admin)
        .execute(&pool)
        .await
        .unwrap();
    let token = auth::jwt::generate_access_token(admin, "ADMIN", 0, "test-only").unwrap();
    let app = Router::new()
        .route(
            "/rol",
            get(|Extension(user): Extension<AuthUser>| async move { user.role }),
        )
        .layer(middleware::from_fn(auth::middleware::jwt_auth))
        .layer(Extension(pool.clone()))
        .layer(Extension(state.config.clone()));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let request = || async {
        let mut stream = tokio::net::TcpStream::connect(address).await.unwrap();
        let raw = format!(
            "GET /rol HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer {token}\r\nConnection: close\r\n\r\n"
        );
        stream.write_all(raw.as_bytes()).await.unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).await.unwrap();
        response
    };
    assert!(request().await.ends_with("ADMIN"));
    sqlx::query("UPDATE users SET rol = 'MEMBER' WHERE id = $1")
        .bind(admin)
        .execute(&pool)
        .await
        .unwrap();
    assert!(
        request().await.ends_with("MEMBER"),
        "degradado sin esperar al token"
    );
    sqlx::query("UPDATE users SET estado = 'SUSPENDED' WHERE id = $1")
        .bind(admin)
        .execute(&pool)
        .await
        .unwrap();
    let suspended = request().await;
    assert!(suspended.starts_with("HTTP/1.1 401") && suspended.contains("invalid_access_token"));
    server.abort();

    // 14. Un registro pendiente reciente no se puede reemplazar; uno abandonado sí.
    let email = format!("pend.{tag}@example.invalid");
    let register =
        |phone: &'static str| {
            let (state, email) = (state.clone(), email.clone());
            async move {
                body(auth::service::register_user(State(state), Json(dto(json!({
                "name": "Ana Rivas", "email": email, "phone": phone, "password": "Secreta1!"
            })))).await)
            }
        };
    assert_eq!(register("+50370000001").await.0, StatusCode::CREATED);
    let (status, json) = register("+50370000002").await;
    assert_eq!(status, StatusCode::CONFLICT, "{json}");
    sqlx::query("UPDATE users SET created_at = NOW() - INTERVAL '25 hours' WHERE email = $1")
        .bind(&email)
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(register("+50370000002").await.0, StatusCode::CREATED);
    let phone: String = sqlx::query_scalar("SELECT telefono FROM users WHERE email = $1")
        .bind(&email)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(phone, "+50370000002", "el abandonado se reemplazó");

    // 15. Leer el chat marca hasta el último mensaje mostrado, no hasta NOW().
    let owner = user(&pool, &format!("chat.{tag}@example.invalid"), "ACTIVE", "x").await;
    let node = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO nodos (id, nombre, token_acceso, creador_id) VALUES ($1, 'Chat', $2, $3)",
    )
    .bind(node)
    .bind(node.to_string()[..32].to_string())
    .bind(owner)
    .execute(&pool)
    .await
    .unwrap();
    // Membresía anterior a los mensajes (last_read_at vale NOW() por defecto).
    sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id, rol, last_read_at) VALUES ($1, $2, 'OWNER', NOW() - INTERVAL '1 hour')")
        .bind(node)
        .bind(owner)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO mensajes (nodo_id, user_id, contenido, created_at) VALUES ($1, $2, 'visto', NOW() - INTERVAL '1 minute')")
        .bind(node).bind(owner).execute(&pool).await.unwrap();
    let auth_owner = AuthUser {
        user_id: owner,
        role: "MEMBER".into(),
        session_version: 0,
    };
    let _ = chat::service::list_mensajes(
        State(state.clone()),
        Extension(auth_owner.clone()),
        Path(node),
        Query(dto(json!({}))),
    )
    .await;
    // Mensaje de otra persona que llega después de lo mostrado pero antes de "ahora".
    let other = user(&pool, &format!("otro.{tag}@example.invalid"), "ACTIVE", "x").await;
    sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id) VALUES ($1, $2)")
        .bind(node)
        .bind(other)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO mensajes (nodo_id, user_id, contenido, created_at) VALUES ($1, $2, 'nuevo', NOW() - INTERVAL '30 seconds')")
        .bind(node).bind(other).execute(&pool).await.unwrap();
    let (_, unread) = body(
        chat::service::get_unread_count(State(state.clone()), Extension(auth_owner), Path(node))
            .await,
    );
    assert_eq!(unread["unread_count"], 1, "{unread}");

    sqlx::query("DELETE FROM nodos WHERE id = $1")
        .bind(node)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE email LIKE $1")
        .bind(format!("%{tag}%"))
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

/// Hallazgos de la revisión profunda: perfil, contraseña, cierre de sesión
/// y sondeo incremental del chat.
#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn deep_review_fixes() {
    use crate::{auth, chat};
    use axum::{Router, middleware, routing::get};
    use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let (pool, state) = setup().await;
    let tag = Uuid::new_v4().simple().to_string();
    let ana = user(
        &pool,
        &format!("perfil.{tag}@example.invalid"),
        "ACTIVE",
        "  Secreta1! ",
    )
    .await;
    let auth_ana = AuthUser {
        user_id: ana,
        role: "MEMBER".into(),
        session_version: 0,
    };
    let update = |payload: Value| {
        let (state, auth) = (state.clone(), auth_ana.clone());
        async move {
            body(
                auth::service::update_user_profile(
                    State(state),
                    Extension(auth),
                    Json(dto(payload)),
                )
                .await,
            )
        }
    };

    // 16. PUT /users/me ya no guarda cualquier texto como foto ni datos sin límite.
    let fake_jpeg = format!("data:image/jpeg;base64,{}", BASE64.encode(b"<svg>no</svg>"));
    assert_eq!(
        update(json!({"avatar_url": fake_jpeg})).await.0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        update(json!({"avatar_url": "https://rastreo.example/pixel.png"}))
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
    let png = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0];
    let declared_jpeg = format!("data:image/jpeg;base64,{}", BASE64.encode(png));
    let (status, saved) = update(json!({"avatar_url": declared_jpeg})).await;
    assert_eq!(status, StatusCode::OK, "{saved}");
    assert!(
        saved["profile"]["avatar_url"]
            .as_str()
            .unwrap()
            .starts_with("data:image/png;base64,"),
        "el tipo sale del contenido, no de lo declarado"
    );
    assert_eq!(
        update(json!({"avatar_url": ""})).await.1["profile"]["avatar_url"],
        Value::Null
    );
    assert_eq!(
        update(json!({"bio": "x".repeat(501)})).await.0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        update(json!({"avatar_color": "red"})).await.0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        update(json!({"name": " "})).await.0,
        StatusCode::BAD_REQUEST
    );
    let other = user(&pool, &format!("otra.{tag}@example.invalid"), "ACTIVE", "x").await;
    let taken: String = sqlx::query_scalar("SELECT telefono FROM users WHERE id = $1")
        .bind(other)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(
        update(json!({"telefono": taken})).await.0,
        StatusCode::CONFLICT
    );
    let upload = auth::service::upload_avatar(
        State(state.clone()),
        Extension(auth_ana.clone()),
        Json(dto(
            json!({"avatar_data": BASE64.encode(b"texto"), "content_type": "image/jpeg"}),
        )),
    )
    .await;
    assert_eq!(
        upload.0,
        StatusCode::BAD_REQUEST,
        "declarar JPEG ya no basta"
    );

    // 17. La contraseña no se recorta y este dispositivo conserva la sesión.
    let old_refresh = Uuid::new_v4();
    sqlx::query("INSERT INTO refresh_tokens (token, user_id, expires_at) VALUES ($1, $2, NOW() + INTERVAL '1 day')")
        .bind(old_refresh)
        .bind(ana)
        .execute(&pool)
        .await
        .unwrap();
    let (status, changed) = body(
        auth::service::change_user_password(
            State(state.clone()),
            Extension(auth_ana.clone()),
            Json(dto(
                json!({"current_password": "  Secreta1! ", "new_password": "Nueva2!clave"}),
            )),
        )
        .await,
    );
    assert_eq!(status, StatusCode::OK, "{changed}");
    let new_refresh = Uuid::parse_str(changed["refresh_token"].as_str().unwrap()).unwrap();
    assert!(changed["access_token"].is_string());
    let sessions: Vec<Uuid> =
        sqlx::query_scalar("SELECT token FROM refresh_tokens WHERE user_id = $1")
            .bind(ana)
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(
        sessions,
        vec![new_refresh],
        "las demás sesiones se cerraron"
    );

    // 18. Cerrar sesión invalida al instante los accesos emitidos antes.
    let app = Router::new()
        .route("/yo", get(|| async { "ok" }))
        .layer(middleware::from_fn(auth::middleware::jwt_auth))
        .layer(Extension(pool.clone()))
        .layer(Extension(state.config.clone()));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let request = |token: String| async move {
        let mut stream = tokio::net::TcpStream::connect(address).await.unwrap();
        let raw = format!(
            "GET /yo HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer {token}\r\nConnection: close\r\n\r\n"
        );
        stream.write_all(raw.as_bytes()).await.unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).await.unwrap();
        response
    };
    // Versión de sesión: 0 al crear la cuenta, 1 tras el cambio de contraseña.
    let token = |version: i32| {
        auth::jwt::generate_access_token(ana, "MEMBER", version, "test-only").unwrap()
    };
    assert!(
        request(token(0)).await.starts_with("HTTP/1.1 401"),
        "emitido antes del cambio de contraseña"
    );
    let earlier = token(1);
    assert!(request(earlier.clone()).await.ends_with("ok"));
    assert_eq!(
        auth::session::logout(
            State(state.clone()),
            Json(dto(json!({"refresh_token": new_refresh.to_string()})))
        )
        .await,
        StatusCode::NO_CONTENT
    );
    assert!(request(earlier).await.contains("invalid_access_token"));
    assert!(
        request(token(2)).await.ends_with("ok"),
        "otros dispositivos renuevan y siguen"
    );
    server.abort();

    // 19. El sondeo del chat pide solo lo posterior al último mensaje conocido.
    let node = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO nodos (id, nombre, token_acceso, creador_id) VALUES ($1, 'Sondeo', $2, $3)",
    )
    .bind(node)
    .bind(node.to_string()[..32].to_string())
    .bind(ana)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id, rol) VALUES ($1, $2, 'OWNER')")
        .bind(node)
        .bind(ana)
        .execute(&pool)
        .await
        .unwrap();
    let mut ids = Vec::new();
    for minutes in [3, 2, 1] {
        let id: Uuid = sqlx::query_scalar("INSERT INTO mensajes (nodo_id, user_id, contenido, created_at) VALUES ($1, $2, 'm', NOW() - make_interval(mins => $3)) RETURNING id")
            .bind(node)
            .bind(ana)
            .bind(minutes)
            .fetch_one(&pool)
            .await
            .unwrap();
        ids.push(id);
    }
    let list = |query: Value| {
        let (state, auth) = (state.clone(), auth_ana.clone());
        async move {
            body(
                chat::service::list_mensajes(
                    State(state),
                    Extension(auth),
                    Path(node),
                    Query(dto(query)),
                )
                .await,
            )
            .1
        }
    };
    let since_first = list(json!({"despues_de": ids[0]})).await;
    assert_eq!(since_first["incremental"], true);
    let returned: Vec<&str> = since_first["mensajes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["id"].as_str().unwrap())
        .collect();
    assert_eq!(returned, vec![ids[1].to_string(), ids[2].to_string()]);
    let unknown = list(json!({"despues_de": Uuid::new_v4()})).await;
    assert_eq!(
        unknown["incremental"],
        Value::Null,
        "cursor ajeno: lista completa"
    );
    assert_eq!(unknown["mensajes"].as_array().unwrap().len(), 3);

    sqlx::query("DELETE FROM nodos WHERE id = $1")
        .bind(node)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE email LIKE $1")
        .bind(format!("%{tag}%"))
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

/// Programación tipo calendario de equipo: series, invitados con respuesta,
/// "Reunirse ahora" y llamadas privadas.
#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn meeting_scheduling() {
    use crate::nodos::reuniones;
    let (pool, state) = setup().await;
    let tag = Uuid::new_v4().simple().to_string();
    let owner = user(&pool, &format!("org.{tag}@example.invalid"), "ACTIVE", "x").await;
    let ana = user(&pool, &format!("ana.{tag}@example.invalid"), "ACTIVE", "x").await;
    let beto = user(&pool, &format!("beto.{tag}@example.invalid"), "ACTIVE", "x").await;
    let outsider = user(
        &pool,
        &format!("fuera.{tag}@example.invalid"),
        "ACTIVE",
        "x",
    )
    .await;
    let auth = |user_id| AuthUser {
        user_id,
        role: "MEMBER".into(),
        session_version: 0,
    };
    let node = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO nodos (id, nombre, token_acceso, creador_id) VALUES ($1, 'Agenda', $2, $3)",
    )
    .bind(node)
    .bind(node.to_string()[..32].to_string())
    .bind(owner)
    .execute(&pool)
    .await
    .unwrap();
    for (u, rol) in [(owner, "OWNER"), (ana, "MEMBER"), (beto, "MEMBER")] {
        sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id, rol) VALUES ($1, $2, $3)")
            .bind(node)
            .bind(u)
            .bind(rol)
            .execute(&pool)
            .await
            .unwrap();
    }
    let create = |payload: Value| {
        let state = state.clone();
        async move {
            body(
                reuniones::create_reunion(
                    State(state),
                    Extension(auth(owner)),
                    Path(node),
                    Json(dto(payload)),
                )
                .await,
            )
        }
    };
    let start = chrono::Utc::now() + chrono::Duration::days(2);
    let end = start + chrono::Duration::minutes(45);

    // Sin enlace externo: la reunión es de IronLink. Serie semanal de 3 con Ana.
    let (status, created) = create(json!({
        "titulo": "Daily", "fecha_inicio": start, "fecha_fin": end,
        "repeticion": {"frecuencia": "weekly", "ocurrencias": 3},
        "invitados": [ana], "zona_minutos": -360
    }))
    .await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    assert_eq!(created["ocurrencias"], 3);
    let first = Uuid::parse_str(created["reunion"]["id"].as_str().unwrap()).unwrap();
    assert_eq!(created["reunion"]["repeticion"], "weekly");
    assert_eq!(created["reunion"]["invitados"], 2, "organizador e invitada");
    assert_eq!(created["reunion"]["mi_respuesta"], "aceptada");
    let series: Vec<(Uuid, chrono::DateTime<chrono::Utc>)> = sqlx::query_as(
        "SELECT id, fecha_inicio FROM reuniones WHERE serie_id = (SELECT serie_id FROM reuniones WHERE id = $1) ORDER BY fecha_inicio",
    )
    .bind(first)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(series.len(), 3);
    assert_eq!(series[1].1 - series[0].1, chrono::Duration::days(7));
    let invitations: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM notificaciones WHERE tipo = 'invitacion' AND user_id = $1",
    )
    .bind(ana)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(invitations, 1, "un aviso por serie");

    // Invitar a alguien de fuera del nodo o repetir sin fechas válidas falla.
    assert_eq!(
        create(json!({"titulo": "X", "fecha_inicio": start, "invitados": [outsider]}))
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        create(json!({"titulo": "X", "fecha_inicio": start, "repeticion": {"frecuencia": "weekly", "ocurrencias": 60}})).await.0,
        StatusCode::BAD_REQUEST
    );
    // Sin lista de invitados se invita a todo el nodo.
    let (_, all) = create(json!({"titulo": "Retro", "fecha_inicio": start})).await;
    assert_eq!(all["reunion"]["invitados"], 3);

    // Ana declina toda la serie; Beto no está invitado a ella.
    let respond = |who: Uuid, respuesta: &str, serie: bool| {
        let state = state.clone();
        let payload = json!({"respuesta": respuesta, "serie": serie});
        async move {
            body(
                reuniones::respond(
                    State(state),
                    Extension(auth(who)),
                    Path((node, first)),
                    Json(dto(payload)),
                )
                .await,
            )
        }
    };
    assert_eq!(respond(ana, "rechazada", true).await.0, StatusCode::OK);
    let declined: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM reunion_invitados WHERE user_id = $1 AND respuesta = 'rechazada'",
    )
    .bind(ana)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(declined, 3);
    assert_eq!(
        respond(beto, "aceptada", false).await.0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        respond(ana, "quizas", false).await.0,
        StatusCode::BAD_REQUEST
    );

    // Llamada privada instantánea con Ana: Beto no la ve ni puede entrar.
    let hub = Arc::new(crate::rtc::server::RoomHub::default());
    let (status, call) = body(
        reuniones::meet_now(
            State(state.clone()),
            Extension(auth(owner)),
            Extension(hub.clone()),
            Path(node),
            Json(dto(
                json!({"titulo": "Llamada con Ana", "invitados": [ana], "privada": true}),
            )),
        )
        .await,
    );
    assert_eq!(status, StatusCode::CREATED, "{call}");
    assert_eq!(call["reunion"]["rtc_estado"], "active");
    let call_id = Uuid::parse_str(call["reunion"]["id"].as_str().unwrap()).unwrap();
    let visible = |who: Uuid| {
        let state = state.clone();
        async move {
            let (_, list) = body(
                reuniones::list_reuniones(State(state), Extension(auth(who)), Path(node)).await,
            );
            list["reuniones"]
                .as_array()
                .unwrap()
                .iter()
                .any(|r| r["id"] == call_id.to_string())
        }
    };
    assert!(visible(ana).await);
    assert!(!visible(beto).await, "llamada privada oculta");
    assert!(
        crate::rtc::server::member_allowed(&pool, call_id, ana)
            .await
            .unwrap()
    );
    assert!(
        !crate::rtc::server::member_allowed(&pool, call_id, beto)
            .await
            .unwrap()
    );
    let started: Vec<Uuid> = sqlx::query_scalar(
        "SELECT user_id FROM notificaciones WHERE reunion_id = $1 AND tipo = 'reunion_iniciada'",
    )
    .bind(call_id)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(started, vec![ana]);
    assert_eq!(
        body(
            reuniones::meet_now(
                State(state.clone()),
                Extension(auth(owner)),
                Extension(hub.clone()),
                Path(node),
                Json(dto(json!({"privada": true})))
            )
            .await
        )
        .0,
        StatusCode::BAD_REQUEST,
        "privada sin invitados"
    );
    // Una reunión abierta (sin título) queda visible para todo el nodo.
    let (_, open) = body(
        reuniones::meet_now(
            State(state.clone()),
            Extension(auth(beto)),
            Extension(hub),
            Path(node),
            Json(dto(json!({}))),
        )
        .await,
    );
    assert!(
        open["reunion"]["titulo"]
            .as_str()
            .unwrap()
            .starts_with("Reunión instantánea de")
    );

    // Cancelar toda la serie.
    let (status, removed) = body(
        reuniones::delete_reunion(
            State(state.clone()),
            Extension(auth(owner)),
            Path((node, first)),
            Query(dto(json!({"serie": true}))),
        )
        .await,
    );
    assert_eq!(status, StatusCode::OK, "{removed}");
    assert_eq!(removed["ocurrencias"], 3);

    sqlx::query("DELETE FROM nodos WHERE id = $1")
        .bind(node)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE email LIKE $1")
        .bind(format!("%{tag}%"))
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn friend_requests() {
    use crate::amigos;
    use crate::rtc::server::RoomHub;
    let (pool, state) = setup().await;
    let hub = Arc::new(RoomHub::default());
    let tag = Uuid::new_v4().simple().to_string();
    let mut ids = Vec::new();
    for (name, estado) in [
        ("Ana", "ACTIVE"),
        ("Bea", "ACTIVE"),
        ("Carlos", "ACTIVE"),
        ("Dora", "SUSPENDED"),
        ("Eva", "ACTIVE"),
    ] {
        let id = user(
            &pool,
            &format!("{}.{tag}@example.invalid", name.to_lowercase()),
            estado,
            "x",
        )
        .await;
        sqlx::query("UPDATE users SET name = $2 WHERE id = $1")
            .bind(id)
            .bind(format!("{name} {tag}"))
            .execute(&pool)
            .await
            .unwrap();
        ids.push(id);
    }
    let (ana, bea, carlos, dora, eva) = (ids[0], ids[1], ids[2], ids[3], ids[4]);
    let auth = |user_id| AuthUser {
        user_id,
        role: "MEMBER".into(),
        session_version: 0,
    };
    // Ana y Bea comparten un nodo; Carlos no comparte ninguno con Ana.
    let node = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO nodos (id, nombre, token_acceso, creador_id) VALUES ($1, 'Amigos', $2, $3)",
    )
    .bind(node)
    .bind(node.to_string()[..32].to_string())
    .bind(ana)
    .execute(&pool)
    .await
    .unwrap();
    for u in [ana, bea] {
        sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id, rol) VALUES ($1, $2, 'MEMBER')")
            .bind(node)
            .bind(u)
            .execute(&pool)
            .await
            .unwrap();
    }
    let search = |who: Uuid, q: &str| {
        let (state, q) = (state.clone(), q.to_string());
        async move {
            body(
                amigos::buscar(
                    State(state),
                    Extension(auth(who)),
                    Query(dto(json!({ "q": q }))),
                )
                .await,
            )
        }
    };
    let send = |who: Uuid, to: Uuid| {
        let (state, hub) = (state.clone(), hub.clone());
        async move {
            body(
                amigos::enviar(
                    State(state),
                    Extension(auth(who)),
                    Extension(hub),
                    Json(dto(json!({ "user_id": to }))),
                )
                .await,
            )
        }
    };
    let requests = |who: Uuid| {
        let state = state.clone();
        async move { body(amigos::solicitudes(State(state), Extension(auth(who))).await).1 }
    };

    // 1. Búsqueda: mínimo 2 caracteres, solo cuentas activas, sin teléfono
    // ni correo, sin incluirse a uno mismo y con comodines literales.
    assert_eq!(search(ana, " a ").await.0, StatusCode::BAD_REQUEST);
    let (status, json) = search(ana, &tag[..12]).await;
    assert_eq!(status, StatusCode::OK, "{json}");
    let found = json["usuarios"].as_array().unwrap();
    let found_ids: Vec<String> = found
        .iter()
        .map(|u| u["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(found.len(), 3, "{json}");
    assert!(
        !found_ids.contains(&ana.to_string()),
        "no se encuentra a sí misma"
    );
    assert!(!found_ids.contains(&dora.to_string()), "cuenta suspendida");
    assert!(!json.to_string().contains("telefono") && !json.to_string().contains("email"));
    let bea_row = found.iter().find(|u| u["id"] == bea.to_string()).unwrap();
    assert_eq!(bea_row["comparte_nodo"], true);
    assert_eq!(bea_row["amistad"], "ninguna");
    let carlos_row = found
        .iter()
        .find(|u| u["id"] == carlos.to_string())
        .unwrap();
    assert_eq!(carlos_row["comparte_nodo"], false);
    // Por correo solo vale el correo completo (sin distinguir mayúsculas y
    // recortando espacios); un fragmento del correo no encuentra a nadie.
    let carlos_email = format!("carlos.{tag}@example.invalid");
    let by_email = search(ana, &format!("  {}  ", carlos_email.to_uppercase()))
        .await
        .1;
    assert_eq!(
        by_email["usuarios"].as_array().unwrap().len(),
        1,
        "{by_email}"
    );
    assert_eq!(by_email["usuarios"][0]["id"], carlos.to_string());
    for partial in [
        format!("carlos.{}", &tag[..6]),
        format!("carlos.{tag}@example"),
        "@example.invalid".to_string(),
        format!("{tag}@example.invalid"),
    ] {
        assert_eq!(
            search(ana, &partial).await.1["usuarios"]
                .as_array()
                .unwrap()
                .len(),
            0,
            "correo parcial: {partial}"
        );
    }
    assert_eq!(
        search(ana, &format!("ana.{tag}@example.invalid")).await.1["usuarios"],
        json!([]),
        "el propio correo no se devuelve"
    );
    assert_eq!(
        search(ana, "%%").await.1["usuarios"]
            .as_array()
            .unwrap()
            .len(),
        0,
        "% es literal"
    );

    // 2. Enviar: a sí mismo no, a cuentas suspendidas no, sin duplicados.
    assert_eq!(send(ana, ana).await.0, StatusCode::BAD_REQUEST);
    assert_eq!(send(ana, dora).await.0, StatusCode::NOT_FOUND);
    let (status, json) = send(ana, bea).await;
    assert_eq!(status, StatusCode::CREATED, "{json}");
    assert_eq!(json["estado"], "pendiente");
    let to_bea: Uuid = dto(json["solicitud_id"].clone());
    assert_eq!(send(ana, bea).await.0, StatusCode::CONFLICT);
    assert_eq!(
        search(ana, &format!("bea {}", &tag[..8])).await.1["usuarios"][0]["amistad"],
        "enviada"
    );
    assert_eq!(
        search(bea, &format!("ana {}", &tag[..8])).await.1["usuarios"][0]["amistad"],
        "recibida"
    );
    assert_eq!(requests(ana).await["enviadas"].as_array().unwrap().len(), 1);
    let received = requests(bea).await;
    assert_eq!(received["recibidas"][0]["id"], to_bea.to_string());
    assert_eq!(received["recibidas"][0]["comparte_nodo"], true);
    assert_eq!(amigos::pendientes_recibidas(&pool, bea).await.unwrap(), 1);

    // 3. Solo quien la recibe acepta o rechaza; solo quien la envía cancela.
    let act = |who: Uuid, id: Uuid, what: &'static str| {
        let (state, hub) = (state.clone(), hub.clone());
        async move {
            let (state, auth, hub, path) =
                (State(state), Extension(auth(who)), Extension(hub), Path(id));
            match what {
                "aceptar" => amigos::aceptar(state, auth, hub, path).await.0,
                "rechazar" => amigos::rechazar(state, auth, hub, path).await.0,
                _ => amigos::cancelar(state, auth, hub, path).await.0,
            }
        }
    };
    assert_eq!(act(ana, to_bea, "aceptar").await, StatusCode::NOT_FOUND);
    assert_eq!(act(carlos, to_bea, "rechazar").await, StatusCode::NOT_FOUND);
    assert_eq!(act(bea, to_bea, "cancelar").await, StatusCode::NOT_FOUND);
    // Rechazar = ignorar: desaparece para Bea; Ana no recibe aviso (la sigue
    // viendo como enviada) y no puede reenviarla durante 30 días.
    assert_eq!(act(bea, to_bea, "rechazar").await, StatusCode::OK);
    assert_eq!(act(bea, to_bea, "aceptar").await, StatusCode::NOT_FOUND);
    assert_eq!(requests(bea).await["recibidas"], json!([]));
    assert_eq!(amigos::pendientes_recibidas(&pool, bea).await.unwrap(), 0);
    assert_eq!(requests(ana).await["enviadas"][0]["id"], to_bea.to_string());
    assert_eq!(
        search(ana, &format!("bea {}", &tag[..8])).await.1["usuarios"][0]["amistad"],
        "enviada"
    );
    let bea_view = search(bea, &format!("ana {}", &tag[..8])).await.1;
    assert_eq!(bea_view["usuarios"][0]["amistad"], "ninguna");
    assert_eq!(bea_view["usuarios"][0]["solicitud_id"], Value::Null);
    assert_eq!(send(ana, bea).await.0, StatusCode::CONFLICT);
    assert_eq!(act(ana, to_bea, "cancelar").await, StatusCode::OK);
    let (status, json) = send(ana, bea).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{json}");
    assert_eq!(json["message"], amigos::SOLICITUD_NO_DISPONIBLE);
    // Pasados 30 días se puede volver a enviar.
    sqlx::query("UPDATE amistad_rechazos SET created_at = NOW() - INTERVAL '31 days' WHERE solicitante = $1")
        .bind(ana)
        .execute(&pool)
        .await
        .unwrap();
    // Cancelar la propia (sin rechazo) sí permite reenviarla.
    let again: Uuid = dto(send(ana, bea).await.1["solicitud_id"].clone());
    assert_eq!(act(ana, again, "cancelar").await, StatusCode::OK);
    assert_eq!(requests(bea).await["recibidas"], json!([]));
    let third: Uuid = dto(send(ana, bea).await.1["solicitud_id"].clone());
    assert_eq!(act(bea, third, "aceptar").await, StatusCode::OK);
    assert_eq!(
        send(bea, ana).await.0,
        StatusCode::CONFLICT,
        "ya son amigas"
    );

    // 4. Si la otra persona ya había enviado una, se acepta automáticamente.
    assert_eq!(send(carlos, ana).await.0, StatusCode::CREATED);
    let (status, json) = send(ana, carlos).await;
    assert_eq!(status, StatusCode::OK, "{json}");
    assert_eq!(json["estado"], "aceptada");
    let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM amistades WHERE $1 IN (solicitante, destinatario) AND $2 IN (solicitante, destinatario)")
        .bind(ana)
        .bind(carlos)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(rows, 1, "sin duplicados en ambos sentidos");

    // 5. Lista de amigos con nodos en común (para el chat directo).
    let (status, json) = body(amigos::listar(State(state.clone()), Extension(auth(ana))).await);
    assert_eq!(status, StatusCode::OK);
    let friends = json["amigos"].as_array().unwrap();
    assert_eq!(friends.len(), 2, "{json}");
    let bea_friend = friends.iter().find(|f| f["id"] == bea.to_string()).unwrap();
    assert_eq!(bea_friend["nodos_comunes"][0]["id"], node.to_string());
    let carlos_friend = friends
        .iter()
        .find(|f| f["id"] == carlos.to_string())
        .unwrap();
    assert_eq!(carlos_friend["nodos_comunes"], json!([]));
    assert!(!json.to_string().contains("telefono"));

    // 6. Eliminar amigo afecta a ambos; una segunda vez ya no existe.
    let remove = |who: Uuid, friend: Uuid| {
        let (state, hub) = (state.clone(), hub.clone());
        async move {
            amigos::eliminar(
                State(state),
                Extension(auth(who)),
                Extension(hub),
                Path(friend),
            )
            .await
            .0
        }
    };
    assert_eq!(remove(carlos, ana).await, StatusCode::OK);
    assert_eq!(remove(ana, carlos).await, StatusCode::NOT_FOUND);
    assert_eq!(remove(ana, eva).await, StatusCode::NOT_FOUND);

    // 7. Límite de solicitudes por hora, aunque se cancelen.
    for _ in 0..amigos::MAX_SOLICITUDES_POR_HORA {
        sqlx::query("INSERT INTO amistad_envios (user_id) VALUES ($1)")
            .bind(eva)
            .execute(&pool)
            .await
            .unwrap();
    }
    assert_eq!(send(eva, ana).await.0, StatusCode::TOO_MANY_REQUESTS);

    // 8. La restricción de la tabla impide solicitarse a uno mismo.
    assert!(
        sqlx::query("INSERT INTO amistades (solicitante, destinatario) VALUES ($1, $1)")
            .bind(ana)
            .execute(&pool)
            .await
            .is_err()
    );

    sqlx::query("DELETE FROM nodos WHERE id = $1")
        .bind(node)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE email LIKE $1")
        .bind(format!("%{tag}%"))
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn social_privacy() {
    use crate::rtc::server::RoomHub;
    use crate::{amigos, amigos_chat, chat::direct};
    let (pool, state) = setup().await;
    let hub = Arc::new(RoomHub::default());
    let tag = Uuid::new_v4().simple().to_string();
    let mut ids = Vec::new();
    for name in ["Ana", "Bea", "Carlos", "Dani"] {
        let id = user(
            &pool,
            &format!("{}.{tag}@example.invalid", name.to_lowercase()),
            "ACTIVE",
            "x",
        )
        .await;
        sqlx::query("UPDATE users SET name = $2 WHERE id = $1")
            .bind(id)
            .bind(format!("{name} {tag}"))
            .execute(&pool)
            .await
            .unwrap();
        ids.push(id);
    }
    let (ana, bea, carlos, dani) = (ids[0], ids[1], ids[2], ids[3]);
    let auth = |user_id| AuthUser {
        user_id,
        role: "MEMBER".into(),
        session_version: 0,
    };
    // Ana, Bea y Dani comparten un nodo; Carlos no comparte ninguno.
    let node = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO nodos (id, nombre, token_acceso, creador_id) VALUES ($1, 'Privacidad', $2, $3)",
    )
    .bind(node)
    .bind(node.to_string()[..32].to_string())
    .bind(ana)
    .execute(&pool)
    .await
    .unwrap();
    for u in [ana, bea, dani] {
        sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id, rol) VALUES ($1, $2, 'MEMBER')")
            .bind(node)
            .bind(u)
            .execute(&pool)
            .await
            .unwrap();
    }
    let search = |who: Uuid, q: String| {
        let state = state.clone();
        async move {
            body(
                amigos::buscar(
                    State(state),
                    Extension(auth(who)),
                    Query(dto(json!({ "q": q }))),
                )
                .await,
            )
        }
    };
    let send = |who: Uuid, to: Uuid| {
        let (state, hub) = (state.clone(), hub.clone());
        async move {
            body(
                amigos::enviar(
                    State(state),
                    Extension(auth(who)),
                    Extension(hub),
                    Json(dto(json!({ "user_id": to }))),
                )
                .await,
            )
        }
    };
    let privacy = |who: Uuid, value: &'static str| {
        let state = state.clone();
        async move {
            body(
                amigos::guardar_privacidad(
                    State(state),
                    Extension(auth(who)),
                    Json(dto(json!({ "solicitudes_de": value }))),
                )
                .await,
            )
            .0
        }
    };
    let chat_send = |who: Uuid, to: Uuid, text: String| {
        let (state, hub) = (state.clone(), hub.clone());
        async move {
            body(
                amigos_chat::enviar(
                    State(state),
                    Extension(auth(who)),
                    Extension(hub),
                    Path(to),
                    Json(dto(json!({ "content": text }))),
                )
                .await,
            )
        }
    };
    let chat_history = |who: Uuid, peer: Uuid| {
        let state = state.clone();
        async move { body(amigos_chat::historial(State(state), Extension(auth(who)), Path(peer)).await) }
    };
    let inbox = |who: Uuid| {
        let state = state.clone();
        async move { body(amigos_chat::conversaciones(State(state), Extension(auth(who))).await).1 }
    };
    let node_send = |who: Uuid, to: Uuid| {
        let state = state.clone();
        async move {
            direct::send(
                State(state),
                Extension(auth(who)),
                Path((node, to)),
                Json(dto(json!({ "content": "Hola desde el nodo" }))),
            )
            .await
            .0
        }
    };
    let block = |who: Uuid, target: Uuid, on: bool| {
        let (state, hub) = (state.clone(), hub.clone());
        async move {
            let (state, auth, hub, path) = (
                State(state),
                Extension(auth(who)),
                Extension(hub),
                Path(target),
            );
            if on {
                amigos::bloquear(state, auth, hub, path).await.0
            } else {
                amigos::desbloquear(state, auth, hub, path).await.0
            }
        }
    };
    let received = |who: Uuid| {
        let state = state.clone();
        async move {
            body(amigos::solicitudes(State(state), Extension(auth(who))).await).1["recibidas"]
                .as_array()
                .unwrap()
                .len()
        }
    };

    // 1. Privacidad: por defecto «todos»; «nadie» y «nodos» se respetan con
    // el mismo mensaje genérico que un bloqueo o una solicitud ignorada.
    let (status, json) = body(amigos::privacidad(State(state.clone()), Extension(auth(bea))).await);
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json["solicitudes_de"], "todos");
    assert_eq!(privacy(bea, "amigos").await, StatusCode::BAD_REQUEST);
    assert_eq!(privacy(bea, "nadie").await, StatusCode::OK);
    for who in [ana, carlos] {
        let (status, json) = send(who, bea).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{json}");
        assert_eq!(json["message"], amigos::SOLICITUD_NO_DISPONIBLE);
    }
    assert_eq!(privacy(bea, "nodos").await, StatusCode::OK);
    let (_, json) = body(amigos::privacidad(State(state.clone()), Extension(auth(bea))).await);
    assert_eq!(json["solicitudes_de"], "nodos");
    assert_eq!(send(carlos, bea).await.0, StatusCode::FORBIDDEN);
    let (status, json) = send(ana, bea).await;
    assert_eq!(status, StatusCode::CREATED, "comparten nodo: {json}");
    let ana_to_bea: Uuid = dto(json["solicitud_id"].clone());
    assert_eq!(privacy(bea, "todos").await, StatusCode::OK);
    // La privacidad de quien acepta no impide aceptar una solicitud recibida.
    assert_eq!(send(carlos, ana).await.0, StatusCode::CREATED);
    assert_eq!(privacy(ana, "nadie").await, StatusCode::OK);
    let (status, json) = send(ana, carlos).await;
    assert_eq!(status, StatusCode::OK, "{json}");
    assert_eq!(json["estado"], "aceptada");
    assert_eq!(privacy(ana, "todos").await, StatusCode::OK);

    // 2. Chat de amistad sin nodo en común (Ana y Carlos).
    let (status, json) = chat_history(ana, carlos).await;
    assert_eq!(status, StatusCode::OK, "{json}");
    assert_eq!(json["messages"], json!([]), "la conversación existe vacía");
    let (status, json) = chat_send(ana, carlos, "  Hola, Carlos  ".into()).await;
    assert_eq!(status, StatusCode::CREATED, "{json}");
    assert_eq!(json["message"]["content"], "Hola, Carlos");
    assert_eq!(json["message"]["kind"], "text");
    assert_eq!(
        chat_send(ana, carlos, "   ".into()).await.0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        chat_send(ana, carlos, "a".repeat(2001)).await.0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        chat_send(ana, carlos, "ñ".repeat(2000)).await.0,
        StatusCode::CREATED,
        "2000 caracteres, no bytes"
    );
    assert_eq!(
        chat_send(ana, ana, "Yo".into()).await.0,
        StatusCode::BAD_REQUEST
    );
    let carlos_inbox = inbox(carlos).await;
    assert_eq!(carlos_inbox["conversaciones"].as_array().unwrap().len(), 1);
    assert_eq!(
        carlos_inbox["conversaciones"][0]["user_id"],
        ana.to_string()
    );
    assert_eq!(carlos_inbox["conversaciones"][0]["no_leidos"], 2);
    assert!(!carlos_inbox.to_string().contains("email"));
    assert_eq!(amigos_chat::no_leidos(&pool, carlos).await.unwrap(), 2);
    let (status, json) = chat_history(carlos, ana).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json["messages"].as_array().unwrap().len(), 2);
    assert_eq!(json["messages"][0]["content"], "Hola, Carlos");
    // Leer marca como leído hasta lo mostrado; lo nuevo sigue sin leer.
    assert_eq!(inbox(carlos).await["conversaciones"][0]["no_leidos"], 0);
    let (_, json) = chat_history(ana, carlos).await;
    assert!(json["messages"][0]["read_at"].is_string(), "{json}");
    assert_eq!(
        chat_send(ana, carlos, "¿Sigues?".into()).await.0,
        StatusCode::CREATED
    );
    assert_eq!(amigos_chat::no_leidos(&pool, carlos).await.unwrap(), 1);
    // Solo entre amigos: Bea y Carlos no lo son.
    for (who, peer) in [(bea, carlos), (carlos, bea)] {
        let (status, json) = chat_send(who, peer, "Hola".into()).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{json}");
        assert_eq!(chat_history(who, peer).await.0, StatusCode::FORBIDDEN);
    }
    assert_eq!(inbox(bea).await["conversaciones"], json!([]));

    // 3. Bloqueo: Bea acepta y Ana la bloquea; se borra la amistad.
    let (_, json) = body(
        amigos::aceptar(
            State(state.clone()),
            Extension(auth(bea)),
            Extension(hub.clone()),
            Path(ana_to_bea),
        )
        .await,
    );
    assert_eq!(json["estado"], "aceptada");
    assert_eq!(
        chat_send(bea, ana, "Hola, Ana".into()).await.0,
        StatusCode::CREATED
    );
    assert_eq!(block(ana, ana, true).await, StatusCode::BAD_REQUEST);
    assert_eq!(
        block(ana, Uuid::new_v4(), true).await,
        StatusCode::NOT_FOUND
    );
    assert_eq!(block(ana, bea, true).await, StatusCode::OK);
    assert_eq!(block(ana, bea, true).await, StatusCode::OK, "idempotente");
    let (_, friends) = body(amigos::listar(State(state.clone()), Extension(auth(ana))).await);
    assert!(!friends.to_string().contains(&bea.to_string()));
    let (_, json) = body(amigos::bloqueados(State(state.clone()), Extension(auth(ana))).await);
    assert_eq!(json["bloqueados"][0]["id"], bea.to_string());
    // Bea no encuentra a Ana (ni por nombre ni por correo exacto).
    let by_name = search(bea, format!("ana {tag}")).await.1;
    assert_eq!(by_name["usuarios"], json!([]), "{by_name}");
    let by_mail = search(bea, format!("ana.{tag}@example.invalid")).await.1;
    assert_eq!(by_mail["usuarios"], json!([]));
    // Ana sí la ve, marcada como bloqueada, para poder desbloquearla.
    let ana_view = search(ana, format!("bea {tag}")).await.1;
    assert_eq!(ana_view["usuarios"][0]["bloqueado"], true);
    assert_eq!(ana_view["usuarios"][0]["amistad"], "ninguna");
    // Solicitudes: genérica para Bea; Ana debe desbloquear antes.
    let (status, json) = send(bea, ana).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(json["message"], amigos::SOLICITUD_NO_DISPONIBLE);
    assert_eq!(send(ana, bea).await.0, StatusCode::CONFLICT);
    // Chats de amistad y de nodo, en ambos sentidos.
    assert_eq!(
        chat_send(bea, ana, "¿Hola?".into()).await.0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(chat_history(ana, bea).await.0, StatusCode::FORBIDDEN);
    assert_eq!(
        inbox(ana).await["conversaciones"].as_array().unwrap().len(),
        1
    );
    assert_eq!(node_send(bea, ana).await, StatusCode::FORBIDDEN);
    assert_eq!(node_send(ana, bea).await, StatusCode::FORBIDDEN);
    assert_eq!(
        node_send(dani, ana).await,
        StatusCode::CREATED,
        "sin bloqueo"
    );
    // Bloquear también borra las solicitudes pendientes de la pareja.
    assert_eq!(send(dani, ana).await.0, StatusCode::CREATED);
    assert_eq!(received(ana).await, 1);
    assert_eq!(block(ana, dani, true).await, StatusCode::OK);
    assert_eq!(received(ana).await, 0);
    assert_eq!(block(ana, dani, false).await, StatusCode::OK);
    // Desbloquear no restaura la amistad; una segunda vez ya no existe.
    assert_eq!(block(ana, bea, false).await, StatusCode::OK);
    assert_eq!(block(ana, bea, false).await, StatusCode::NOT_FOUND);
    assert_eq!(
        search(bea, format!("ana {tag}")).await.1["usuarios"][0]["amistad"],
        "ninguna"
    );
    assert_eq!(
        chat_send(bea, ana, "¿Hola?".into()).await.0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(node_send(bea, ana).await, StatusCode::CREATED);

    // 4. Límites: 60 mensajes de amistad y 60 búsquedas por minuto.
    sqlx::query(
        "INSERT INTO mensajes_amistad (sender_id, recipient_id, content) \
         SELECT $1, $2, 'relleno' FROM generate_series(1, 60)",
    )
    .bind(carlos)
    .bind(ana)
    .execute(&pool)
    .await
    .unwrap();
    assert_eq!(
        chat_send(carlos, ana, "Uno más".into()).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    sqlx::query(
        "INSERT INTO busquedas_personas (user_id) SELECT $1 FROM generate_series(1, $2::int)",
    )
    .bind(dani)
    .bind(amigos::MAX_BUSQUEDAS_POR_MINUTO as i32)
    .execute(&pool)
    .await
    .unwrap();
    assert_eq!(
        search(dani, format!("ana {tag}")).await.0,
        StatusCode::TOO_MANY_REQUESTS
    );

    sqlx::query("DELETE FROM nodos WHERE id = $1")
        .bind(node)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM users WHERE email LIKE $1")
        .bind(format!("%{tag}%"))
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn calendar_details() {
    use crate::nodos::reuniones;
    use chrono::{DateTime, Duration, TimeZone, Utc};
    let (pool, state) = setup().await;
    let tag = Uuid::new_v4().simple().to_string();
    let owner = user(&pool, &format!("org.{tag}@example.invalid"), "ACTIVE", "x").await;
    let ana = user(&pool, &format!("ana.{tag}@example.invalid"), "ACTIVE", "x").await;
    let beto = user(&pool, &format!("beto.{tag}@example.invalid"), "ACTIVE", "x").await;
    let outsider = user(
        &pool,
        &format!("fuera.{tag}@example.invalid"),
        "ACTIVE",
        "x",
    )
    .await;
    let auth = |user_id| AuthUser {
        user_id,
        role: "MEMBER".into(),
        session_version: 0,
    };
    let node = Uuid::new_v4();
    let other = Uuid::new_v4();
    for (id, creator) in [(node, owner), (other, ana)] {
        sqlx::query(
            "INSERT INTO nodos (id, nombre, token_acceso, creador_id) VALUES ($1, 'Agenda', $2, $3)",
        )
        .bind(id)
        .bind(id.to_string()[..32].to_string())
        .bind(creator)
        .execute(&pool)
        .await
        .unwrap();
    }
    for (n, u, rol) in [
        (node, owner, "OWNER"),
        (node, ana, "MEMBER"),
        (node, beto, "MEMBER"),
        (other, ana, "OWNER"),
        (other, outsider, "MEMBER"),
    ] {
        sqlx::query("INSERT INTO nodo_miembros (nodo_id, user_id, rol) VALUES ($1, $2, $3)")
            .bind(n)
            .bind(u)
            .bind(rol)
            .execute(&pool)
            .await
            .unwrap();
    }
    let create = |who: Uuid, nodo: Uuid, payload: Value| {
        let state = state.clone();
        async move {
            body(
                reuniones::create_reunion(
                    State(state),
                    Extension(auth(who)),
                    Path(nodo),
                    Json(dto(payload)),
                )
                .await,
            )
        }
    };
    let update = |who: Uuid, id: Uuid, payload: Value| {
        let state = state.clone();
        async move {
            body(
                reuniones::update_reunion(
                    State(state),
                    Extension(auth(who)),
                    Path((node, id)),
                    Json(dto(payload)),
                )
                .await,
            )
        }
    };
    let at = |d: u32, h: u32, m: u32| Utc.with_ymd_and_hms(2030, 1, d, h, m, 0).unwrap();
    let date = |v: &Value| v.as_str().unwrap().parse::<DateTime<Utc>>().unwrap();
    let uid = |v: &Value| Uuid::parse_str(v.as_str().unwrap()).unwrap();

    // 1. Todo el día (UTC−6) con ubicación: de medianoche a medianoche local.
    let (status, all_day) = create(
        owner,
        node,
        json!({
            "titulo": "Feria", "fecha_inicio": Utc.with_ymd_and_hms(2030, 2, 5, 20, 0, 0).unwrap(),
            "todo_el_dia": true, "zona_minutos": -360, "ubicacion": "  Auditorio  "
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{all_day}");
    assert_eq!(all_day["reunion"]["todo_el_dia"], true);
    assert_eq!(all_day["reunion"]["ubicacion"], "Auditorio");
    assert_eq!(
        date(&all_day["reunion"]["fecha_inicio"]),
        Utc.with_ymd_and_hms(2030, 2, 5, 6, 0, 0).unwrap()
    );
    assert_eq!(
        date(&all_day["reunion"]["fecha_fin"]),
        Utc.with_ymd_and_hms(2030, 2, 6, 6, 0, 0).unwrap()
    );
    assert_eq!(
        all_day["reunion"]["rtc_estado"], "scheduled",
        "no se inicia sola"
    );
    assert_eq!(
        create(
            owner,
            node,
            json!({"titulo": "X", "fecha_inicio": at(7, 15, 0), "ubicacion": "x".repeat(201)})
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    // El calendario también lleva los campos nuevos.
    let events = body(
        crate::calendar::list(
            State(state.clone()),
            Extension(auth(owner)),
            Query(dto(json!({
                "from": Utc.with_ymd_and_hms(2030, 2, 1, 0, 0, 0).unwrap(),
                "to": Utc.with_ymd_and_hms(2030, 3, 1, 0, 0, 0).unwrap(),
                "node_id": node
            }))),
        )
        .await,
    )
    .1;
    let feria = &events["reuniones"][0];
    assert_eq!(feria["todo_el_dia"], true);
    assert_eq!(feria["ubicacion"], "Auditorio");
    assert_eq!(
        feria["asistentes"].as_array().unwrap().len(),
        2,
        "Ana y Beto"
    );

    // 2. Serie semanal de 4 con Ana: la 1.ª ya se celebró y la 2.ª está en curso.
    let (status, created) = create(
        owner,
        node,
        json!({
            "titulo": "Daily", "fecha_inicio": at(7, 15, 0), "fecha_fin": at(7, 15, 45),
            "repeticion": {"frecuencia": "weekly", "ocurrencias": 4},
            "invitados": [ana], "zona_minutos": -360
        }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    let series: Vec<Uuid> = sqlx::query_scalar(
        "SELECT id FROM reuniones WHERE serie_id = (SELECT serie_id FROM reuniones WHERE id = $1) ORDER BY fecha_inicio",
    )
    .bind(uid(&created["reunion"]["id"]))
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(series.len(), 4);
    for (id, estado) in [(series[0], "ended"), (series[1], "active")] {
        sqlx::query("UPDATE reuniones SET rtc_estado = $2 WHERE id = $1")
            .bind(id)
            .bind(estado)
            .execute(&pool)
            .await
            .unwrap();
    }
    type Row = (String, DateTime<Utc>, Option<DateTime<Utc>>, Option<String>);
    let rows = || async {
        let mut out: Vec<Row> = Vec::new();
        for id in &series {
            out.push(
                sqlx::query_as(
                    "SELECT titulo, fecha_inicio, fecha_fin, ubicacion FROM reuniones WHERE id = $1",
                )
                .bind(id)
                .fetch_one(&pool)
                .await
                .unwrap(),
            );
        }
        out
    };

    // Permisos: Beto no organiza ni administra; un alcance desconocido falla.
    assert_eq!(
        update(beto, series[2], json!({"titulo": "Mío"})).await.0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        update(owner, series[2], json!({"titulo": "X", "alcance": "todas"}))
            .await
            .0,
        StatusCode::BAD_REQUEST
    );

    // «Solo esta».
    let (status, one) = update(
        owner,
        series[2],
        json!({"titulo": "Solo esta", "alcance": "una"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{one}");
    assert_eq!(one["ocurrencias"], 1);
    let r = rows().await;
    assert_eq!(
        r.iter().map(|x| x.0.as_str()).collect::<Vec<_>>(),
        ["Daily", "Daily", "Solo esta", "Daily"]
    );

    // «Esta y las siguientes»: +1 h y 15 min más de duración, desde la 3.ª.
    let (status, next) = update(
        owner,
        series[2],
        json!({
            "fecha_inicio": at(21, 16, 0), "fecha_fin": at(21, 17, 0),
            "alcance": "siguientes", "zona_minutos": -360
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{next}");
    assert_eq!(next["ocurrencias"], 2);
    let r = rows().await;
    assert_eq!(r[0].1, at(7, 15, 0), "celebrada intacta");
    assert_eq!(r[1].1, at(14, 15, 0), "en curso intacta");
    assert_eq!(r[1].2, Some(at(14, 15, 45)));
    assert_eq!((r[2].1, r[2].2), (at(21, 16, 0), Some(at(21, 17, 0))));
    assert_eq!((r[3].1, r[3].2), (at(28, 16, 0), Some(at(28, 17, 0))));

    // «Toda la serie» desde la última: ubicación e invitados (Beto en lugar de
    // Ana); las reuniones celebradas o en curso no cambian.
    let (status, all) = update(
        owner,
        series[3],
        json!({"ubicacion": "Sala 3", "invitados": [beto], "alcance": "serie"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{all}");
    assert_eq!(all["ocurrencias"], 2);
    assert_eq!(all["reunion"]["asistentes"], json!([beto]));
    let r = rows().await;
    assert_eq!(
        r.iter().map(|x| x.3.as_deref()).collect::<Vec<_>>(),
        [None, None, Some("Sala 3"), Some("Sala 3")]
    );
    let invited = |id: Uuid, who: Uuid| {
        let pool = pool.clone();
        async move {
            sqlx::query_scalar::<_, String>(
                "SELECT respuesta FROM reunion_invitados WHERE reunion_id = $1 AND user_id = $2",
            )
            .bind(id)
            .bind(who)
            .fetch_optional(&pool)
            .await
            .unwrap()
        }
    };
    assert_eq!(invited(series[0], ana).await.as_deref(), Some("pendiente"));
    assert_eq!(invited(series[2], ana).await, None);
    assert_eq!(invited(series[3], beto).await.as_deref(), Some("pendiente"));
    assert_eq!(invited(series[1], beto).await, None);
    assert_eq!(
        invited(series[2], owner).await.as_deref(),
        Some("aceptada"),
        "el organizador sigue"
    );
    let notices: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM notificaciones WHERE tipo = 'invitacion' AND user_id = $1",
    )
    .bind(beto)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(notices, 2, "Feria y la serie");
    // Borrar la ubicación con texto vacío; invitar a alguien ajeno falla.
    let (_, cleared) = update(owner, series[3], json!({"ubicacion": ""})).await;
    assert!(cleared["reunion"]["ubicacion"].is_null());
    assert_eq!(
        update(owner, series[3], json!({"invitados": [outsider]}))
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
    // Una reunión en curso no se cambia con «toda la serie».
    let (status, _) = update(owner, series[1], json!({"titulo": "Z", "alcance": "serie"})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(rows().await[1].0, "Daily");

    // 3. Disponibilidad: Ana organiza «Secreto» en otro nodo y rechazó
    // «Planning»; Beto está invitado a «Planning» y a «Revisión».
    let (_, secret) = create(
        ana,
        other,
        json!({"titulo": "Secreto", "fecha_inicio": at(10, 18, 0), "fecha_fin": at(10, 19, 0), "invitados": []}),
    )
    .await;
    assert_eq!(secret["reunion"]["titulo"], "Secreto");
    let (_, planning) = create(
        owner,
        node,
        json!({"titulo": "Planning", "fecha_inicio": at(11, 14, 0), "fecha_fin": at(11, 15, 0), "invitados": [ana, beto]}),
    )
    .await;
    let planning_id = uid(&planning["reunion"]["id"]);
    create(
        owner,
        node,
        json!({"titulo": "Revisión", "fecha_inicio": at(11, 14, 30), "fecha_fin": at(11, 16, 0), "invitados": [beto]}),
    )
    .await;
    assert_eq!(
        body(
            reuniones::respond(
                State(state.clone()),
                Extension(auth(ana)),
                Path((node, planning_id)),
                Json(dto(json!({"respuesta": "rechazada"}))),
            )
            .await
        )
        .0,
        StatusCode::OK
    );
    let availability = |who: Uuid,
                        users: Vec<Uuid>,
                        desde: DateTime<Utc>,
                        hasta: DateTime<Utc>,
                        excluir: Option<Uuid>| {
        let state = state.clone();
        let usuarios = users
            .iter()
            .map(Uuid::to_string)
            .collect::<Vec<_>>()
            .join(",");
        async move {
            body(
                reuniones::availability(
                    State(state),
                    Extension(auth(who)),
                    Path(node),
                    Query(dto(json!({
                        "desde": desde, "hasta": hasta, "usuarios": usuarios, "excluir": excluir
                    }))),
                )
                .await,
            )
        }
    };
    let (status, busy) =
        availability(owner, vec![ana, beto], at(10, 0, 0), at(12, 0, 0), None).await;
    assert_eq!(status, StatusCode::OK, "{busy}");
    let text = busy.to_string();
    assert!(
        !text.contains("Secreto") && !text.contains("titulo"),
        "{text}"
    );
    assert_eq!(busy["usuarios"][0]["user_id"], ana.to_string());
    assert_eq!(
        busy["usuarios"][0]["ocupado"],
        json!([{"inicio": at(10, 18, 0), "fin": at(10, 19, 0)}]),
        "Ana: solo el intervalo de otro nodo; rechazó Planning"
    );
    assert_eq!(
        busy["usuarios"][1]["ocupado"],
        json!([{"inicio": at(11, 14, 0), "fin": at(11, 16, 0)}]),
        "Beto: Planning y Revisión unidos"
    );
    // Un evento de todo el día del nodo no ocupa a nadie.
    create(
        owner,
        node,
        json!({"titulo": "Entrega", "invitados": [beto], "todo_el_dia": true, "zona_minutos": -360,
               "fecha_inicio": at(11, 6, 0), "fecha_fin": at(12, 6, 0)}),
    )
    .await;
    let (_, with_all_day) = availability(owner, vec![beto], at(10, 0, 0), at(12, 0, 0), None).await;
    assert_eq!(
        with_all_day["usuarios"][0]["ocupado"],
        busy["usuarios"][1]["ocupado"]
    );
    // Al editar Planning, su propio horario no cuenta como choque.
    let (_, editing) = availability(
        owner,
        vec![beto],
        at(10, 0, 0),
        at(12, 0, 0),
        Some(planning_id),
    )
    .await;
    assert_eq!(
        editing["usuarios"][0]["ocupado"],
        json!([{"inicio": at(11, 14, 30), "fin": at(11, 16, 0)}])
    );
    // Solo personas que comparten el nodo, y como máximo 14 días.
    assert_eq!(
        availability(owner, vec![outsider], at(10, 0, 0), at(12, 0, 0), None)
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        availability(outsider, vec![ana], at(10, 0, 0), at(12, 0, 0), None)
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        availability(
            owner,
            vec![ana],
            at(1, 0, 0),
            at(1, 0, 0) + Duration::days(15),
            None
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );

    for id in [node, other] {
        sqlx::query("DELETE FROM nodos WHERE id = $1")
            .bind(id)
            .execute(&pool)
            .await
            .unwrap();
    }
    sqlx::query("DELETE FROM users WHERE email LIKE $1")
        .bind(format!("%{tag}%"))
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

/// QA: si el correo no sale, la verificación y la recuperación lo dicen y
/// no dejan tokens vivos (el `setup` usa un SMTP inalcanzable).
#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn mail_failures_are_reported() {
    use crate::auth::verification;
    let (pool, state) = setup().await;
    let (working, inbox) = with_working_smtp(&state).await;
    let tag = Uuid::new_v4().simple().to_string();
    let unsent = "No pudimos enviar el correo. Inténtalo de nuevo en unos minutos.";
    let tokens = |id: Uuid, method: &'static str| {
        let pool = pool.clone();
        async move {
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM verification_tokens WHERE user_id = $1 AND method = $2",
            )
            .bind(id)
            .bind(method)
            .fetch_one(&pool)
            .await
            .unwrap()
        }
    };
    let request = |state: AppState, email: String, method: &'static str| async move {
        response_body(
            verification::request_verification(
                State(state),
                Json(dto(json!({"email": email, "method": method}))),
            )
            .await,
        )
        .await
    };

    // 1. Verificación: 503 con mensaje claro y sin token, por código o enlace.
    let email = format!("pend.{tag}@example.invalid");
    let pending = user(&pool, &email, "PENDING", "Secreta1!").await;
    for method in ["code", "link"] {
        let (status, json) = request(state.clone(), email.clone(), method).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{method}: {json}");
        assert_eq!(json["success"], false);
        assert_eq!(json["message"], unsent);
        assert_eq!(tokens(pending, method).await, 0, "{method}: token borrado");
    }
    // Con el correo funcionando sí se envía, a la dirección registrada aunque
    // la solicitud traiga espacios o mayúsculas.
    let (status, json) = request(
        working.clone(),
        format!("  {}  ", email.to_uppercase()),
        "code",
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{json}");
    assert_eq!(tokens(pending, "code").await, 1);
    assert_eq!(*inbox.lock().unwrap(), vec![email.clone()]);

    // 2. Recuperación: con el correo funcionando, una dirección desconocida
    // recibe la respuesta genérica y no se le escribe.
    let forgot = |state: AppState, email: String| async move {
        response_body(
            verification::forgot_password(State(state), Json(dto(json!({"email": email})))).await,
        )
        .await
    };
    let (status, generic) = forgot(working.clone(), format!("nadie.{tag}@example.invalid")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(generic["success"], true);
    assert!(
        !inbox
            .lock()
            .unwrap()
            .iter()
            .any(|to| to.starts_with("nadie.")),
        "a una dirección desconocida no se le envía nada"
    );
    // Si la cuenta existe y el envío falla, se informa y el código anterior sigue valiendo.
    let active_email = format!("act.{tag}@example.invalid");
    let active = user(&pool, &active_email, "ACTIVE", "Secreta1!").await;
    sqlx::query("INSERT INTO verification_tokens (user_id, code, method, expires_at) VALUES ($1, '111111', 'reset_code', NOW() + INTERVAL '15 minutes')")
        .bind(active)
        .execute(&pool)
        .await
        .unwrap();
    let alive_codes = || {
        let pool = pool.clone();
        async move {
            sqlx::query_scalar::<_, String>("SELECT code FROM verification_tokens WHERE user_id = $1 AND method = 'reset_code' AND expires_at > NOW()")
                .bind(active)
                .fetch_all(&pool)
                .await
                .unwrap()
        }
    };
    let (status, json) = forgot(state.clone(), active_email.clone()).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{json}");
    assert_eq!(json["message"], unsent);
    // Con el SMTP caído, una dirección desconocida recibe exactamente lo mismo:
    // la respuesta no delata qué cuentas existen.
    assert_eq!(
        forgot(state.clone(), format!("otro.{tag}@example.invalid")).await,
        (status, json.clone())
    );
    assert_eq!(alive_codes().await, vec!["111111".to_string()]);
    assert_eq!(tokens(active, "reset_code").await, 1, "sin código nuevo");
    // Enviado de verdad: respuesta genérica y solo vale el código nuevo.
    let (status, json) = forgot(working.clone(), active_email.clone()).await;
    assert_eq!((status, &json), (StatusCode::OK, &generic));
    let alive = alive_codes().await;
    assert_eq!(alive.len(), 1);
    assert_ne!(alive[0], "111111");
    assert_eq!(inbox.lock().unwrap().last(), Some(&active_email));

    sqlx::query("DELETE FROM users WHERE email LIKE $1")
        .bind(format!("%{tag}%"))
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

/// QA: cerrar sesión invalida los accesos emitidos aunque ocurra en el mismo
/// segundo de la emisión (antes `iat` y la marca de corte se comparaban en
/// segundos). Ahora el JWT lleva la versión de sesión del usuario.
#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn session_version_revokes_access_tokens() {
    use crate::auth::{self, service, session, verification};
    use axum::{Router, middleware, routing::get};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let (pool, state) = setup().await;
    let tag = Uuid::new_v4().simple().to_string();
    let email = format!("ses.{tag}@example.invalid");
    let id = user(&pool, &email, "ACTIVE", "Secreta1!").await;
    let secret = state.config.jwt_secret.clone();
    let app = Router::new()
        .route("/yo", get(|| async { "ok" }))
        .layer(middleware::from_fn(auth::middleware::jwt_auth))
        .layer(Extension(pool.clone()))
        .layer(Extension(state.config.clone()));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let request = |token: String| async move {
        let mut stream = tokio::net::TcpStream::connect(address).await.unwrap();
        let raw = format!(
            "GET /yo HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer {token}\r\nConnection: close\r\n\r\n"
        );
        stream.write_all(raw.as_bytes()).await.unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).await.unwrap();
        response
    };
    let rejected = |response: String| {
        response.starts_with("HTTP/1.1 401") && response.contains("invalid_access_token")
    };
    let logout = |token: Uuid| {
        let state = state.clone();
        async move {
            session::logout(
                State(state),
                Json(dto(json!({"refresh_token": token.to_string()}))),
            )
            .await
        }
    };
    let refresh = |token: Uuid| {
        let state = state.clone();
        async move {
            body(
                session::refresh(
                    State(state),
                    Json(dto(json!({"refresh_token": token.to_string()}))),
                )
                .await,
            )
        }
    };
    let iat = |token: &str| {
        auth::jwt::validate_token(token, &secret)
            .unwrap()
            .claims
            .iat as i64
    };

    // 1. Emisión y cierre de sesión en el mismo segundo: el acceso deja de valer.
    let ms = chrono::Utc::now().timestamp_subsec_millis().min(999);
    tokio::time::sleep(std::time::Duration::from_millis(u64::from(1005 - ms))).await;
    let (access, closed_refresh) = session::issue_pair(&pool, &secret, id, "MEMBER")
        .await
        .unwrap();
    assert_eq!(logout(closed_refresh).await, StatusCode::NO_CONTENT);
    // 2. Un inicio de sesión inmediatamente posterior (mismo segundo) sí vale.
    let (relogin, relogin_refresh) = session::issue_pair(&pool, &secret, id, "MEMBER")
        .await
        .unwrap();
    assert_eq!(
        iat(&access),
        chrono::Utc::now().timestamp(),
        "mismo segundo"
    );
    assert_eq!(iat(&relogin), iat(&access));
    assert!(
        rejected(request(access).await),
        "cerrado en el mismo segundo"
    );
    assert!(request(relogin.clone()).await.ends_with("ok"));
    // 3. El refresh de la sesión cerrada ya no renueva.
    assert_eq!(refresh(closed_refresh).await.0, StatusCode::UNAUTHORIZED);

    // 4. Varias sesiones (semántica actual): cerrar una invalida los accesos de
    // todas, pero las demás renuevan con su propio refresh y siguen.
    let (other, other_refresh) = session::issue_pair(&pool, &secret, id, "MEMBER")
        .await
        .unwrap();
    assert!(request(other.clone()).await.ends_with("ok"));
    assert_eq!(logout(relogin_refresh).await, StatusCode::NO_CONTENT);
    assert!(rejected(request(relogin).await));
    assert!(rejected(request(other).await));
    assert_eq!(refresh(relogin_refresh).await.0, StatusCode::UNAUTHORIZED);
    let (status, renewed) = refresh(other_refresh).await;
    assert_eq!(status, StatusCode::OK, "{renewed}");
    let renewed_access = renewed["access_token"].as_str().unwrap().to_string();
    let renewed_refresh = Uuid::parse_str(renewed["refresh_token"].as_str().unwrap()).unwrap();
    assert!(request(renewed_access.clone()).await.ends_with("ok"));

    // 5. Cambiar la contraseña invalida los accesos y refresh previos; la
    // pareja nueva de este dispositivo vale.
    let (status, changed) = body(
        service::change_user_password(
            State(state.clone()),
            Extension(AuthUser {
                user_id: id,
                role: "MEMBER".into(),
                session_version: 0,
            }),
            Json(dto(
                json!({"current_password": "Secreta1!", "new_password": "Nueva2!clave"}),
            )),
        )
        .await,
    );
    assert_eq!(status, StatusCode::OK, "{changed}");
    assert!(rejected(request(renewed_access).await));
    assert_eq!(refresh(renewed_refresh).await.0, StatusCode::UNAUTHORIZED);
    let changed_access = changed["access_token"].as_str().unwrap().to_string();
    assert!(request(changed_access.clone()).await.ends_with("ok"));

    // 6. Restablecer la contraseña con código también los invalida.
    sqlx::query("INSERT INTO verification_tokens (user_id, code, method, expires_at) VALUES ($1, '222222', 'reset_code', NOW() + INTERVAL '15 minutes')")
        .bind(id)
        .execute(&pool)
        .await
        .unwrap();
    let (status, json) = body(
        verification::reset_password(
            State(state.clone()),
            Json(dto(
                json!({"email": email, "code": "222222", "new_password": "Otra3!clave"}),
            )),
        )
        .await,
    );
    assert_eq!(status, StatusCode::OK, "{json}");
    assert!(rejected(request(changed_access).await));

    // 7. El login emite un acceso con la versión vigente.
    let (status, logged) = body(
        service::login(
            State(state.clone()),
            Json(dto(json!({"email": email, "password": "Otra3!clave"}))),
        )
        .await,
    );
    assert_eq!(status, StatusCode::OK, "{logged}");
    assert!(
        request(logged["access_token"].as_str().unwrap().to_string())
            .await
            .ends_with("ok")
    );

    // 8. Un JWT antiguo, sin la versión, se rechaza limpiamente.
    let now = chrono::Utc::now().timestamp();
    let legacy = jsonwebtoken::encode(
        &jsonwebtoken::Header::default(),
        &json!({"sub": id.to_string(), "role": "MEMBER", "exp": now + 600, "iat": now}),
        &jsonwebtoken::EncodingKey::from_secret(secret.as_bytes()),
    )
    .unwrap();
    assert!(rejected(request(legacy).await), "sin versión de sesión");
    server.abort();

    sqlx::query("DELETE FROM users WHERE email LIKE $1")
        .bind(format!("%{tag}%"))
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

/// QA: el registro valida el formato del correo en el servidor (antes solo
/// exigía una «@») y no inserta nada si es inválido.
#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn register_validates_email_format() {
    use crate::auth::service;
    let (pool, state) = setup().await;
    let tag = Uuid::new_v4().simple().to_string();
    let base = Uuid::new_v4().as_u128() % 1_000_000;
    let register = |email: String, attempt: u128| {
        let state = state.clone();
        // Teléfono único por intento para comprobar que no queda ninguna fila.
        let phone = format!("+5037{:06}{attempt}", base);
        async move {
            let response = body(
                service::register_user(
                    State(state),
                    Json(dto(json!({
                        "name": "Ana Rivas", "email": email, "phone": phone, "password": "Secreta1!"
                    }))),
                )
                .await,
            );
            (response, phone)
        }
    };
    let rows = |phone: String| {
        let pool = pool.clone();
        async move {
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM users WHERE telefono = $1")
                .bind(phone)
                .fetch_one(&pool)
                .await
                .unwrap()
        }
    };

    let invalid = [
        "a@".to_string(),
        "@b.com".to_string(),
        "a@b".to_string(),
        "a b@c.com".to_string(),
        "a@b..com".to_string(),
        "a@.b.com".to_string(),
        "a@b.com.".to_string(),
        "a@b@c.com".to_string(),
        "a@b\u{7}.com".to_string(),
        format!("{}@b.com", "a".repeat(250)),
    ];
    for (attempt, email) in invalid.into_iter().enumerate() {
        let ((status, json), phone) = register(email.clone(), attempt as u128).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{email}: {json}");
        assert_eq!(json["success"], false);
        assert_eq!(
            json["field_errors"]["email"], "Formato de correo electrónico inválido.",
            "{email}: {json}"
        );
        assert_eq!(rows(phone).await, 0, "{email}: sin filas");
    }

    // Válidos: se guardan recortados y en minúsculas, como los busca el login.
    let valid = [
        (
            format!("  Ana.Rivas+{tag}@Sub.Example.COM "),
            format!("ana.rivas+{tag}@sub.example.com"),
        ),
        (format!("x{tag}@b.co"), format!("x{tag}@b.co")),
    ];
    for (attempt, (email, stored)) in valid.into_iter().enumerate() {
        let ((status, json), phone) = register(email.clone(), 10 + attempt as u128).await;
        assert_eq!(status, StatusCode::CREATED, "{email}: {json}");
        let saved: String = sqlx::query_scalar("SELECT email FROM users WHERE telefono = $1")
            .bind(&phone)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(saved, stored);
    }

    sqlx::query("DELETE FROM users WHERE email LIKE $1")
        .bind(format!("%{tag}%"))
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

/// QA: el límite de 3 correos por hora es independiente para verificación
/// (código o enlace) y recuperación (reset_code), y no tiene huecos.
#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn verification_rate_limit_per_purpose() {
    use crate::auth::verification;
    let (pool, state) = setup().await;
    let (working, inbox) = with_working_smtp(&state).await;
    let tag = Uuid::new_v4().simple().to_string();
    let verify = |email: String, method: &'static str| {
        let state = working.clone();
        async move {
            response_body(
                verification::request_verification(
                    State(state),
                    Json(dto(json!({"email": email, "method": method}))),
                )
                .await,
            )
            .await
        }
    };
    let forgot = |email: String| {
        let state = working.clone();
        async move {
            response_body(
                verification::forgot_password(State(state), Json(dto(json!({"email": email}))))
                    .await,
            )
            .await
        }
    };
    let tokens = |id: Uuid, methods: &'static [&'static str]| {
        let pool = pool.clone();
        async move {
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM verification_tokens WHERE user_id = $1 AND method = ANY($2)",
            )
            .bind(id)
            .bind(methods)
            .fetch_one(&pool)
            .await
            .unwrap()
        }
    };
    let delivered = |email: &str| {
        inbox
            .lock()
            .unwrap()
            .iter()
            .filter(|to| *to == email)
            .count()
    };
    const VERIFY: &[&str] = &["code", "link"];
    const RESET: &[&str] = &["reset_code"];

    // 1. Tres recuperaciones no bloquean la verificación; la 4.ª verificación sí.
    let ana = format!("ana.{tag}@example.invalid");
    let ana_id = user(&pool, &ana, "PENDING", "Secreta1!").await;
    for _ in 0..3 {
        assert_eq!(forgot(ana.clone()).await.0, StatusCode::OK);
    }
    for method in ["code", "link", "code"] {
        let (status, json) = verify(ana.clone(), method).await;
        assert_eq!(status, StatusCode::OK, "{method}: {json}");
    }
    let (status, json) = verify(ana.clone(), "link").await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "{json}");
    assert_eq!(delivered(&ana), 6);
    // La verificación no borró los códigos de recuperación (ni los ya
    // reemplazados, que cuentan para su límite): la 4.ª recuperación no sale.
    assert_eq!(tokens(ana_id, RESET).await, 3);
    assert_eq!(forgot(ana.clone()).await.0, StatusCode::OK);
    assert_eq!(tokens(ana_id, RESET).await, 3);
    assert_eq!(delivered(&ana), 6);

    // 2. Y viceversa: tres verificaciones no bloquean la recuperación.
    let beto = format!("beto.{tag}@example.invalid");
    let beto_id = user(&pool, &beto, "PENDING", "Secreta1!").await;
    for _ in 0..3 {
        assert_eq!(verify(beto.clone(), "code").await.0, StatusCode::OK);
    }
    for _ in 0..3 {
        assert_eq!(forgot(beto.clone()).await.0, StatusCode::OK);
    }
    assert_eq!(tokens(beto_id, RESET).await, 3);
    assert_eq!(delivered(&beto), 6);

    // 3. Agotar los intentos de un código no devuelve cupo (antes se borraban
    // los códigos y se podían pedir sin límite para probar más).
    let caro = format!("caro.{tag}@example.invalid");
    let caro_id = user(&pool, &caro, "PENDING", "Secreta1!").await;
    for _ in 0..3 {
        assert_eq!(verify(caro.clone(), "code").await.0, StatusCode::OK);
    }
    for _ in 0..5 {
        let (status, _) = body(
            verification::verify_email(
                State(working.clone()),
                Json(dto(json!({"email": caro, "code": "abcdef"}))),
            )
            .await,
        );
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
    assert_eq!(
        verify(caro.clone(), "code").await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(delivered(&caro), 3);
    assert_eq!(tokens(caro_id, VERIFY).await, 3, "vencidos, no borrados");

    // 4. La limpieza va antes de contar y solo borra lo propio y ya fuera de
    // la ventana: lo vencido de la última hora sigue contando.
    let dani = format!("dani.{tag}@example.invalid");
    let dani_id = user(&pool, &dani, "PENDING", "Secreta1!").await;
    let old = |method: &'static str, created: &'static str, expires: &'static str| {
        let pool = pool.clone();
        async move {
            sqlx::query("INSERT INTO verification_tokens (user_id, code, method, created_at, expires_at) VALUES ($1, '123456', $2, NOW() - $3::text::interval, NOW() - $4::text::interval)")
                .bind(dani_id)
                .bind(method)
                .bind(created)
                .bind(expires)
                .execute(&pool)
                .await
                .unwrap();
        }
    };
    old("code", "2 hours", "105 minutes").await;
    old("reset_code", "2 hours", "105 minutes").await;
    for _ in 0..2 {
        old("code", "40 minutes", "25 minutes").await;
    }
    assert_eq!(verify(dani.clone(), "code").await.0, StatusCode::OK);
    assert_eq!(
        verify(dani.clone(), "code").await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(
        tokens(dani_id, VERIFY).await,
        3,
        "se borró solo el de hace 2 h"
    );
    assert_eq!(
        tokens(dani_id, RESET).await,
        1,
        "la recuperación no se toca"
    );

    // 5. Solicitudes simultáneas no se saltan el límite.
    let eva = format!("eva.{tag}@example.invalid");
    user(&pool, &eva, "PENDING", "Secreta1!").await;
    // Conexiones ya abiertas, para que las solicitudes se solapen de verdad.
    drop(futures_util::future::join_all((0..8).map(|_| pool.acquire())).await);
    let burst: Vec<_> = (0..8).map(|_| verify(eva.clone(), "code")).collect();
    let statuses: Vec<StatusCode> = futures_util::future::join_all(burst)
        .await
        .into_iter()
        .map(|(status, _)| status)
        .collect();
    assert_eq!(
        statuses.iter().filter(|s| **s == StatusCode::OK).count(),
        3,
        "{statuses:?}"
    );
    assert_eq!(delivered(&eva), 3);

    sqlx::query("DELETE FROM users WHERE email LIKE $1")
        .bind(format!("%{tag}%"))
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

fn node_name_cases() -> Vec<(String, bool)> {
    vec![
        ("".into(), false),
        ("   ".into(), false),
        ("\t\n\u{2003}\u{a0}".into(), false),
        ("a".repeat(100), true),
        ("a".repeat(101), false),
        (" \t Nombre recortado \n\u{2003}".into(), true),
        (format!("  {}  ", "a".repeat(100)), true),
        ("á😀".repeat(50), true),
        (format!("{}ñ", "á😀".repeat(50)), false),
        ("ñ".into(), true),
        ("😀".into(), true),
        ("x".repeat(10_000), false),
    ]
}

async fn node_name_fixture() -> (PgPool, AppState, AuthUser, Uuid) {
    let (pool, state) = setup().await;
    let owner = user(
        &pool,
        &format!("nombre.{}@example.invalid", Uuid::new_v4()),
        "ACTIVE",
        "x",
    )
    .await;
    let auth = AuthUser {
        user_id: owner,
        role: "MEMBER".into(),
        session_version: 0,
    };
    let (status, response) = crate::nodos::service::create_nodo(
        State(state.clone()),
        Extension(auth.clone()),
        Json(dto(json!({"nombre": "Original"}))),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    (pool, state, auth, response.0.nodo.unwrap().id)
}

#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn node_names_create_regression() {
    let (pool, state, auth, _) = node_name_fixture().await;
    let mut accepted = 1_i64;
    for (name, valid) in node_name_cases() {
        let (status, response) = crate::nodos::service::create_nodo(
            State(state.clone()),
            Extension(auth.clone()),
            Json(dto(json!({"nombre": name}))),
        )
        .await;
        if valid {
            assert_eq!(status, StatusCode::CREATED);
            assert!(response.0.success);
            let node = response.0.nodo.unwrap();
            assert_eq!(node.nombre, name.trim());
            let stored: String = sqlx::query_scalar("SELECT nombre FROM nodos WHERE id = $1")
                .bind(node.id)
                .fetch_one(&pool)
                .await
                .unwrap();
            assert_eq!(stored, name.trim());
            accepted += 1;
        } else {
            assert_eq!(
                status,
                StatusCode::BAD_REQUEST,
                "longitud: {}",
                name.chars().count()
            );
            assert!(!response.0.success);
            assert_eq!(
                response.0.message,
                if name.trim().is_empty() {
                    "El nombre del nodo no puede estar vacío."
                } else {
                    "El nombre del nodo no puede superar los 100 caracteres."
                }
            );
            assert!(response.0.nodo.is_none());
        }
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM nodos WHERE creador_id = $1")
            .bind(auth.user_id)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, accepted);
        let memberships: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM nodo_miembros WHERE user_id = $1")
                .bind(auth.user_id)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(memberships, accepted);
    }
}

#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn node_names_create_subgrupo_regression() {
    let (pool, state, auth, node) = node_name_fixture().await;
    let mut accepted = 0_i64;
    for (name, valid) in node_name_cases() {
        let (status, response) = crate::nodos::subgrupos::create_subgrupo(
            State(state.clone()),
            Extension(auth.clone()),
            Path(node),
            Json(dto(json!({"nombre": name}))),
        )
        .await;
        if valid {
            assert_eq!(status, StatusCode::CREATED);
            assert!(response.0.success);
            let sub = response.0.subgrupo.unwrap();
            assert_eq!(sub.nombre, name.trim());
            let stored: String = sqlx::query_scalar("SELECT nombre FROM subgrupos WHERE id = $1")
                .bind(sub.id)
                .fetch_one(&pool)
                .await
                .unwrap();
            assert_eq!(stored, name.trim());
            accepted += 1;
        } else {
            assert_eq!(
                status,
                StatusCode::BAD_REQUEST,
                "longitud: {}",
                name.chars().count()
            );
            assert!(!response.0.success);
            assert_eq!(
                response.0.message,
                if name.trim().is_empty() {
                    "El nombre del subgrupo no puede estar vacío."
                } else {
                    "El nombre del subgrupo no puede superar los 100 caracteres."
                }
            );
            assert!(response.0.subgrupo.is_none());
        }
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM subgrupos WHERE nodo_id = $1")
            .bind(node)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, accepted);
        let memberships: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM subgrupo_miembros WHERE user_id = $1")
                .bind(auth.user_id)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(memberships, accepted);
    }
}

#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn node_names_rename_subgrupo_regression() {
    let (pool, state, auth, node) = node_name_fixture().await;
    let (status, response) = crate::nodos::subgrupos::create_subgrupo(
        State(state.clone()),
        Extension(auth.clone()),
        Path(node),
        Json(dto(
            json!({"nombre": "Original", "descripcion": "Sin cambios"}),
        )),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let sub = response.0.subgrupo.unwrap().id;
    let mut expected_name = "Original".to_string();
    for (name, valid) in node_name_cases() {
        let (status, response) = crate::nodos::subgrupos::update_subgrupo(
            State(state.clone()),
            Extension(auth.clone()),
            Path((node, sub)),
            Json(dto(json!({"nombre": name, "descripcion": "Sin cambios"}))),
        )
        .await;
        if valid {
            assert_eq!(status, StatusCode::OK);
            assert!(response.0.success);
            expected_name = name.trim().to_string();
            assert_eq!(response.0.subgrupo.unwrap().nombre, expected_name);
        } else {
            assert_eq!(
                status,
                StatusCode::BAD_REQUEST,
                "longitud: {}",
                name.chars().count()
            );
            assert!(!response.0.success);
            assert_eq!(
                response.0.message,
                if name.trim().is_empty() {
                    "El nombre del subgrupo no puede estar vacío."
                } else {
                    "El nombre del subgrupo no puede superar los 100 caracteres."
                }
            );
            assert!(response.0.subgrupo.is_none());
        }
        let stored: String = sqlx::query_scalar("SELECT nombre FROM subgrupos WHERE id = $1")
            .bind(sub)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(stored, expected_name);
    }
    // Omitir el nombre o enviar null conserva el nombre actual.
    for payload in [json!({"descripcion": " Nueva "}), json!({"nombre": null})] {
        let (status, response) = crate::nodos::subgrupos::update_subgrupo(
            State(state.clone()),
            Extension(auth.clone()),
            Path((node, sub)),
            Json(dto(payload)),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let info = response.0.subgrupo.unwrap();
        assert_eq!(info.nombre, expected_name);
        assert_eq!(info.descripcion.as_deref(), Some("Nueva"));
    }
    // Una petición inválida concurrente no debe sobrescribir ningún campo.
    let update = |payload| {
        crate::nodos::subgrupos::update_subgrupo(
            State(state.clone()),
            Extension(auth.clone()),
            Path((node, sub)),
            Json(dto(payload)),
        )
    };
    let (valid, invalid) = tokio::join!(
        update(json!({"nombre": "  Concurrente  "})),
        update(json!({"nombre": " ", "descripcion": "No guardar"})),
    );
    assert_eq!(valid.0, StatusCode::OK);
    assert_eq!(invalid.0, StatusCode::BAD_REQUEST);
    let stored: (String, Option<String>) =
        sqlx::query_as("SELECT nombre, descripcion FROM subgrupos WHERE id = $1")
            .bind(sub)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(stored, ("Concurrente".into(), Some("Nueva".into())));
}

/// Riesgo: con el SMTP caído, los envíos fallidos no cuentan para el límite
/// por hora; el tope por dirección corta los reintentos (con `Retry-After`),
/// igual para una dirección registrada que para una desconocida.
#[tokio::test]
#[ignore = "requires IRONLINK_TEST_DATABASE_URL"]
async fn failed_mail_sends_are_capped_per_address() {
    let (pool, state) = setup().await;
    let tag = Uuid::new_v4().simple().to_string();
    let call = |state: AppState, path: &'static str, email: String| async move {
        match path {
            "verify" => {
                crate::auth::verification::request_verification(
                    State(state),
                    Json(dto(json!({"email": email, "method": "code"}))),
                )
                .await
            }
            _ => {
                crate::auth::verification::forgot_password(
                    State(state),
                    Json(dto(json!({"email": email}))),
                )
                .await
            }
        }
    };
    let pending = format!("tope.{tag}@example.invalid");
    user(&pool, &pending, "PENDING", "Secreta1!").await;
    let unknown = format!("tope.nadie.{tag}@example.invalid");
    for (path, email) in [("verify", pending.clone()), ("forgot", unknown.clone())] {
        for i in 0..5 {
            let response = call(state.clone(), path, email.clone()).await;
            assert_eq!(
                response.status(),
                StatusCode::SERVICE_UNAVAILABLE,
                "{path} #{i}"
            );
        }
        let blocked = call(state.clone(), path, email.clone()).await;
        assert_eq!(blocked.status(), StatusCode::TOO_MANY_REQUESTS, "{path}");
        let retry: u64 = blocked.headers()[axum::http::header::RETRY_AFTER]
            .to_str()
            .unwrap()
            .parse()
            .unwrap();
        assert!((1..=900).contains(&retry), "{path}: Retry-After {retry}");
        let (_, json) = response_body(blocked).await;
        assert_eq!(json["success"], false);
    }
    // Mayúsculas o espacios no esquivan el tope.
    let disguised = call(
        state.clone(),
        "forgot",
        format!("  {}  ", unknown.to_uppercase()),
    )
    .await;
    assert_eq!(disguised.status(), StatusCode::TOO_MANY_REQUESTS);
    // Otra dirección no queda afectada.
    let other = call(
        state.clone(),
        "forgot",
        format!("otra.{tag}@example.invalid"),
    )
    .await;
    assert_eq!(other.status(), StatusCode::SERVICE_UNAVAILABLE);

    sqlx::query("DELETE FROM users WHERE email LIKE $1")
        .bind(format!("%{tag}%"))
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

/// Riesgo: tope por IP en las rutas que envían correo, con la IP real de la
/// conexión (servidor con `ConnectInfo`, como en main.rs).
#[tokio::test]
async fn mail_routes_are_capped_per_ip() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let app = axum::Router::new()
        .route("/forgot-password", axum::routing::post(|| async { "ok" }))
        .route_layer(axum::middleware::from_fn(
            crate::auth::mail_guard::limit_by_ip,
        ));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
        )
        .await
        .unwrap();
    });
    let post = || async move {
        let mut socket = tokio::net::TcpStream::connect(address).await.unwrap();
        socket
            .write_all(
                b"POST /forgot-password HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )
            .await
            .unwrap();
        let mut reply = String::new();
        socket.read_to_string(&mut reply).await.unwrap();
        reply
    };
    for i in 0..10 {
        let reply = post().await;
        assert!(reply.starts_with("HTTP/1.1 200"), "#{i}: {reply}");
    }
    let reply = post().await.to_lowercase();
    assert!(reply.starts_with("http/1.1 429"), "{reply}");
    assert!(reply.contains("retry-after: "), "{reply}");
}

/// Correo de bienvenida: sale una sola vez, cuando una verificación (por
/// código o por enlace) activa la cuenta, con el diseño y sus imágenes; si el
/// SMTP falla, la verificación responde igual.
#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn welcome_email_once_on_activation() {
    use crate::auth::verification;
    let (pool, state) = setup().await;
    let (working, inbox, messages) = with_recording_smtp(&state).await;
    let mut config = (*working.config).clone();
    config.app_public_url = Some("https://app.example".into());
    let working = AppState {
        config: Arc::new(config),
        ..working
    };
    let tag = Uuid::new_v4().simple().to_string();
    let token = |user: Uuid, method: &'static str, code: &'static str, link: Option<String>| {
        let pool = pool.clone();
        async move {
            sqlx::query("INSERT INTO verification_tokens (user_id, code, token, method, expires_at) VALUES ($1, $2, $3, $4, NOW() + INTERVAL '15 minutes')")
                .bind(user).bind(code).bind(link).bind(method).execute(&pool).await.unwrap();
        }
    };
    let welcomes = |to: String| {
        let (inbox, messages) = (inbox.clone(), messages.clone());
        async move {
            // El envío va en segundo plano: se espera un momento.
            tokio::time::sleep(std::time::Duration::from_millis(400)).await;
            let inbox = inbox.lock().unwrap();
            let messages = messages.lock().unwrap();
            inbox
                .iter()
                .zip(messages.iter())
                .filter(|(rcpt, data)| {
                    **rcpt == to && data.contains("Subject: Bienvenido a IronLink")
                })
                .map(|(_, data)| data.clone())
                .collect::<Vec<_>>()
        }
    };

    // 1. Por código: una bienvenida, con el HTML, el texto plano y las imágenes.
    let ana = format!("ana.{tag}@example.invalid");
    let ana_id = user(&pool, &ana, "PENDING", "Secreta1!").await;
    token(ana_id, "code", "246810", None).await;
    let verify = |state: AppState, email: String, code: &'static str| async move {
        body(
            verification::verify_email(
                State(state),
                Json(dto(json!({"email": email, "code": code}))),
            )
            .await,
        )
    };
    let (status, json) = verify(working.clone(), ana.clone(), "246810").await;
    assert_eq!(status, StatusCode::OK, "{json}");
    let sent = welcomes(ana.clone()).await;
    assert_eq!(sent.len(), 1);
    let mail = &sent[0];
    assert!(mail.contains("multipart/alternative"));
    assert!(mail.contains("multipart/related"));
    assert!(mail.contains("text/plain"));
    assert!(mail.contains("text/html"));
    for cid in [
        "logo@ironlink",
        "nodes@ironlink",
        "video@ironlink",
        "calendar@ironlink",
    ] {
        assert!(mail.contains(&format!("Content-ID: <{cid}>")), "{cid}");
    }
    // Un segundo código válido no vuelve a activar ni a dar la bienvenida.
    token(ana_id, "code", "135791", None).await;
    let (status, _) = verify(working.clone(), ana.clone(), "135791").await;
    assert_ne!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(welcomes(ana.clone()).await.len(), 1);

    // 2. Por enlace: también una sola bienvenida.
    let beto = format!("beto.{tag}@example.invalid");
    let beto_id = user(&pool, &beto, "PENDING", "Secreta1!").await;
    let link = format!("{tag}{tag}");
    token(beto_id, "link", "000000", Some(link.clone())).await;
    let (status, json) =
        body(verification::verify_link(State(working.clone()), axum::extract::Path(link)).await);
    assert_eq!(status, StatusCode::OK, "{json}");
    assert_eq!(welcomes(beto.clone()).await.len(), 1);

    // 3. Con el SMTP caído la verificación responde bien y la cuenta queda activa.
    let caro = format!("caro.{tag}@example.invalid");
    let caro_id = user(&pool, &caro, "PENDING", "Secreta1!").await;
    token(caro_id, "code", "975310", None).await;
    let (status, json) = verify(state.clone(), caro.clone(), "975310").await;
    assert_eq!(status, StatusCode::OK, "{json}");
    let estado: String = sqlx::query_scalar("SELECT estado::TEXT FROM users WHERE id = $1")
        .bind(caro_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(estado, "ACTIVE");

    sqlx::query("DELETE FROM users WHERE email LIKE $1")
        .bind(format!("%{tag}%"))
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

/// Los correos de código citan la vigencia real del token y llevan sus
/// imágenes embebidas.
#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn code_email_matches_token_lifetime() {
    use crate::auth::verification;
    let (pool, state) = setup().await;
    let (working, _, messages) = with_recording_smtp(&state).await;
    let tag = Uuid::new_v4().simple().to_string();
    let email = format!("vida.{tag}@example.invalid");
    let id = user(&pool, &email, "PENDING", "Secreta1!").await;
    let (status, json) = response_body(
        verification::request_verification(
            State(working),
            Json(dto(json!({"email": email, "method": "code"}))),
        )
        .await,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{json}");
    let minutes: f64 = sqlx::query_scalar(
        "SELECT (EXTRACT(EPOCH FROM expires_at - created_at) / 60)::float8 FROM verification_tokens WHERE user_id = $1",
    )
    .bind(id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(minutes.round(), 15.0);
    let mail = messages.lock().unwrap().last().cloned().unwrap();
    // El asunto lleva el código (codificado por ser UTF-8); su contenido lo
    // comprueban las pruebas de plantillas.
    assert!(mail.contains("Subject: "));
    assert!(mail.contains("Content-ID: <clock@ironlink>"));
    assert!(mail.contains("Content-ID: <shield@ironlink>"));

    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}

/// Revisión de código del 5 de octubre de 2026: verificar el correo no
/// levanta una suspensión y un código solo se puede usar una vez.
#[tokio::test]
#[ignore = "Requires disposable IRONLINK_TEST_DATABASE_URL"]
async fn verification_respects_suspension_and_single_use_codes() {
    use crate::auth::verification;
    let (pool, state) = setup().await;
    let (working, inbox) = with_working_smtp(&state).await;
    let tag = Uuid::new_v4().simple().to_string();
    let estado = |id: Uuid| {
        let pool = pool.clone();
        async move {
            sqlx::query_scalar::<_, String>("SELECT estado::TEXT FROM users WHERE id = $1")
                .bind(id)
                .fetch_one(&pool)
                .await
                .unwrap()
        }
    };

    // 1. Una cuenta suspendida no puede pedir un código de verificación.
    let susp = format!("susp.{tag}@example.invalid");
    let susp_id = user(&pool, &susp, "SUSPENDED", "Secreta1!").await;
    let (status, json) = response_body(
        verification::request_verification(
            State(working.clone()),
            Json(dto(json!({"email": susp, "method": "code"}))),
        )
        .await,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{json}");
    assert!(!inbox.lock().unwrap().iter().any(|to| to == &susp));

    // 2. Ni un código ni un enlace emitidos antes de suspenderla la reactivan.
    sqlx::query("INSERT INTO verification_tokens (user_id, code, method, expires_at) VALUES ($1, '111111', 'code', NOW() + INTERVAL '15 minutes')")
        .bind(susp_id)
        .execute(&pool)
        .await
        .unwrap();
    let (status, _) = body(
        verification::verify_email(
            State(working.clone()),
            Json(dto(json!({"email": susp, "code": "111111"}))),
        )
        .await,
    );
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(estado(susp_id).await, "SUSPENDED");
    let link = "ab".repeat(32);
    sqlx::query("INSERT INTO verification_tokens (user_id, code, token, method, expires_at) VALUES ($1, '000000', $2, 'link', NOW() + INTERVAL '15 minutes')")
        .bind(susp_id)
        .bind(&link)
        .execute(&pool)
        .await
        .unwrap();
    let (status, _) =
        body(verification::verify_link(State(working.clone()), axum::extract::Path(link)).await);
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(estado(susp_id).await, "SUSPENDED");

    // 3. Una cuenta pendiente sigue activándose con su código.
    let pend = format!("pend.{tag}@example.invalid");
    let pend_id = user(&pool, &pend, "PENDING", "Secreta1!").await;
    sqlx::query("INSERT INTO verification_tokens (user_id, code, method, expires_at) VALUES ($1, '333333', 'code', NOW() + INTERVAL '15 minutes')")
        .bind(pend_id)
        .execute(&pool)
        .await
        .unwrap();
    let (status, _) = body(
        verification::verify_email(
            State(working.clone()),
            Json(dto(json!({"email": pend, "code": "333333"}))),
        )
        .await,
    );
    assert_eq!(status, StatusCode::OK);
    assert_eq!(estado(pend_id).await, "ACTIVE");

    // 4. Dos restablecimientos simultáneos con el mismo código: solo uno
    // cambia la contraseña.
    let act = format!("act.{tag}@example.invalid");
    let act_id = user(&pool, &act, "ACTIVE", "Secreta1!").await;
    sqlx::query("INSERT INTO verification_tokens (user_id, code, method, expires_at) VALUES ($1, '222222', 'reset_code', NOW() + INTERVAL '15 minutes')")
        .bind(act_id)
        .execute(&pool)
        .await
        .unwrap();
    let reset = |password: &'static str| {
        let (state, email) = (working.clone(), act.clone());
        async move {
            body(
                verification::reset_password(
                    State(state),
                    Json(dto(
                        json!({"email": email, "code": "222222", "new_password": password}),
                    )),
                )
                .await,
            )
            .0
        }
    };
    let (first, second) = tokio::join!(reset("Nueva123!"), reset("Otra1234!"));
    let mut statuses = [first, second];
    statuses.sort();
    assert_eq!(statuses, [StatusCode::OK, StatusCode::BAD_REQUEST]);

    sqlx::query("DELETE FROM users WHERE id = ANY($1)")
        .bind(vec![susp_id, pend_id, act_id])
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}
