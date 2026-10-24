-- Run only against a disposable database with psql -v ON_ERROR_STOP=1 -f ...
-- All fixtures and cleanup are rolled back, including on connection closure.
BEGIN;
DO $$
BEGIN
    IF current_database() NOT LIKE 'ironlink%test' THEN
        RAISE EXCEPTION 'This regression requires a disposable ironlink test database';
    END IF;
END $$;

CREATE TEMP TABLE migration_fixture AS
SELECT gen_random_uuid() AS owner_id, gen_random_uuid() AS member_id,
       gen_random_uuid() AS orphan_id, gen_random_uuid() AS node_id,
       gen_random_uuid() AS subgroup_id;

INSERT INTO users (id, name, email, password, telefono, estado)
SELECT ids.id, 'Migration QA', ids.id::text || '@example.invalid',
       'test-only', ids.id::text, 'ACTIVE'
FROM migration_fixture f
CROSS JOIN LATERAL (VALUES (f.owner_id), (f.member_id), (f.orphan_id)) AS ids(id);

INSERT INTO nodos (id, nombre, token_acceso, creador_id)
SELECT node_id, 'Migration QA', replace(node_id::text, '-', ''), owner_id
FROM migration_fixture;
INSERT INTO nodo_miembros (nodo_id, user_id)
SELECT f.node_id, ids.id FROM migration_fixture f
CROSS JOIN LATERAL (VALUES (f.owner_id), (f.member_id)) AS ids(id);
INSERT INTO subgrupos (id, nodo_id, nombre, es_privado, creado_por)
SELECT subgroup_id, node_id, 'Private QA', true, owner_id FROM migration_fixture;
INSERT INTO subgrupo_miembros (subgrupo_id, user_id)
SELECT f.subgroup_id, ids.id FROM migration_fixture f
CROSS JOIN LATERAL (VALUES (f.owner_id), (f.member_id), (f.orphan_id)) AS ids(id);

\ir ../migrations/013_orphan_subgroup_members.sql
DO $$
BEGIN
    ASSERT NOT EXISTS (
        SELECT 1 FROM subgrupo_miembros sm JOIN migration_fixture f
        ON sm.subgrupo_id=f.subgroup_id AND sm.user_id=f.orphan_id
    ), 'Orphan private membership must be removed';
    ASSERT (SELECT COUNT(*) FROM subgrupo_miembros sm JOIN migration_fixture f
            ON sm.subgrupo_id=f.subgroup_id) = 2,
           'Valid private memberships must remain';
END $$;

-- A second application must preserve the same valid memberships.
\ir ../migrations/013_orphan_subgroup_members.sql
DO $$
BEGIN
    ASSERT (SELECT COUNT(*) FROM subgrupo_miembros sm JOIN migration_fixture f
            ON sm.subgrupo_id=f.subgroup_id) = 2,
           'Cleanup must be idempotent';
END $$;
ROLLBACK;
\echo 'Migration 013 regression: passed (fixtures rolled back)'
