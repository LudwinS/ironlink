-- Sprint 3: estado persistente de llamada y pases WebSocket de un solo uso.
ALTER TABLE reuniones ADD COLUMN IF NOT EXISTS rtc_estado TEXT NOT NULL DEFAULT 'scheduled';
ALTER TABLE reuniones ADD COLUMN IF NOT EXISTS rtc_started_at TIMESTAMPTZ;
ALTER TABLE reuniones ADD COLUMN IF NOT EXISTS rtc_ended_at TIMESTAMPTZ;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'reuniones_rtc_estado_check') THEN
        ALTER TABLE reuniones ADD CONSTRAINT reuniones_rtc_estado_check
            CHECK (rtc_estado IN ('scheduled', 'active', 'ended'));
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS rtc_tickets (
    id UUID PRIMARY KEY,
    reunion_id UUID NOT NULL REFERENCES reuniones(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_rtc_tickets_expiry ON rtc_tickets(expires_at);
