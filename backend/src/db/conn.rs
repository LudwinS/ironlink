use sqlx::{Connection, PgConnection, PgPool, postgres::PgPoolOptions};
use std::env;

pub async fn establish_connexion() -> PgPool {
    let database_url = env::var("DATABASE_URL")
        .expect("Fallo por que la variable de entorno DATABASE_URL no esta definida");

    // 1. Asegurar que la base de datos física exista en Postgres
    ensure_database_exists(&database_url).await;

    // 2. Conectar al pool de base de datos final
    PgPoolOptions::new()
        .max_connections(10)
        .connect(&database_url)
        .await
        .expect("error critico: El sistema no pudo conectarse a la base de datos")
}

async fn ensure_database_exists(database_url: &str) {
    // Intentar extraer el nombre de la base de datos y la URL base
    // Ejemplo: postgres://postgres:password@localhost:5432/IronLink
    let last_slash_idx = match database_url.rfind('/') {
        Some(idx) => idx,
        None => return, // Si no hay barra, no podemos determinar la base de datos
    };

    let base_url = &database_url[..last_slash_idx + 1];
    let db_name = &database_url[last_slash_idx + 1..];

    // Quitar posibles parámetros de consulta de la URL (ej. ?sslmode=disable)
    let db_name = match db_name.find('?') {
        Some(idx) => &db_name[..idx],
        None => db_name,
    };

    // Construir la URL de conexión a la base de datos del sistema 'postgres'
    let postgres_url = format!("{}postgres", base_url);

    println!("Verificando si la base de datos '{}' existe...", db_name);

    // Conectar a la base de datos del sistema 'postgres'
    let mut conn = match PgConnection::connect(&postgres_url).await {
        Ok(c) => c,
        Err(e) => {
            eprintln!(
                "Advertencia: No se pudo conectar a la base de datos 'postgres' para verificar existencia de '{}': {}",
                db_name, e
            );
            return;
        }
    };

    // Comprobar si existe la base de datos en pg_database de forma segura usando bind parameter
    let row: Option<(i32,)> = match sqlx::query_as("SELECT 1 FROM pg_database WHERE datname = $1")
        .bind(db_name)
        .fetch_optional(&mut conn)
        .await
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("Advertencia: Error al consultar pg_database: {}", e);
            return;
        }
    };

    if row.is_none() {
        println!(
            "La base de datos '{}' no existe. Creándola desde cero...",
            db_name
        );
        let create_query = format!("CREATE DATABASE \"{}\"", db_name);

        // Envolver en AssertSqlSafe ya que DDL en postgres no soporta bind parameters para nombres de BD
        if let Err(e) = sqlx::query(sqlx::AssertSqlSafe(create_query.as_str()))
            .execute(&mut conn)
            .await
        {
            eprintln!(
                "Error crítico: No se pudo crear la base de datos '{}': {}",
                db_name, e
            );
        } else {
            println!("Base de datos '{}' creada con éxito.", db_name);
        }
    } else {
        println!(
            "La base de datos '{}' ya existe. Omitiendo creación.",
            db_name
        );
    }
}
