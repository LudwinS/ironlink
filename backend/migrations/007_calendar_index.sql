-- Sprint 4: bounded cross-node calendar ordered by scheduled start and ID.
CREATE INDEX IF NOT EXISTS idx_reuniones_calendar_start
    ON reuniones (fecha_inicio, id);
