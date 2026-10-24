-- Migración Sprint 2: Esquemas adicionales y soporte de archivado / perfiles / reuniones

-- 1. Columnas adicionales para Perfil de Usuario (BUG-S2-01 / IRL-IAM-US-05)
ALTER TABLE users ADD COLUMN IF NOT EXISTS bio TEXT DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_color VARCHAR(30) DEFAULT '#00E5FF';
ALTER TABLE users ADD COLUMN IF NOT EXISTS status_text TEXT DEFAULT '🟢 En línea';
ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- 2. Columna de Soft-Delete / Archivado para Subgrupos (BUG-S2-06)
ALTER TABLE subgrupos ADD COLUMN IF NOT EXISTS is_archived BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS idx_subgrupos_nodo_archived ON subgrupos(nodo_id, is_archived);

-- 3. Ajuste de Columnas para Reuniones Programadas (BUG-S2-02 / IRL-WKS-US-04)
DO $$ 
BEGIN 
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'reuniones' AND column_name = 'enlace'
    ) THEN 
        ALTER TABLE reuniones ALTER COLUMN enlace DROP NOT NULL;
    END IF;
END $$;
ALTER TABLE reuniones ADD COLUMN IF NOT EXISTS fecha_fin TIMESTAMPTZ;
ALTER TABLE reuniones ADD COLUMN IF NOT EXISTS enlace_reunion TEXT;

-- 4. Registro de última lectura para contador de mensajes no leídos (IRL-WKS-US-03)
ALTER TABLE nodo_miembros ADD COLUMN IF NOT EXISTS last_read_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE subgrupo_miembros ADD COLUMN IF NOT EXISTS last_read_at TIMESTAMPTZ DEFAULT NOW();
CREATE INDEX IF NOT EXISTS idx_nodo_miembros_read ON nodo_miembros(nodo_id, user_id, last_read_at);
CREATE INDEX IF NOT EXISTS idx_subgrupo_miembros_read ON subgrupo_miembros(subgrupo_id, user_id, last_read_at);

