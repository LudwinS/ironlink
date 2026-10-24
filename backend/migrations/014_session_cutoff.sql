-- Revisión profunda: cerrar sesión o cambiar/restablecer la contraseña
-- invalida al instante los tokens de acceso emitidos antes de ese momento.
-- El middleware compara el `iat` del JWT con esta marca en cada solicitud;
-- los dispositivos con un refresh token vigente obtienen un acceso nuevo.
ALTER TABLE users ADD COLUMN IF NOT EXISTS tokens_validos_desde TIMESTAMPTZ;
