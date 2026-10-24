-- Sprint 4 (IRL-NTF-US-01/03): notificaciones persistentes por usuario.
CREATE TABLE IF NOT EXISTS notificaciones (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tipo TEXT NOT NULL CHECK (tipo IN ('recordatorio_15', 'recordatorio_5', 'reunion_iniciada')),
    nodo_id UUID NOT NULL REFERENCES nodos(id) ON DELETE CASCADE,
    reunion_id UUID NOT NULL REFERENCES reuniones(id) ON DELETE CASCADE,
    titulo TEXT NOT NULL,
    -- Hora de inicio de la reunión cuando se generó: el cliente la muestra en
    -- su zona horaria. Reprogramar la reunión genera recordatorios nuevos.
    programada_para TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_at TIMESTAMPTZ,
    -- Evita duplicados aunque el generador corra varias veces o se reinicie.
    dedupe_key TEXT NOT NULL UNIQUE
);
CREATE INDEX IF NOT EXISTS idx_notificaciones_usuario ON notificaciones (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reuniones_programadas ON reuniones (fecha_inicio) WHERE rtc_estado = 'scheduled';
