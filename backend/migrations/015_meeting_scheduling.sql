-- Programación de reuniones al estilo de un calendario de equipo:
-- series repetidas, invitados con respuesta (asistiré / tal vez / no) y
-- reuniones instantáneas ("Reunirse ahora"), que pueden ser privadas para
-- llamadas directas entre personas del nodo.
ALTER TABLE reuniones ADD COLUMN IF NOT EXISTS serie_id UUID;
ALTER TABLE reuniones ADD COLUMN IF NOT EXISTS repeticion TEXT;
ALTER TABLE reuniones ADD COLUMN IF NOT EXISTS espontanea BOOLEAN NOT NULL DEFAULT FALSE;
-- Privada: solo quien la creó y sus invitados la ven y pueden entrar.
ALTER TABLE reuniones ADD COLUMN IF NOT EXISTS privada BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS idx_reuniones_serie ON reuniones (serie_id) WHERE serie_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS reunion_invitados (
    reunion_id UUID NOT NULL REFERENCES reuniones(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    respuesta TEXT NOT NULL DEFAULT 'pendiente'
        CHECK (respuesta IN ('pendiente', 'aceptada', 'tentativa', 'rechazada')),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (reunion_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_reunion_invitados_usuario ON reunion_invitados (user_id);

-- Nuevo tipo de notificación: invitación a una reunión.
ALTER TABLE notificaciones DROP CONSTRAINT IF EXISTS notificaciones_tipo_check;
ALTER TABLE notificaciones ADD CONSTRAINT notificaciones_tipo_check
    CHECK (tipo IN ('recordatorio_15', 'recordatorio_5', 'reunion_iniciada', 'invitacion'));
