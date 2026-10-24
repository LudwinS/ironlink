-- Privacidad social al estilo de Discord: bloqueos, solicitudes ignoradas,
-- ajuste de quién puede enviar solicitudes, límite de búsquedas y chat
-- entre amigos sin nodo en común. Migración aditiva e idempotente.

-- 1. Rechazar = ignorar: la fila pasa a 'ignorada'. Quien la recibió deja
-- de verla; quien la envió la sigue viendo como enviada (sin aviso).
ALTER TABLE amistades DROP CONSTRAINT IF EXISTS amistades_estado_check;
ALTER TABLE amistades ADD CONSTRAINT amistades_estado_check
    CHECK (estado IN ('pendiente', 'aceptada', 'ignorada'));

-- Recuerda el rechazo aunque quien envió cancele su solicitud: no puede
-- reenviarla hasta 30 días después de `created_at`.
CREATE TABLE IF NOT EXISTS amistad_rechazos (
    solicitante UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    destinatario UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (solicitante, destinatario)
);

-- 2. Bloqueos (unidireccionales). Bloquear borra la amistad y las
-- solicitudes de la pareja; el resto se comprueba en cada operación.
CREATE TABLE IF NOT EXISTS bloqueos (
    bloqueador UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    bloqueado UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (bloqueador, bloqueado),
    CONSTRAINT bloqueos_no_a_si_mismo CHECK (bloqueador <> bloqueado)
);
CREATE INDEX IF NOT EXISTS idx_bloqueos_bloqueado ON bloqueos (bloqueado);

-- 3. Quién puede enviarte solicitudes. Sin fila = 'todos'.
CREATE TABLE IF NOT EXISTS privacidad_social (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    solicitudes_de TEXT NOT NULL DEFAULT 'todos'
        CHECK (solicitudes_de IN ('todos', 'nodos', 'nadie')),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 4. Registro de búsquedas de personas para limitarlas por minuto.
CREATE TABLE IF NOT EXISTS busquedas_personas (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_busquedas_personas_usuario
    ON busquedas_personas (user_id, created_at);

-- 5. Chat entre amigos, independiente de los nodos: tabla propia para no
-- tocar `direct_messages` (cuyas consultas asumen un nodo).
CREATE TABLE IF NOT EXISTS mensajes_amistad (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_at TIMESTAMPTZ,
    CONSTRAINT mensajes_amistad_distintos CHECK (sender_id <> recipient_id),
    CONSTRAINT mensajes_amistad_longitud CHECK (char_length(content) BETWEEN 1 AND 2000)
);
CREATE INDEX IF NOT EXISTS idx_mensajes_amistad_pareja
    ON mensajes_amistad (LEAST(sender_id, recipient_id), GREATEST(sender_id, recipient_id), created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mensajes_amistad_emisor
    ON mensajes_amistad (sender_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mensajes_amistad_no_leidos
    ON mensajes_amistad (recipient_id, sender_id) WHERE read_at IS NULL;

-- 6. Búsqueda por correo exacto sin distinguir mayúsculas.
CREATE INDEX IF NOT EXISTS idx_users_email_lower ON users (lower(email));
