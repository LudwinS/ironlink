-- Cerrar sesión también invalida los pases de un solo uso de /live/ws y
-- /rtc/ws: cada pase guarda la versión de sesión con la que se emitió y solo
-- se canjea si la del usuario sigue siendo la misma (ver migración 019).
-- Migración aditiva e idempotente.
ALTER TABLE IF EXISTS live_tickets ADD COLUMN IF NOT EXISTS version_sesion INTEGER NOT NULL DEFAULT 0;
ALTER TABLE IF EXISTS rtc_tickets ADD COLUMN IF NOT EXISTS version_sesion INTEGER NOT NULL DEFAULT 0;
