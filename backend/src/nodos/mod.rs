pub mod reuniones;
pub mod service;
pub mod subgrupos;

fn validate_name<'a>(nombre: &'a str, entidad: &str) -> Result<&'a str, String> {
    let nombre = nombre.trim();
    if nombre.is_empty() {
        return Err(format!("El nombre del {entidad} no puede estar vacío."));
    }
    if nombre.chars().take(101).count() > 100 {
        return Err(format!(
            "El nombre del {entidad} no puede superar los 100 caracteres."
        ));
    }
    Ok(nombre)
}
