-- Detalles de calendario al estilo de un calendario de equipo: eventos de
-- todo el día, ubicación opcional y consulta de disponibilidad.
-- Idempotente y aditiva: se puede ejecutar varias veces.
ALTER TABLE reuniones ADD COLUMN IF NOT EXISTS todo_el_dia BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE reuniones ADD COLUMN IF NOT EXISTS ubicacion TEXT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'reuniones_ubicacion_longitud'
    ) THEN
        ALTER TABLE reuniones ADD CONSTRAINT reuniones_ubicacion_longitud
            CHECK (ubicacion IS NULL OR char_length(ubicacion) <= 200);
    END IF;
END $$;

-- Disponibilidad: reuniones vigentes que organiza cada persona, por fecha.
CREATE INDEX IF NOT EXISTS idx_reuniones_creador_inicio
    ON reuniones (creado_por, fecha_inicio)
    WHERE rtc_estado IN ('scheduled', 'active');
