pub mod templates;

use lettre::message::header::ContentType;
use lettre::message::{Attachment, MultiPart, SinglePart};
use lettre::transport::smtp::authentication::Credentials;
use lettre::{AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor};

use crate::config::AppConfig;
use templates::Email;

pub type SmtpMailer = AsyncSmtpTransport<Tokio1Executor>;

/// Inicializa el transporte SMTP reutilizable a partir de la configuración
pub fn create_mailer(config: &AppConfig) -> Result<SmtpMailer, String> {
    let creds = Credentials::new(config.smtp_username.clone(), config.smtp_password.clone());

    // Conectar a Gmail SMTP con STARTTLS en puerto 587
    let transport = AsyncSmtpTransport::<Tokio1Executor>::starttls_relay("smtp.gmail.com")
        .map_err(|e| format!("Error al configurar transporte SMTP: {}", e))?
        .credentials(creds)
        .port(587)
        .build();
    Ok(transport)
}

/// Bienvenida al quedar verificada la cuenta.
pub async fn send_welcome(
    mailer: &SmtpMailer,
    from_email: &str,
    to: &str,
    name: &str,
    app_url: Option<&str>,
) -> Result<(), String> {
    send(mailer, from_email, to, templates::welcome(name, app_url)).await
}

/// Envía un código de verificación OTP por correo electrónico usando el transporte compartido
pub async fn send_verification_code(
    mailer: &SmtpMailer,
    from_email: &str,
    to: &str,
    code: &str,
    minutes: i64,
) -> Result<(), String> {
    send(
        mailer,
        from_email,
        to,
        templates::verification_code(code, minutes),
    )
    .await
}

/// Envía un código OTP para restablecer la contraseña
pub async fn send_password_reset_code(
    mailer: &SmtpMailer,
    from_email: &str,
    to: &str,
    code: &str,
    minutes: i64,
) -> Result<(), String> {
    send(
        mailer,
        from_email,
        to,
        templates::password_reset(code, minutes),
    )
    .await
}

/// Envía un enlace de verificación de un solo uso
pub async fn send_verification_link(
    mailer: &SmtpMailer,
    from_email: &str,
    to: &str,
    link: &str,
    minutes: i64,
) -> Result<(), String> {
    send(
        mailer,
        from_email,
        to,
        templates::verification_link(link, minutes),
    )
    .await
}

/// `multipart/alternative` con el texto plano y, como alternativa preferida,
/// `multipart/related` con el HTML y sus imágenes por CID.
fn body(email: &Email) -> MultiPart {
    let png = ContentType::parse("image/png").expect("tipo MIME válido");
    let related = email.images.iter().fold(
        MultiPart::related().singlepart(SinglePart::html(email.html.clone())),
        |related, image| {
            related.singlepart(
                Attachment::new_inline(image.cid.to_string()).body(image.png.to_vec(), png.clone()),
            )
        },
    );
    MultiPart::alternative()
        .singlepart(SinglePart::plain(email.text.clone()))
        .multipart(related)
}

async fn send(mailer: &SmtpMailer, from_email: &str, to: &str, email: Email) -> Result<(), String> {
    let message = Message::builder()
        .from(
            from_email
                .parse()
                .map_err(|e| format!("Error al parsear remitente SMTP: {}", e))?,
        )
        .to(to
            .parse()
            .map_err(|e| format!("Error al parsear destinatario: {}", e))?)
        .subject(&email.subject)
        .multipart(body(&email))
        .map_err(|e| format!("Error al construir el correo: {}", e))?;

    mailer
        .send(message)
        .await
        .map_err(|e| format!("Error al enviar correo: {}", e))?;

    Ok(())
}
