-- Per-meeting restrictions. A room kick does not remove node membership.
CREATE TABLE IF NOT EXISTS rtc_participant_controls (
    reunion_id UUID NOT NULL REFERENCES reuniones(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    microphone_allowed BOOLEAN NOT NULL DEFAULT TRUE,
    camera_allowed BOOLEAN NOT NULL DEFAULT TRUE,
    kicked BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (reunion_id, user_id)
);
