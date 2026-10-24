-- Sprint 4 (IRL-SEC-US-01/02): registro automático de asistencia por conexión RTC.
-- Lo escribe solo el servidor al admitir y cerrar cada WebSocket de la sala.
CREATE TABLE IF NOT EXISTS reunion_asistencia (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reunion_id UUID NOT NULL REFERENCES reuniones(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    connection_id UUID NOT NULL UNIQUE,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Se actualiza en cada latido (5 s): tras una caída del servidor es la
    -- mejor evidencia de hasta cuándo siguió conectado.
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    left_at TIMESTAMPTZ,
    salida TEXT CHECK (salida IN (
        'salio', 'conexion_perdida', 'expulsado', 'reunion_finalizada',
        'reemplazada', 'sin_autorizacion', 'limite_sesion', 'servidor_reiniciado'
    )),
    CHECK (left_at IS NULL OR left_at >= joined_at)
);
CREATE INDEX IF NOT EXISTS idx_asistencia_reunion ON reunion_asistencia (reunion_id, joined_at);
CREATE INDEX IF NOT EXISTS idx_asistencia_abiertas ON reunion_asistencia (reunion_id) WHERE left_at IS NULL;
