-- Sprint 4 (IRL-RTC-US-08): pizarra compartida por canal de la reunión.
-- canal_id = ID de la reunión (sala principal) o de una sala de trabajo.
CREATE TABLE IF NOT EXISTS pizarra_trazos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reunion_id UUID NOT NULL REFERENCES reuniones(id) ON DELETE CASCADE,
    canal_id UUID NOT NULL,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- {"puntos":[[x,y],...] normalizados 0..1, "color":"#rrggbb", "grosor":n}
    datos JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_pizarra_canal ON pizarra_trazos (canal_id, created_at, id);

CREATE TABLE IF NOT EXISTS pizarra_permisos (
    canal_id UUID PRIMARY KEY,
    reunion_id UUID NOT NULL REFERENCES reuniones(id) ON DELETE CASCADE,
    todos_dibujan BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
