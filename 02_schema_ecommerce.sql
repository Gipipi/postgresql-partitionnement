-- =============================================================================
-- SCRIPT 1 : Modèle de données E-commerce
-- PostgreSQL 18 — Benchmark Partitionnement
-- =============================================================================

-- Nettoyage préalable
DROP SCHEMA IF EXISTS ecommerce CASCADE;
CREATE SCHEMA ecommerce;
SET search_path = ecommerce;

-- =============================================================================
-- TABLE CLIENTS
-- =============================================================================
CREATE TABLE customers (
    customer_id     BIGSERIAL PRIMARY KEY,
    email           TEXT NOT NULL UNIQUE,
    full_name       TEXT NOT NULL,
    country_code    CHAR(2) NOT NULL DEFAULT 'FR',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- TABLE PRODUITS (référentiel léger)
-- =============================================================================
CREATE TABLE products (
    product_id      BIGSERIAL PRIMARY KEY,
    sku             TEXT NOT NULL UNIQUE,
    name            TEXT NOT NULL,
    category        TEXT NOT NULL,
    price           NUMERIC(10,2) NOT NULL,
    active          BOOLEAN NOT NULL DEFAULT TRUE
);

-- =============================================================================
-- VERSION SANS PARTITIONNEMENT : orders_flat
-- =============================================================================
CREATE TABLE orders_flat (
    order_id        BIGSERIAL PRIMARY KEY,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id),
    order_date      TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('pending','processing','shipped','delivered','cancelled')),
    total_amount    NUMERIC(12,2) NOT NULL,
    country_code    CHAR(2) NOT NULL DEFAULT 'FR'
);

-- Index créés après chargement des données dans 03_data_generation.sql

-- =============================================================================
-- VERSION AVEC PARTITIONNEMENT : orders_partitioned
-- Stratégie : RANGE par mois sur order_date (10 ans = 120 partitions)
-- =============================================================================
CREATE TABLE orders_partitioned (
    order_id        BIGINT NOT NULL,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id),
    order_date      TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('pending','processing','shipped','delivered','cancelled')),
    total_amount    NUMERIC(12,2) NOT NULL,
    country_code    CHAR(2) NOT NULL DEFAULT 'FR',
    PRIMARY KEY (order_id, order_date)   -- la clé de partition DOIT être dans la PK
) PARTITION BY RANGE (order_date);

-- =============================================================================
-- Création des partitions mensuelles : 2015-01 → 2024-12 (10 ans)
-- =============================================================================
DO $$
DECLARE
    yr  INT;
    mo  INT;
    p_start DATE;
    p_end   DATE;
    tname   TEXT;
BEGIN
    FOR yr IN 2015..2024 LOOP
        FOR mo IN 1..12 LOOP
            p_start := make_date(yr, mo, 1);
            p_end   := p_start + INTERVAL '1 month';
            tname   := format('orders_%s_%s', yr, lpad(mo::TEXT, 2, '0'));

            EXECUTE format(
                'CREATE TABLE ecommerce.%I
                 PARTITION OF ecommerce.orders_partitioned
                 FOR VALUES FROM (%L) TO (%L)',
                tname, p_start, p_end
            );

            -- Index créés après chargement des données dans 03_data_generation.sql
        END LOOP;
    END LOOP;
    RAISE NOTICE '120 partitions créées (2015-01 à 2024-12)';
END;
$$;

-- =============================================================================
-- TABLE order_items (commune, référence les deux tables pour le test)
-- =============================================================================
CREATE TABLE order_items_flat (
    item_id         BIGSERIAL PRIMARY KEY,
    order_id        BIGINT NOT NULL,  -- référence orders_flat
    product_id      BIGINT NOT NULL REFERENCES products(product_id),
    quantity        INT NOT NULL DEFAULT 1,
    unit_price      NUMERIC(10,2) NOT NULL
);

CREATE INDEX idx_items_flat_order   ON order_items_flat(order_id);
CREATE INDEX idx_items_flat_product ON order_items_flat(product_id);

-- Vue de vérification du partitionnement
CREATE VIEW partition_sizes AS
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size
FROM pg_tables
WHERE tablename LIKE 'orders_%'
  AND schemaname = 'ecommerce'
ORDER BY tablename;

\echo '✅ Modèle de données créé avec succès'
\echo '   - customers (référentiel)'
\echo '   - products  (référentiel)'
\echo '   - orders_flat (sans partitionnement)'
\echo '   - orders_partitioned (120 partitions mensuelles 2015-2024)'
\echo '   - order_items_flat'
