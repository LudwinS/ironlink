//! Correos de IronLink con el diseño Nocturne (Claude Design, «IronLink —
//! Correos y notificaciones»). El HTML usa tablas y estilos en línea para
//! Gmail, Outlook y Apple Mail; cada correo lleva además su versión en texto
//! plano y sus imágenes embebidas por CID (sin cargar nada de internet).

/// Imagen embebida en el correo y referenciada como `cid:<cid>`.
pub struct Image {
    pub cid: &'static str,
    pub png: &'static [u8],
}

pub struct Email {
    pub subject: String,
    pub html: String,
    pub text: String,
    pub images: Vec<&'static Image>,
}

pub const LOGO: Image = Image {
    cid: "logo@ironlink",
    png: include_bytes!("../../assets/email/logo-mark.png"),
};
const NODES: Image = Image {
    cid: "nodes@ironlink",
    png: include_bytes!("../../assets/email/icon-nodes.png"),
};
const VIDEO: Image = Image {
    cid: "video@ironlink",
    png: include_bytes!("../../assets/email/icon-video.png"),
};
const CALENDAR: Image = Image {
    cid: "calendar@ironlink",
    png: include_bytes!("../../assets/email/icon-calendar.png"),
};
const CLOCK: Image = Image {
    cid: "clock@ironlink",
    png: include_bytes!("../../assets/email/icon-clock.png"),
};
const SHIELD: Image = Image {
    cid: "shield@ironlink",
    png: include_bytes!("../../assets/email/icon-shield.png"),
};
const WARNING: Image = Image {
    cid: "warning@ironlink",
    png: include_bytes!("../../assets/email/icon-warning.png"),
};

const ACCENT: &str = "#9184D9";
const ACCENT_TEXT: &str = "#D2CEFD";
const AMBER: &str = "#FCD34D";
const FONT: &str = "-apple-system, 'Segoe UI', Helvetica, Arial, sans-serif";
const MONO: &str = "'SF Mono', Menlo, Consolas, monospace";

/// Escapa texto para HTML, también dentro de atributos.
pub fn escape(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for c in input.chars() {
        match c {
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '&' => out.push_str("&amp;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

/// Partes de un correo; todo el texto llega ya escapado salvo `body`, que
/// es HTML construido con los ayudantes de este módulo.
struct Layout<'a> {
    preheader: &'a str,
    accent: &'a str,
    eyebrow: &'a str,
    eyebrow_color: &'a str,
    title: &'a str,
    body: String,
    /// Sección inferior de la tarjeta (consejo de seguridad o lista).
    bottom: String,
    footer: &'a [&'a str],
}

fn layout(l: Layout) -> String {
    let footer: String = l
        .footer
        .iter()
        .map(|line| {
            format!(
                r#"<tr><td style="padding:0 8px 6px 8px;font-family:{FONT};font-size:12px;line-height:1.6;color:#75798C;">{line}</td></tr>"#
            )
        })
        .collect();
    format!(
        r##"<!doctype html>
<html lang="es" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<meta name="supported-color-schemes" content="dark light">
<title>IronLink</title>
<!--[if mso]><xml><o:OfficeDocumentSettings><o:AllowPNG/><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml><![endif]-->
<style>
:root {{ color-scheme: dark light; supported-color-schemes: dark light; }}
body {{ margin:0; padding:0; background:#0C0D14; }}
a {{ color:{ACCENT_TEXT}; }}
@media (max-width:620px) {{ .card-pad {{ padding-left:24px !important; padding-right:24px !important; }} .digit {{ width:40px !important; height:56px !important; font-size:26px !important; }} }}
</style>
</head>
<body style="margin:0;padding:0;background:#0C0D14;">
<div style="display:none;max-height:0;max-width:0;overflow:hidden;opacity:0;font-size:1px;line-height:1px;color:#0C0D14;">{preheader}&#8203;&nbsp;&#8203;&nbsp;&#8203;&nbsp;&#8203;&nbsp;&#8203;&nbsp;</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#0C0D14;">
<tr><td align="center" style="padding:40px 16px;">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:600px;">
<tr><td style="padding:0 8px 24px 8px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
<td valign="middle" style="padding-right:12px;"><img src="cid:{logo}" alt="IronLink" width="36" height="36" style="display:block;width:36px;height:36px;border:0;"></td>
<td valign="middle" style="font-family:{FONT};font-size:18px;font-weight:700;letter-spacing:-0.2px;color:#E9E9ED;">IronLink</td>
</tr></table>
</td></tr>
<tr><td>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;background:#161826;border:1px solid #292B31;border-radius:20px;overflow:hidden;">
<tr><td style="height:3px;line-height:3px;font-size:3px;background:{accent};">&nbsp;</td></tr>
<tr><td class="card-pad" style="padding:44px 44px 36px 44px;font-family:{FONT};color:#E9E9ED;">
<div style="font-size:12px;font-weight:600;letter-spacing:1.6px;text-transform:uppercase;color:{eyebrow_color};">{eyebrow}</div>
<h1 style="margin:18px 0 0 0;font-size:30px;line-height:1.2;font-weight:700;letter-spacing:-0.6px;color:#E9E9ED;">{title}</h1>
{body}
</td></tr>
<tr><td class="card-pad" style="border-top:1px solid #292B31;padding:24px 44px 32px 44px;font-family:{FONT};">{bottom}</td></tr>
</table>
</td></tr>
<tr><td style="padding-top:24px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">{footer}</table></td></tr>
</table>
</td></tr>
</table>
</body>
</html>"##,
        preheader = l.preheader,
        logo = LOGO.cid,
        accent = l.accent,
        eyebrow_color = l.eyebrow_color,
        eyebrow = l.eyebrow,
        title = l.title,
        body = l.body,
        bottom = l.bottom,
    )
}

fn paragraph(text: &str) -> String {
    format!(
        r#"<p style="margin:18px 0 0 0;font-size:16px;line-height:1.6;color:#B2B6CA;">{text}</p>"#
    )
}

/// Botón redondeado; en Outlook para Windows, con VML.
fn button(href: &str, label: &str) -> String {
    format!(
        r##"<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:26px;"><tr><td>
<!--[if mso]><v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="{href}" style="height:48px;v-text-anchor:middle;width:200px;" arcsize="25%" stroke="f" fillcolor="{ACCENT}"><w:anchorlock/><center style="color:#161826;font-family:Arial,sans-serif;font-size:15px;font-weight:bold;">{label}</center></v:roundrect><![endif]-->
<!--[if !mso]><!--><a href="{href}" style="display:inline-block;background:{ACCENT};color:#161826;font-family:{FONT};font-size:15px;font-weight:700;line-height:48px;padding:0 26px;border-radius:12px;text-decoration:none;">{label}</a><!--<![endif]-->
</td></tr></table>"##
    )
}

/// Los seis dígitos en casillas, como en el diseño.
fn digits(code: &str) -> String {
    let cells: Vec<String> = code
        .chars()
        .map(|d| {
            format!(
                r#"<td class="digit" width="56" height="68" align="center" valign="middle" style="width:56px;height:68px;background:#1D1F2C;border:1px solid #5D5294;border-radius:14px;font-family:{MONO};font-size:32px;font-weight:700;color:#FFFFFF;">{d}</td>"#,
                d = escape(&d.to_string())
            )
        })
        .collect();
    format!(
        r#"<table role="presentation" align="center" cellpadding="0" cellspacing="0" border="0" style="margin:30px auto 0 auto;border-collapse:separate;border-spacing:8px 0;"><tr>{}</tr></table>"#,
        cells.join("")
    )
}

fn expires(minutes: i64) -> String {
    format!(
        r#"<table role="presentation" align="center" cellpadding="0" cellspacing="0" border="0" style="margin:18px auto 0 auto;"><tr>
<td valign="middle" style="padding-right:8px;"><img src="cid:{cid}" alt="" width="16" height="16" style="display:block;width:16px;height:16px;border:0;"></td>
<td valign="middle" style="font-family:{FONT};font-size:14px;color:#9397AB;">Vence en {minutes} minutos</td>
</tr></table>"#,
        cid = CLOCK.cid
    )
}

/// Consejo con icono para la parte inferior de la tarjeta.
fn notice(icon: &Image, text: &str) -> String {
    format!(
        r#"<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
<td valign="top" style="padding:2px 14px 0 0;"><img src="cid:{cid}" alt="" width="20" height="20" style="display:block;width:20px;height:20px;border:0;"></td>
<td valign="top" style="font-family:{FONT};font-size:14px;line-height:1.6;color:#B2B6CA;">{text}</td>
</tr></table>"#,
        cid = icon.cid
    )
}

fn feature(icon: &Image, title: &str, text: &str) -> String {
    format!(
        r#"<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:22px;"><tr>
<td valign="top" width="40" style="width:40px;"><table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;"><tr><td width="40" height="40" align="center" valign="middle" style="width:40px;height:40px;background:#2B2741;border-radius:12px;"><img src="cid:{cid}" alt="" width="20" height="20" style="display:block;width:20px;height:20px;border:0;"></td></tr></table></td>
<td valign="top" style="padding-left:16px;font-family:{FONT};"><div style="font-size:15px;font-weight:600;color:#E9E9ED;">{title}</div><div style="margin-top:4px;font-size:14px;line-height:1.5;color:#B2B6CA;">{text}</div></td>
</tr></table>"#,
        cid = icon.cid
    )
}

/// Bienvenida, al quedar verificada la cuenta. `app_url` es la dirección
/// pública de la app (`APP_PUBLIC_URL`); sin ella no hay botón.
pub fn welcome(name: &str, app_url: Option<&str>) -> Email {
    let name_text = name.trim();
    let name_html = escape(name_text);
    let intro = "Tu cuenta está lista. IronLink reúne a tu equipo en un solo lugar: nodos para cada proyecto, chat, llamadas y la agenda de reuniones.";
    let mut body = paragraph(intro);
    if let Some(url) = app_url {
        body.push_str(&button(&escape(url), "Abrir IronLink"));
    }
    let bottom = format!(
        r#"<div style="font-size:13px;font-weight:600;color:#9397AB;">Para empezar</div>{}{}{}"#,
        feature(
            &NODES,
            "Crea o únete a un nodo",
            "Un espacio por proyecto, con subgrupos, canales y miembros."
        ),
        feature(
            &VIDEO,
            "Llama sin salir de la app",
            "Video, audio y pantalla compartida directo entre participantes."
        ),
        feature(
            &CALENDAR,
            "Organiza la agenda",
            "Reuniones, series y disponibilidad del equipo, o «Reunirse ahora»."
        ),
    );
    let footer = [
        "Recibes este correo porque se creó una cuenta en IronLink con esta dirección.",
        "IronLink · InnovaSoft",
    ];
    let html = layout(Layout {
        preheader: &escape(&format!(
            "Hola, {name_text}. Tu cuenta de IronLink está lista."
        )),
        accent: ACCENT,
        eyebrow: "Bienvenida",
        eyebrow_color: ACCENT_TEXT,
        title: &format!("Hola, {name_html}. Ya eres parte de IronLink."),
        body,
        bottom,
        footer: &footer,
    });
    let mut text = format!("Hola, {name_text}. Ya eres parte de IronLink.\n\n{intro}\n");
    if let Some(url) = app_url {
        text.push_str(&format!("\nAbrir IronLink: {url}\n"));
    }
    text.push_str(
        "\nPara empezar:\n\
         - Crea o únete a un nodo: un espacio por proyecto, con subgrupos, canales y miembros.\n\
         - Llama sin salir de la app: video, audio y pantalla compartida directo entre participantes.\n\
         - Organiza la agenda: reuniones, series y disponibilidad del equipo, o «Reunirse ahora».\n\
         \nRecibes este correo porque se creó una cuenta en IronLink con esta dirección.\n\
         IronLink · InnovaSoft\n",
    );
    Email {
        subject: "Bienvenido a IronLink".into(),
        html,
        text,
        images: vec![&LOGO, &NODES, &VIDEO, &CALENDAR],
    }
}

/// Código de verificación. El código va también en el asunto para que Apple
/// Mail y Gmail lo ofrezcan para rellenar.
pub fn verification_code(code: &str, minutes: i64) -> Email {
    let code_html = escape(code);
    let html = layout(Layout {
        preheader: &format!("Tu código es {code_html}. Vence en {minutes} minutos."),
        accent: ACCENT,
        eyebrow: "Verifica tu correo",
        eyebrow_color: ACCENT_TEXT,
        title: "Tu código de verificación",
        body: format!(
            "{}{}{}",
            paragraph("Escribe este código en IronLink para confirmar que esta dirección es tuya."),
            digits(code),
            expires(minutes)
        ),
        bottom: notice(
            &SHIELD,
            "Nadie de IronLink te pedirá este código. Si no intentaste crear una cuenta, ignora este correo.",
        ),
        footer: &["Este código es de un solo uso.", "IronLink · InnovaSoft"],
    });
    let text = format!(
        "Tu código de verificación de IronLink: {code}\n\n\
         Escribe este código en IronLink para confirmar que esta dirección es tuya. Vence en {minutes} minutos.\n\n\
         Nadie de IronLink te pedirá este código. Si no intentaste crear una cuenta, ignora este correo.\n\n\
         IronLink · InnovaSoft\n"
    );
    Email {
        subject: format!("Tu código de IronLink: {code}"),
        html,
        text,
        images: vec![&LOGO, &CLOCK, &SHIELD],
    }
}

pub fn verification_link(link: &str, minutes: i64) -> Email {
    let link_html = escape(link);
    let html = layout(Layout {
        preheader: "Confirma tu dirección para activar tu cuenta de IronLink.",
        accent: ACCENT,
        eyebrow: "Verifica tu correo",
        eyebrow_color: ACCENT_TEXT,
        title: "Confirma tu dirección con un clic",
        body: format!(
            r#"{}{}<p style="margin:28px 0 8px 0;font-size:13px;color:#9397AB;">¿El botón no funciona? Copia este enlace en tu navegador:</p><div style="font-family:{MONO};font-size:12px;line-height:1.6;color:{ACCENT_TEXT};background:#1D1F2C;border:1px solid #292B31;border-radius:10px;padding:12px 14px;word-break:break-all;"><a href="{link_html}" style="color:{ACCENT_TEXT};text-decoration:none;">{link_html}</a></div>"#,
            paragraph(&format!(
                "Pulsa el botón para verificar tu cuenta de IronLink. El enlace vence en {minutes} minutos y solo funciona una vez."
            )),
            button(&link_html, "Verificar mi correo"),
        ),
        bottom: notice(
            &SHIELD,
            "Si no creaste una cuenta en IronLink, ignora este correo; nadie podrá usar tu dirección sin este enlace.",
        ),
        footer: &["IronLink · InnovaSoft"],
    });
    let text = format!(
        "Confirma tu dirección de IronLink\n\n\
         Abre este enlace para verificar tu cuenta. Vence en {minutes} minutos y solo funciona una vez:\n{link}\n\n\
         Si no creaste una cuenta en IronLink, ignora este correo.\n\n\
         IronLink · InnovaSoft\n"
    );
    Email {
        subject: "Confirma tu correo de IronLink".into(),
        html,
        text,
        images: vec![&LOGO, &SHIELD],
    }
}

pub fn password_reset(code: &str, minutes: i64) -> Email {
    let code_html = escape(code);
    let html = layout(Layout {
        preheader: &format!("Tu código para restablecer la contraseña es {code_html}."),
        accent: AMBER,
        eyebrow: "Recuperar contraseña",
        eyebrow_color: AMBER,
        title: "Código para restablecer tu contraseña",
        body: format!(
            "{}{}{}",
            paragraph(
                "Alguien pidió cambiar la contraseña de tu cuenta. Si fuiste tú, escribe este código en IronLink."
            ),
            digits(code),
            expires(minutes)
        ),
        bottom: notice(
            &WARNING,
            "¿No lo pediste? Ignora este correo: tu contraseña no cambia. Al restablecerla se cerrará la sesión en todos tus dispositivos.",
        ),
        footer: &[
            "Nadie de IronLink te pedirá este código.",
            "IronLink · InnovaSoft",
        ],
    });
    let text = format!(
        "Código para restablecer tu contraseña de IronLink: {code}\n\n\
         Alguien pidió cambiar la contraseña de tu cuenta. Si fuiste tú, escribe este código en IronLink. Vence en {minutes} minutos.\n\n\
         ¿No lo pediste? Ignora este correo: tu contraseña no cambia. Al restablecerla se cerrará la sesión en todos tus dispositivos.\n\n\
         Nadie de IronLink te pedirá este código.\n\
         IronLink · InnovaSoft\n"
    );
    Email {
        subject: format!("Restablece tu contraseña de IronLink: {code}"),
        html,
        text,
        images: vec![&LOGO, &CLOCK, &WARNING],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cids(html: &str) -> Vec<&str> {
        html.split("cid:")
            .skip(1)
            .map(|rest| &rest[..rest.find('"').unwrap()])
            .collect()
    }

    /// Cada `cid:` del HTML tiene su imagen adjunta y no se adjunta ninguna
    /// que no se use.
    fn assert_images_match(email: &Email) {
        let mut used = cids(&email.html);
        used.sort_unstable();
        used.dedup();
        let mut attached: Vec<&str> = email.images.iter().map(|i| i.cid).collect();
        attached.sort_unstable();
        assert_eq!(used, attached);
        for image in &email.images {
            assert!(image.png.starts_with(b"\x89PNG"), "{}", image.cid);
        }
    }

    #[test]
    fn every_email_is_consistent() {
        let emails = [
            welcome("Ana", Some("https://app.example")),
            welcome("Ana", None),
            verification_code("482071", 15),
            verification_link("https://api.example/verify-link/abc", 15),
            password_reset("739156", 15),
        ];
        for email in &emails {
            assert_images_match(email);
            assert!(email.html.contains("color-scheme"));
            assert!(!email.text.contains('<'), "texto plano sin HTML");
            assert!(!email.html.contains("{{") && !email.html.contains("}}"));
        }
    }

    #[test]
    fn codes_and_minutes_reach_every_part() {
        for (email, code) in [
            (verification_code("482071", 15), "482071"),
            (password_reset("739156", 15), "739156"),
        ] {
            assert!(email.subject.contains(code));
            assert!(email.text.contains(code));
            assert!(email.text.contains("15 minutos"));
            assert!(email.html.contains("Vence en 15 minutos"));
            for digit in code.chars() {
                assert!(email.html.contains(&format!(">{digit}</td>")));
            }
        }
        let link = verification_link("https://api.example/verify-link/abc", 20);
        assert!(link.html.contains("vence en 20 minutos"));
        assert!(link.text.contains("https://api.example/verify-link/abc"));
    }

    #[test]
    fn user_data_is_escaped_everywhere() {
        let evil = "<img src=x onerror=alert(1)> & \"Ana\"";
        let email = welcome(evil, Some("https://app.example/?a=1&b=\"x\""));
        assert!(!email.html.contains("<img src=x"));
        assert!(!email.html.contains("onerror=alert(1)>"));
        assert!(
            email
                .html
                .contains("&lt;img src=x onerror=alert(1)&gt; &amp; &quot;Ana&quot;")
        );
        assert!(
            email
                .html
                .contains("href=\"https://app.example/?a=1&amp;b=&quot;x&quot;\"")
        );
        // El texto plano no es HTML: va tal cual.
        assert!(email.text.contains(evil));

        let link = verification_link("https://x.example/\"><script>", 15);
        assert!(!link.html.contains("<script>"));
    }

    /// Vistas previas en HTML para revisar el diseño en un navegador:
    /// `IRONLINK_EMAIL_PREVIEW_DIR=/ruta cargo test write_previews -- --ignored`.
    #[test]
    #[ignore = "genera archivos; solo bajo demanda"]
    fn write_previews() {
        // Sin carpeta indicada no hay nada que generar (la suite completa
        // también ejecuta las pruebas ignoradas).
        let Ok(dir) = std::env::var("IRONLINK_EMAIL_PREVIEW_DIR") else {
            return;
        };
        let dir = std::path::PathBuf::from(dir);
        std::fs::create_dir_all(&dir).unwrap();
        let emails = [
            (
                "bienvenida",
                welcome("Ana Pérez", Some("https://app.example")),
            ),
            ("codigo", verification_code("482071", 15)),
            (
                "enlace",
                verification_link("https://api.example/verify-link/3f9c", 15),
            ),
            ("recuperacion", password_reset("739156", 15)),
        ];
        for (name, email) in emails {
            let mut html = email.html;
            for image in &email.images {
                let file = dir.join(format!("{}.png", image.cid.split('@').next().unwrap()));
                std::fs::write(&file, image.png).unwrap();
                html = html.replace(&format!("cid:{}", image.cid), file.to_str().unwrap());
            }
            std::fs::write(dir.join(format!("{name}.html")), html).unwrap();
        }
    }

    #[test]
    fn welcome_button_needs_a_public_url() {
        assert!(
            welcome("Ana", Some("https://app.example"))
                .html
                .contains("Abrir IronLink")
        );
        let without = welcome("Ana", None);
        assert!(!without.html.contains("Abrir IronLink"));
        assert!(!without.text.contains("Abrir IronLink"));
    }
}
