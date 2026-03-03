-- =============================================================================
-- Phase 1/3 : Setup du chargement en masse
-- =============================================================================
SET search_path = ecommerce;
SET synchronous_commit   = off;
SET work_mem             = '256MB';
SET maintenance_work_mem = '1GB';

-- Tables UNLOGGED → élimine le WAL
ALTER TABLE orders_flat SET UNLOGGED;
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT inhrelid::regclass AS p
        FROM pg_inherits
        WHERE inhparent = 'ecommerce.orders_partitioned'::regclass
    LOOP
        EXECUTE format('ALTER TABLE %s SET UNLOGGED', r.p);
    END LOOP;
    RAISE NOTICE '120 partitions → UNLOGGED';
END;
$$;

-- Autovacuum off
ALTER TABLE orders_flat SET (autovacuum_enabled = false);
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT inhrelid::regclass AS p
        FROM pg_inherits
        WHERE inhparent = 'ecommerce.orders_partitioned'::regclass
    LOOP
        EXECUTE format('ALTER TABLE %s SET (autovacuum_enabled = false)', r.p);
    END LOOP;
END;
$$;

-- =============================================================================
-- Clients (1 million)
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
-- Produits (500)
-- =============================================================================
INSERT INTO products (sku, name, category, price)
SELECT
    'SKU-' || lpad(i::TEXT, 5, '0'),
    'Product ' || i,
    (ARRAY['Electronics','Clothing','Books','Home','Sports','Beauty','Food','Toys','Garden','Auto'])[1 + floor(random() * 10)::INT],
    (random() * 990 + 10)::NUMERIC(10,2)
FROM generate_series(1, 500) AS s(i);
\echo '✅ 500 produits insérés'
