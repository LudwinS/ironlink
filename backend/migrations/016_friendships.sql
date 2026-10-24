-- Amistades al estilo de Discord: una fila por pareja de usuarios.
-- 'pendiente' = solicitud de `solicitante` a `destinatario` sin responder;
-- 'aceptada' = amistad. Rechazar, cancelar o eliminar borran la fila.
-- Migración aditiva e idempotente.
CREATE TABLE IF NOT EXISTS amistades (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    solicitante UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    destinatario UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    estado TEXT NOT NULL DEFAULT 'pendiente'
        CHECK (estado IN ('pendiente', 'aceptada')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    responded_at TIMESTAMPTZ,
    CONSTRAINT amistades_no_a_si_mismo CHECK (solicitante <> destinatario)
);

-- Una sola fila por pareja, sin importar quién envió la solicitud.
CREATE UNIQUE INDEX IF NOT EXISTS idx_amistades_pareja
    ON amistades (LEAST(solicitante, destinatario), GREATEST(solicitante, destinatario));
CREATE INDEX IF NOT EXISTS idx_amistades_destinatario ON amistades (destinatario, estado);
CREATE INDEX IF NOT EXISTS idx_amistades_solicitante ON amistades (solicitante, estado);

-- Registro de envíos para limitar solicitudes por hora: cancelar o rechazar
-- borra la solicitud, pero el envío sigue contando para el límite.
CREATE TABLE IF NOT EXISTS amistad_envios (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_amistad_envios_usuario ON amistad_envios (user_id, created_at);
