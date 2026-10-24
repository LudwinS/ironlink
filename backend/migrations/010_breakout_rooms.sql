-- Sprint 4 (IRL-RTC-US-07): salas de trabajo dentro de una reunión.
CREATE TABLE IF NOT EXISTS reunion_salas (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reunion_id UUID NOT NULL REFERENCES reuniones(id) ON DELETE CASCADE,
    nombre TEXT NOT NULL CHECK (char_length(btrim(nombre)) BETWEEN 1 AND 60),
    orden SMALLINT NOT NULL,
    creada_por UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_salas_abiertas ON reunion_salas (reunion_id) WHERE closed_at IS NULL;

CREATE TABLE IF NOT EXISTS reunion_sala_miembros (
    sala_id UUID NOT NULL REFERENCES reunion_salas(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (sala_id, user_id)
);

-- El pase de entrada indica a qué canal se conecta (NULL = sala principal).
ALTER TABLE rtc_tickets ADD COLUMN IF NOT EXISTS sala_id UUID REFERENCES reunion_salas(id) ON DELETE CASCADE;
-- La asistencia registra en qué sala estuvo cada conexión.
ALTER TABLE reunion_asistencia ADD COLUMN IF NOT EXISTS sala_id UUID REFERENCES reunion_salas(id) ON DELETE SET NULL;
