-- Auditoría: intentos fallidos por código de verificación o recuperación.
-- Al quinto fallo el código se invalida y hay que pedir otro, lo que impide
-- probar las 10^6 combinaciones de un código de 6 dígitos.
ALTER TABLE verification_tokens ADD COLUMN IF NOT EXISTS intentos SMALLINT NOT NULL DEFAULT 0;
