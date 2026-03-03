-- =============================================================================
-- SCRIPT 2 : Génération de 100 millions de lignes (version optimisée)
-- Durée estimée : 3-8 min selon les ressources disponibles
-- =============================================================================
SET search_path = ecommerce;

-- =============================================================================
-- OPTIMISATION 1 : Paramètres de session pour le bulk load
-- Note: checkpoint_completion_target et max_wal_size sont des paramètres
-- serveur (postgresql.conf / ALTER SYSTEM), non modifiables en session.
-- =============================================================================
SET synchronous_commit   = off;     -- pas d'attente de flush WAL à chaque commit
SET work_mem             = '256MB'; -- tri/hash en mémoire
SET maintenance_work_mem = '1GB';   -- pour les CREATE INDEX finaux

-- =============================================================================
-- OPTIMISATION 2 : Tables UNLOGGED → élimine le WAL (~3-5× plus rapide)
-- orders_partitioned étant partitionnée, il faut boucler sur les feuilles
-- =============================================================================
ALTER TABLE orders_flat SET UNLOGGED;
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT inhrelid::regclass AS partition_name
        FROM pg_inherits
        WHERE inhparent = 'ecommerce.orders_partitioned'::regclass
    LOOP
        EXECUTE format('ALTER TABLE %s SET UNLOGGED', r.partition_name);
    END LOOP;
    RAISE NOTICE '120 partitions passées en UNLOGGED';
END;
$$;

-- =============================================================================
-- OPTIMISATION 4 : Désactiver les FK et autovacuum pendant le chargement
-- session_replication_role = replica court-circuite tous les triggers de FK
-- (sûr ici car les customer_id 1-1M seront tous présents)
-- =============================================================================
SET session_replication_role = replica;

ALTER TABLE orders_flat SET (autovacuum_enabled = false);
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT inhrelid::regclass AS partition_name
        FROM pg_inherits
        WHERE inhparent = 'ecommerce.orders_partitioned'::regclass
    LOOP
        EXECUTE format('ALTER TABLE %s SET (autovacuum_enabled = false)', r.partition_name);
    END LOOP;
END;
$$;

-- =============================================================================
-- ÉTAPE 1 : Clients (1 million)
-- =============================================================================
\echo '⏳ Génération des clients...'

INSERT INTO customers (email, full_name, country_code, created_at)
SELECT
    'user_' || i || '@example.com',
    'Customer ' || i,
    (ARRAY['FR','DE','GB','ES','IT','BE','NL','PL','PT','SE'])[1 + floor(random() * 10)::INT],
    NOW() - (random() * INTERVAL '10 years')
FROM generate_series(1, 1_000_000) AS s(i);

\echo '✅ 1 000 000 clients insérés'

-- =============================================================================
-- ÉTAPE 2 : Produits (500)
-- =============================================================================
INSERT INTO products (sku, name, category, price)
SELECT
    'SKU-' || lpad(i::TEXT, 5, '0'),
    'Product ' || i,
    (ARRAY['Electronics','Clothing','Books','Home','Sports','Beauty','Food','Toys','Garden','Auto'])[1 + floor(random() * 10)::INT],
    (random() * 990 + 10)::NUMERIC(10,2)
FROM generate_series(1, 500) AS s(i);

\echo '✅ 500 produits insérés'

-- =============================================================================
-- ÉTAPE 3 : Commandes — 100M lignes, en batches de 1M
--
-- OPTIMISATION CLÉ : INSERT ... RETURNING CTE
--   → les données sont générées UNE seule fois en mémoire
--   → la clause RETURNING alimente orders_partitioned directement
--   → plus de relecture sur disque depuis orders_flat
-- =============================================================================
\echo '⏳ Génération des 100M commandes (batches de 1M)...'

DO $$
DECLARE
    batch_size  INT := 1_000_000;
    total_rows  INT := 100_000_000;
    batches     INT := total_rows / batch_size;
    i           INT;
    t_start     TIMESTAMPTZ;
    t_end       TIMESTAMPTZ;
BEGIN
    FOR i IN 1..batches LOOP
        t_start := clock_timestamp();

        -- Génération unique → flat via RETURNING → partitioned, sans relecture disque
        WITH gen AS (
            SELECT
                (1 + floor(random() * 1_000_000))::BIGINT AS customer_id,
                timestamp '2015-01-01'
                    + (random()^0.7
                       * EXTRACT(EPOCH FROM (timestamp '2025-01-01' - timestamp '2015-01-01'))
                      ) * INTERVAL '1 second'                              AS order_date,
                (ARRAY['pending','processing','shipped','delivered','cancelled'])[1 + floor(random() * 5)::INT] AS status,
                (random() * 500 + 5)::NUMERIC(12,2)                       AS total_amount,
                (ARRAY['FR','DE','GB','ES','IT','BE','NL','PL','PT','SE'])[1 + floor(random() * 10)::INT] AS country_code
            FROM generate_series(1, batch_size)
        ),
        ins_flat AS (
            INSERT INTO ecommerce.orders_flat
                (customer_id, order_date, status, total_amount, country_code)
            SELECT customer_id, order_date, status, total_amount, country_code
            FROM gen
            RETURNING order_id, customer_id, order_date, status, total_amount, country_code
        )
        INSERT INTO ecommerce.orders_partitioned
            (order_id, customer_id, order_date, status, total_amount, country_code)
        SELECT order_id, customer_id, order_date, status, total_amount, country_code
        FROM ins_flat;

        t_end := clock_timestamp();

        RAISE NOTICE 'Batch %/% terminé — % lignes insérées — durée: %ms',
            i, batches, batch_size,
            EXTRACT(MILLISECONDS FROM (t_end - t_start))::INT;
    END LOOP;
END;
$$;

-- =============================================================================
-- ÉTAPE 4 : Remettre les tables en LOGGED + réactiver FK et autovacuum
-- =============================================================================
SET session_replication_role = DEFAULT;

ALTER TABLE orders_flat SET LOGGED;
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT inhrelid::regclass AS partition_name
        FROM pg_inherits
        WHERE inhparent = 'ecommerce.orders_partitioned'::regclass
    LOOP
        EXECUTE format('ALTER TABLE %s SET LOGGED', r.partition_name);
    END LOOP;
    RAISE NOTICE '120 partitions repassées en LOGGED';
END;
$$;

ALTER TABLE orders_flat SET (autovacuum_enabled = true);
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT inhrelid::regclass AS partition_name
        FROM pg_inherits
        WHERE inhparent = 'ecommerce.orders_partitioned'::regclass
    LOOP
        EXECUTE format('ALTER TABLE %s SET (autovacuum_enabled = true)', r.partition_name);
    END LOOP;
END;
$$;

-- =============================================================================
-- ÉTAPE 5 : Créer les index (une seule passe sur données statiques, optimal)
-- =============================================================================
\echo '⏳ Création des index sur orders_flat...'
CREATE INDEX idx_orders_flat_customer ON ecommerce.orders_flat(customer_id);
CREATE INDEX idx_orders_flat_date     ON ecommerce.orders_flat(order_date);
CREATE INDEX idx_orders_flat_status   ON ecommerce.orders_flat(status);

\echo '⏳ Création des index sur les partitions...'
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT inhrelid::regclass AS pname, inhrelid AS poid
        FROM pg_inherits
        WHERE inhparent = 'ecommerce.orders_partitioned'::regclass
        ORDER BY inhrelid
    LOOP
        EXECUTE format('CREATE INDEX ON %s (customer_id)', r.pname);
        EXECUTE format('CREATE INDEX ON %s (status)',      r.pname);
    END LOOP;
    RAISE NOTICE '240 index de partitions créés';
END;
$$;

-- =============================================================================
-- ÉTAPE 6 : ANALYZE
-- =============================================================================
\echo '⏳ ANALYZE en cours...'
ANALYZE orders_flat;
ANALYZE orders_partitioned;

-- =============================================================================
-- Vérification du chargement
-- =============================================================================
SELECT
    'orders_flat'         AS table_name,
    count(*)              AS row_count,
    min(order_date)       AS min_date,
    max(order_date)       AS max_date,
    pg_size_pretty(pg_total_relation_size('ecommerce.orders_flat')) AS total_size
FROM ecommerce.orders_flat

UNION ALL

SELECT
    'orders_partitioned',
    count(*),
    min(order_date),
    max(order_date),
    pg_size_pretty(pg_total_relation_size('ecommerce.orders_partitioned'))
FROM ecommerce.orders_partitioned;

-- Taille des 5 plus grosses partitions
SELECT tablename, total_size
FROM ecommerce.partition_sizes
ORDER BY pg_total_relation_size('ecommerce.'||tablename) DESC
LIMIT 5;

\echo '✅ Chargement terminé !'
