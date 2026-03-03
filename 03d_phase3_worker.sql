-- =============================================================================
-- Worker Phase 3 — lancé en parallèle par 03_run.sh
-- Pour chaque partition de sa tranche :
--   1. autovacuum = true (restauration)
--   2. CREATE INDEX customer_id
--   3. CREATE INDEX status
-- + optionnellement un index sur orders_flat (réparti sur les premiers workers)
--
-- NOTE : SET LOGGED volontairement omis (voir 03c_teardown.sql)
--
-- Variables psql injectées via -v :
--   :worker_id   identifiant du worker (logs)
--   :part_start  premier rang de partition à traiter (1-based, dans l'ordre pg_inherits)
--   :part_end    dernier rang de partition à traiter (inclus)
--   :flat_col    colonne à indexer sur orders_flat (ex: 'customer_id'), ou ''
--   :flat_idx    nom de l'index orders_flat correspondant, ou ''
-- =============================================================================
SET search_path = ecommerce;
SET maintenance_work_mem = '512MB';

SELECT set_config('app.worker_id',  :'worker_id',  false);
SELECT set_config('app.part_start', :'part_start', false);
SELECT set_config('app.part_end',   :'part_end',   false);
SELECT set_config('app.flat_col',   :'flat_col',   false);
SELECT set_config('app.flat_idx',   :'flat_idx',   false);

DO $body$
DECLARE
    worker_id  INT  := current_setting('app.worker_id')::INT;
    part_start INT  := current_setting('app.part_start')::INT;
    part_end   INT  := current_setting('app.part_end')::INT;
    flat_col   TEXT := current_setting('app.flat_col');
    flat_idx   TEXT := current_setting('app.flat_idx');
    r          RECORD;
    row_num    INT := 0;
BEGIN
    -- Index sur orders_flat (réparti : chaque worker traite une colonne)
    IF flat_col <> '' THEN
        EXECUTE format('CREATE INDEX %I ON ecommerce.orders_flat (%I)', flat_idx, flat_col);
        -- En PL/pgSQL RAISE NOTICE, % est le seul marqueur (pas %s)
        RAISE NOTICE 'Worker % — Index orders_flat(%) créé', worker_id, flat_col;
    END IF;

    -- autovacuum + 2 index pour chaque partition de la tranche
    FOR r IN
        SELECT inhrelid::regclass AS p
        FROM pg_inherits
        WHERE inhparent = 'ecommerce.orders_partitioned'::regclass
        ORDER BY inhrelid
    LOOP
        row_num := row_num + 1;
        CONTINUE WHEN row_num < part_start OR row_num > part_end;

        EXECUTE format('ALTER TABLE %s SET (autovacuum_enabled = true)', r.p);
        EXECUTE format('CREATE INDEX ON %s (customer_id)',               r.p);
        EXECUTE format('CREATE INDEX ON %s (status)',                    r.p);
    END LOOP;

    RAISE NOTICE 'Worker % — Partitions % → % finalisées', worker_id, part_start, part_end;
END;
$body$;
