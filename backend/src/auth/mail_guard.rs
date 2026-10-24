//! Topes en memoria para las rutas que envían correo (verificación y
//! recuperación). El límite de 3 por hora de `verification_tokens` solo cuenta
//! los correos que salieron; estos topes cubren lo demás:
//!
//! - Por IP: 10 solicitudes cada 15 minutos, salgan o no.
//! - Por dirección: 5 envíos fallidos cada 15 minutos. Se cuenta por la
//!   dirección escrita (normalizada) y no por la cuenta, para que una dirección
//!   desconocida se comporte igual que una registrada.
//!
//! Viven en el proceso: con varias instancias del backend cada una lleva su
//! cuenta, lo que basta para que un SMTP caído no se convierta en un relé sin
//! límite.

use std::collections::{HashMap, VecDeque};
use std::hash::Hash;
use std::net::{IpAddr, SocketAddr};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use axum::extract::{ConnectInfo, Request};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};

use crate::auth::service::ApiResponse;

const WINDOW: Duration = Duration::from_secs(15 * 60);
/// Por encima de esta cantidad de claves se purgan las que ya no tienen
/// solicitudes dentro de la ventana.
const PRUNE_ABOVE: usize = 4096;

static BY_IP: LazyLock<SlidingLimit<IpAddr>> = LazyLock::new(|| SlidingLimit::new(10));
static FAILED_BY_ADDRESS: LazyLock<SlidingLimit<String>> = LazyLock::new(|| SlidingLimit::new(5));

/// Ventana deslizante: como mucho `max` marcas por clave en [`WINDOW`].
pub struct SlidingLimit<K> {
    max: usize,
    hits: Mutex<HashMap<K, VecDeque<Instant>>>,
}

impl<K: Hash + Eq + Clone> SlidingLimit<K> {
    pub fn new(max: usize) -> Self {
        Self {
            max,
            hits: Mutex::new(HashMap::new()),
        }
    }

    /// Segundos hasta que `key` vuelva a tener hueco, o `None` si lo tiene.
    pub fn retry_after(&self, key: &K, now: Instant) -> Option<u64> {
        let mut hits = self.hits.lock().unwrap_or_else(|e| e.into_inner());
        let queue = hits.get_mut(key)?;
        expire(queue, now);
        (queue.len() >= self.max).then(|| {
            let oldest = queue.front().copied().unwrap_or(now);
            (WINDOW.saturating_sub(now - oldest).as_secs()).max(1)
        })
    }

    /// Comprueba y anota en un solo paso: dos solicitudes simultáneas no
    /// pueden ocupar el mismo hueco.
    pub fn try_take(&self, key: K, now: Instant) -> Result<(), u64> {
        let mut hits = self.hits.lock().unwrap_or_else(|e| e.into_inner());
        if hits.len() > PRUNE_ABOVE {
            hits.retain(|_, queue| {
                expire(queue, now);
                !queue.is_empty()
            });
        }
        let queue = hits.entry(key).or_default();
        expire(queue, now);
        if queue.len() >= self.max {
            let oldest = queue.front().copied().unwrap_or(now);
            return Err((WINDOW.saturating_sub(now - oldest).as_secs()).max(1));
        }
        queue.push_back(now);
        Ok(())
    }

    pub fn record(&self, key: K, now: Instant) {
        let _ = self.try_take(key, now);
    }
}

fn expire(queue: &mut VecDeque<Instant>, now: Instant) {
    while queue.front().is_some_and(|t| now - *t >= WINDOW) {
        queue.pop_front();
    }
}

/// 429 con `Retry-After` y el mensaje habitual de la API.
pub fn too_many(retry_after: u64) -> Response {
    let mut response = (
        StatusCode::TOO_MANY_REQUESTS,
        ApiResponse::failure("Demasiados intentos. Inténtalo de nuevo en unos minutos."),
    )
        .into_response();
    response
        .headers_mut()
        .insert(header::RETRY_AFTER, HeaderValue::from(retry_after));
    response
}

/// IP del cliente. Detrás de un proxy (`TRUST_PROXY=1`) se toma la última
/// dirección de `X-Forwarded-For`, la que añadió el proxy; las anteriores las
/// escribe el cliente y no son fiables.
pub fn client_ip(
    headers: &HeaderMap,
    peer: Option<SocketAddr>,
    trust_proxy: bool,
) -> Option<IpAddr> {
    if trust_proxy {
        // Solo la última entrada: si no es una IP válida no se recurre a las
        // anteriores, que puede haber escrito el cliente.
        let forwarded = headers
            .get_all("x-forwarded-for")
            .iter()
            .next_back()
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.rsplit(',').next())
            .and_then(|ip| ip.trim().parse().ok());
        if forwarded.is_some() {
            return forwarded;
        }
    }
    peer.map(|addr| addr.ip())
}

/// Capa para las rutas que envían correo: tope por IP.
pub async fn limit_by_ip(request: Request, next: Next) -> Response {
    let peer = request
        .extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|info| info.0);
    let trust_proxy = std::env::var("TRUST_PROXY").is_ok_and(|v| v == "1");
    if let Some(ip) = client_ip(request.headers(), peer, trust_proxy)
        && let Err(retry_after) = BY_IP.try_take(ip, Instant::now())
    {
        return too_many(retry_after);
    }
    next.run(request).await
}

/// Normaliza la dirección como lo hacen las consultas de usuarios.
fn address_key(email: &str) -> String {
    email.trim().to_lowercase()
}

/// `Some(segundos)` si la dirección acumuló demasiados envíos fallidos.
pub fn failures_block(email: &str) -> Option<u64> {
    FAILED_BY_ADDRESS.retry_after(&address_key(email), Instant::now())
}

pub fn record_failure(email: &str) {
    FAILED_BY_ADDRESS.record(address_key(email), Instant::now());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sliding_window_blocks_and_frees_slots() {
        let limit = SlidingLimit::new(2);
        let start = Instant::now();
        assert!(limit.try_take("a", start).is_ok());
        assert!(limit.try_take("a", start + Duration::from_secs(60)).is_ok());
        let retry = limit
            .try_take("a", start + Duration::from_secs(120))
            .unwrap_err();
        assert_eq!(retry, 15 * 60 - 120);
        assert!(
            limit.try_take("b", start).is_ok(),
            "otra clave no se ve afectada"
        );
        assert!(
            limit.try_take("a", start + WINDOW).is_ok(),
            "la primera marca caducó"
        );
    }

    #[test]
    fn retry_after_does_not_consume_slots() {
        let limit = SlidingLimit::new(1);
        let now = Instant::now();
        assert_eq!(limit.retry_after(&"a", now), None);
        assert_eq!(limit.retry_after(&"a", now), None);
        limit.record("a", now);
        assert!(limit.retry_after(&"a", now).is_some());
    }

    #[test]
    fn stale_keys_are_pruned() {
        let limit = SlidingLimit::new(1);
        let start = Instant::now();
        for i in 0..=PRUNE_ABOVE {
            limit.record(i, start);
        }
        limit.record(usize::MAX, start + WINDOW);
        assert_eq!(limit.hits.lock().unwrap().len(), 1);
    }

    #[test]
    fn forwarded_for_only_behind_trusted_proxy() {
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-for", "1.1.1.1, 2.2.2.2".parse().unwrap());
        let peer: SocketAddr = "10.0.0.1:5000".parse().unwrap();
        assert_eq!(client_ip(&headers, Some(peer), false), Some(peer.ip()));
        assert_eq!(
            client_ip(&headers, Some(peer), true),
            Some("2.2.2.2".parse().unwrap())
        );
        assert_eq!(
            client_ip(&HeaderMap::new(), Some(peer), true),
            Some(peer.ip())
        );
        assert_eq!(client_ip(&HeaderMap::new(), None, false), None);
    }
}
