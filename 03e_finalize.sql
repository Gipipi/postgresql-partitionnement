-- =============================================================================
-- Phase 3d : Vérification finale
-- =============================================================================
SET search_path = ecommerce;

SELECT
    'orders_flat'        AS table_name,
    count(*)             AS row_count,
    min(order_date)      AS min_date,
    max(order_date)      AS max_date,
    pg_size_pretty(pg_total_relation_size('ecommerce.orders_flat')) AS total_size
FROM ecommerce.orders_flat

UNION ALL

SELECT
    'orders_partitioned',
    count(*),
    min(order_date),
    max(order_date),
    -- pg_total_relation_size sur la table parente retourne 0 (pas de stockage direct).
    -- On somme explicitement toutes les partitions feuilles.
    pg_size_pretty((
        SELECT COALESCE(SUM(pg_total_relation_size(inhrelid)), 0)
        FROM pg_inherits
        WHERE inhparent = 'ecommerce.orders_partitioned'::regclass
    ))
FROM ecommerce.orders_partitioned;

-- Top 5 des partitions les plus volumineuses
SELECT tablename, total_size
FROM ecommerce.partition_sizes
WHERE tablename LIKE 'orders_2%'
ORDER BY pg_total_relation_size('ecommerce.'||tablename) DESC
LIMIT 5;

\echo '✅ Chargement terminé !'
