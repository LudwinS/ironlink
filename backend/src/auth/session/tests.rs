use super::*;
use sqlx::postgres::PgPoolOptions;

#[tokio::test]
async fn database_outage_does_not_issue_tokens() {
    let pool = PgPoolOptions::new()
        .connect_lazy("postgres://test:test@127.0.0.1:1/test")
        .unwrap();
    pool.close().await;
    assert_eq!(
        rotate(&pool, "test-secret", Uuid::new_v4())
            .await
            .unwrap_err(),
        StatusCode::SERVICE_UNAVAILABLE
    );
}

#[tokio::test]
#[ignore = "Requires a disposable database in IRONLINK_TEST_DATABASE_URL"]
async fn isolated_rotation_and_revocation_lifecycle() {
    let url = std::env::var("IRONLINK_TEST_DATABASE_URL").expect("isolated database URL required");
    let pool = PgPoolOptions::new()
        .max_connections(4)
        .connect(&url)
        .await
        .unwrap();
    sqlx::raw_sql(sqlx::AssertSqlSafe(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/migrations/001_sprint1_complete.sql"
    ))))
    .execute(&pool)
    .await
    .unwrap();
    sqlx::raw_sql(sqlx::AssertSqlSafe(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/migrations/014_session_cutoff.sql"
    ))))
    .execute(&pool)
    .await
    .unwrap();
    sqlx::raw_sql(sqlx::AssertSqlSafe(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/migrations/019_session_version.sql"
    ))))
    .execute(&pool)
    .await
    .unwrap();
    let id = Uuid::new_v4();
    sqlx::query("INSERT INTO users (id, name, email, password, telefono, estado) VALUES ($1, 'Test', $2, 'old-hash', $3, 'ACTIVE')")
        .bind(id).bind(format!("{id}@example.invalid")).bind(id.to_string()).execute(&pool).await.unwrap();
    let token = Uuid::new_v4();
    sqlx::query("INSERT INTO refresh_tokens (token, user_id, expires_at) VALUES ($1, $2, NOW() + INTERVAL '1 day')")
        .bind(token).bind(id).execute(&pool).await.unwrap();
    let expiry: chrono::DateTime<chrono::Utc> =
        sqlx::query_scalar("SELECT expires_at FROM refresh_tokens WHERE token = $1")
            .bind(token)
            .fetch_one(&pool)
            .await
            .unwrap();

    let (a, b) = tokio::join!(
        rotate(&pool, "test-secret", token),
        rotate(&pool, "test-secret", token)
    );
    assert_eq!(
        usize::from(a.is_ok()) + usize::from(b.is_ok()),
        1,
        "exactly one concurrent rotation must succeed"
    );
    let (access, next) = match (a, b) {
        (Ok(pair), Err(status)) | (Err(status), Ok(pair)) => {
            assert_eq!(status, StatusCode::UNAUTHORIZED);
            pair
        }
        _ => panic!("rotation race"),
    };
    let claims = crate::auth::jwt::validate_token(&access, "test-secret")
        .unwrap()
        .claims;
    assert_eq!(claims.sub, id.to_string());
    assert_eq!(claims.role, "MEMBER");
    assert_eq!(
        rotate(&pool, "test-secret", token).await.unwrap_err(),
        StatusCode::UNAUTHORIZED
    );
    let new_expiry: chrono::DateTime<chrono::Utc> =
        sqlx::query_scalar("SELECT expires_at FROM refresh_tokens WHERE token = $1")
            .bind(next)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(
        expiry, new_expiry,
        "rotation must not extend absolute session expiry"
    );

    sqlx::query("UPDATE users SET estado = 'SUSPENDED' WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        rotate(&pool, "test-secret", next).await.unwrap_err(),
        StatusCode::UNAUTHORIZED
    );
    sqlx::query("UPDATE users SET estado = 'ACTIVE', rol = 'ADMIN' WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .unwrap();
    let (access, next) = rotate(&pool, "test-secret", next).await.unwrap();
    assert_eq!(
        crate::auth::jwt::validate_token(&access, "test-secret")
            .unwrap()
            .claims
            .role,
        "ADMIN"
    );

    update_password(&pool, id, "new-hash").await.unwrap();
    assert_eq!(
        rotate(&pool, "test-secret", next).await.unwrap_err(),
        StatusCode::UNAUTHORIZED
    );
    let hash: String = sqlx::query_scalar("SELECT password FROM users WHERE id = $1")
        .bind(id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(hash, "new-hash");
    sqlx::query("INSERT INTO refresh_tokens (token, user_id, expires_at) VALUES ($1, $2, NOW() - INTERVAL '1 second')")
        .bind(token).bind(id).execute(&pool).await.unwrap();
    assert_eq!(
        rotate(&pool, "test-secret", token).await.unwrap_err(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        rotate(&pool, "test-secret", Uuid::new_v4())
            .await
            .unwrap_err(),
        StatusCode::UNAUTHORIZED
    );
    // Si falla la inserción, el DELETE del token anterior también se revierte.
    sqlx::query("UPDATE refresh_tokens SET expires_at = NOW() + INTERVAL '1 day' WHERE token = $1")
        .bind(token)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::raw_sql(sqlx::AssertSqlSafe("CREATE FUNCTION fail_refresh_insert() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected test failure'; END $$; CREATE TRIGGER fail_refresh_insert BEFORE INSERT ON refresh_tokens FOR EACH ROW EXECUTE FUNCTION fail_refresh_insert();"))
        .execute(&pool).await.unwrap();
    assert_eq!(
        rotate(&pool, "test-secret", token).await.unwrap_err(),
        StatusCode::SERVICE_UNAVAILABLE
    );
    let retained: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM refresh_tokens WHERE token = $1)")
            .bind(token)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(retained);
    sqlx::raw_sql(sqlx::AssertSqlSafe(
        "DROP TRIGGER fail_refresh_insert ON refresh_tokens; DROP FUNCTION fail_refresh_insert();",
    ))
    .execute(&pool)
    .await
    .unwrap();
    let state = AppState {
        pool: pool.clone(),
        config: std::sync::Arc::new(crate::config::AppConfig {
            jwt_secret: "test-secret".into(),
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
    };
    assert_eq!(
        refresh(
            State(state.clone()),
            Json(RefreshRequest {
                refresh_token: "not-a-token".into()
            })
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    for _ in 0..2 {
        assert_eq!(
            logout(
                State(state.clone()),
                Json(RefreshRequest {
                    refresh_token: token.to_string()
                })
            )
            .await,
            StatusCode::NO_CONTENT
        );
    }
    assert_eq!(
        rotate(&pool, "test-secret", token).await.unwrap_err(),
        StatusCode::UNAUTHORIZED
    );
    // La recuperación por código también debe invalidar las renovaciones.
    sqlx::query("INSERT INTO refresh_tokens (token, user_id, expires_at) VALUES ($1, $2, NOW() + INTERVAL '1 day')")
        .bind(token).bind(id).execute(&pool).await.unwrap();
    sqlx::query("INSERT INTO verification_tokens (user_id, code, method, expires_at) VALUES ($1, '123456', 'reset_code', NOW() + INTERVAL '10 minutes')")
        .bind(id).execute(&pool).await.unwrap();
    let (status, body) = crate::auth::verification::reset_password(
        State(state),
        Json(crate::auth::verification::ResetPasswordDto {
            email: format!("{id}@example.invalid"),
            code: "123456".into(),
            new_password: "TestOnly-Strong-Password9!".into(),
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(body.success);
    assert_eq!(
        rotate(&pool, "test-secret", token).await.unwrap_err(),
        StatusCode::UNAUTHORIZED
    );
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(id)
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}
