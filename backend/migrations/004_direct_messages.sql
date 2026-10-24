-- Mensajes privados e invitaciones de llamada entre miembros del mismo nodo.
CREATE TABLE IF NOT EXISTS direct_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nodo_id UUID NOT NULL REFERENCES nodos(id) ON DELETE CASCADE,
    sender_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'text',
    reunion_id UUID REFERENCES reuniones(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_at TIMESTAMPTZ,
    CONSTRAINT direct_messages_distinct_users CHECK (sender_id <> recipient_id),
    CONSTRAINT direct_messages_content_length CHECK (char_length(content) BETWEEN 1 AND 2000),
    CONSTRAINT direct_messages_kind CHECK (kind IN ('text', 'call_invite'))
);
CREATE INDEX IF NOT EXISTS idx_dm_recipient_inbox
    ON direct_messages(nodo_id, recipient_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_dm_sender_history
    ON direct_messages(nodo_id, sender_id, created_at DESC);
