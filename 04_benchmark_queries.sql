-- =============================================================================
-- SCRIPT 3 : Benchmark — Comparaison Sans vs Avec Partitionnement
-- Exécuter chaque requête avec EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
-- =============================================================================
SET search_path = ecommerce;

-- Active le timing pour mesurer la durée
\timing on

-- Active les statistiques détaillées du planner
SET enable_partitionwise_join      = on;
SET enable_partitionwise_aggregate = on;

-- Désactive le pager pour voir les résultats complets sans pagination
\pset pager off

-- =============================================================================
-- 🔍 TEST 1 : Lecture d'un mois précis (le cas idéal du partition pruning)
-- =============================================================================
-- Attendu : la version partitionnée ne lit qu'1/120 des données

\echo ''
\echo '=========================================='
\echo 'TEST 1 : SELECT sur 1 mois (Janvier 2023)'
\echo '=========================================='

\echo '--- Sans partitionnement ---'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT count(*), sum(total_amount)
FROM orders_flat
WHERE order_date >= '2023-01-01'
  AND order_date <  '2023-02-01';

\echo '--- Avec partitionnement ---'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT count(*), sum(total_amount)
FROM orders_partitioned
WHERE order_date >= '2023-01-01'
  AND order_date <  '2023-02-01';

-- =============================================================================
-- 🔍 TEST 2 : Requête sur 1 trimestre (pruning sur 3 partitions)
-- =============================================================================
\echo ''
\echo '=========================================='
\echo 'TEST 2 : SELECT sur 1 trimestre (Q4 2023)'
\echo '=========================================='

\echo '--- Sans partitionnement ---'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    status,
    count(*)           AS nb_orders,
    sum(total_amount)  AS revenue,
    avg(total_amount)  AS avg_basket
FROM orders_flat
WHERE order_date >= '2023-10-01'
  AND order_date <  '2024-01-01'
GROUP BY status
ORDER BY nb_orders DESC;

\echo '--- Avec partitionnement ---'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    status,
    count(*)           AS nb_orders,
    sum(total_amount)  AS revenue,
    avg(total_amount)  AS avg_basket
FROM orders_partitioned
WHERE order_date >= '2023-10-01'
  AND order_date <  '2024-01-01'
GROUP BY status
ORDER BY nb_orders DESC;

-- =============================================================================
-- 🔍 TEST 3 : Lookup client sur une période récente
-- =============================================================================
\echo ''
\echo '================================================='
\echo 'TEST 3 : Commandes d un client (12 derniers mois)'
\echo '================================================='

\echo '--- Sans partitionnement ---'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT order_id, order_date, status, total_amount
FROM orders_flat
WHERE customer_id = 42
  AND order_date >= NOW() - INTERVAL '12 months'
ORDER BY order_date DESC;

\echo '--- Avec partitionnement ---'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT order_id, order_date, status, total_amount
FROM orders_partitioned
WHERE customer_id = 42
  AND order_date >= NOW() - INTERVAL '12 months'
ORDER BY order_date DESC;

-- =============================================================================
-- 🔍 TEST 4 : Agrégat annuel (full scan)
-- Ici le partitionnement aide moins mais le parallélisme par partition compense
-- =============================================================================
\echo ''
\echo '================================================='
\echo 'TEST 4 : Chiffre affaires par année (full scan)'
\echo '================================================='

\echo '--- Sans partitionnement ---'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    date_trunc('year', order_date) AS year,
    count(*)                        AS nb_orders,
    sum(total_amount)               AS total_revenue
FROM orders_flat
GROUP BY 1
ORDER BY 1;

\echo '--- Avec partitionnement ---'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    date_trunc('year', order_date) AS year,
    count(*)                        AS nb_orders,
    sum(total_amount)               AS total_revenue
FROM orders_partitioned
GROUP BY 1
ORDER BY 1;

-- =============================================================================
-- 🔍 TEST 5 : UPDATE sur une période (maintenance courante)
-- =============================================================================
\echo ''
\echo '================================================='
\echo 'TEST 5 : UPDATE statut commandes Janvier 2022'
\echo '================================================='

BEGIN;

\echo '--- Sans partitionnement ---'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
UPDATE orders_flat
SET status = 'delivered'
WHERE order_date >= '2022-01-01'
  AND order_date <  '2022-02-01'
  AND status = 'shipped';

ROLLBACK;

BEGIN;

\echo '--- Avec partitionnement ---'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
UPDATE orders_partitioned
SET status = 'delivered'
WHERE order_date >= '2022-01-01'
  AND order_date <  '2022-02-01'
  AND status = 'shipped';

ROLLBACK;

-- =============================================================================
-- 🔍 TEST 6 : Maintenance — Archivage (le vrai avantage du partitionnement)
-- =============================================================================
\echo ''
\echo '================================================='
\echo 'TEST 6 : Suppression de données anciennes'
\echo '================================================='

\echo '--- Sans partitionnement : DELETE coûteux ---'
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
DELETE FROM orders_flat
WHERE order_date < '2016-01-01';

-- ROLLBACK pour ne pas perdre les données
ROLLBACK;

\echo '--- Avec partitionnement : DETACH + DROP instantané ---'
\echo '(simulation, ne pas exécuter en prod sans vérification)'
-- ALTER TABLE orders_partitioned DETACH PARTITION orders_2015_01 CONCURRENTLY;
-- ALTER TABLE orders_partitioned DETACH PARTITION orders_2015_02 CONCURRENTLY;
-- ... puis DROP TABLE orders_2015_01; etc.
-- => Aucun scan de données, opération quasi-instantanée !

-- =============================================================================
-- 📊 RÉSUMÉ : Comparaison des tailles
-- =============================================================================
\echo ''
\echo '================================================='
\echo 'RÉSUMÉ : Tailles des tables'
\echo '================================================='

SELECT
    'orders_flat (sans)' AS description,
    pg_size_pretty(pg_relation_size('ecommerce.orders_flat'))       AS heap_size,
    pg_size_pretty(pg_indexes_size('ecommerce.orders_flat'))        AS index_size,
    pg_size_pretty(pg_total_relation_size('ecommerce.orders_flat')) AS total_size

UNION ALL

-- Table mère : toujours 0, il faut agréger les partitions filles via pg_inherits
SELECT
    'orders_partitioned (avec)' AS description,
    pg_size_pretty(sum(pg_relation_size(inhrelid))),
    pg_size_pretty(sum(pg_indexes_size(inhrelid))),
    pg_size_pretty(sum(pg_total_relation_size(inhrelid)))
FROM pg_inherits
WHERE inhparent = 'ecommerce.orders_partitioned'::regclass;

-- Vérifier le partition pruning (nb de partitions réellement lues)
\echo ''
\echo '📌 Vérification du partition pruning actif :'
SHOW enable_partition_pruning;
