-- QA: versión de sesión por usuario. Cada JWT lleva la versión vigente al
-- emitirse y el middleware rechaza los que no coinciden. Cerrar sesión y
-- cambiar o restablecer la contraseña la incrementan (`version_sesion + 1`).
-- Sustituye a `tokens_validos_desde` (migración 014), que comparaba en
-- segundos y dejaba vivo un token cerrado en el mismo segundo de su emisión;
-- esa columna se conserva sin uso. Migración aditiva e idempotente.
ALTER TABLE users ADD COLUMN IF NOT EXISTS version_sesion INTEGER NOT NULL DEFAULT 0;
