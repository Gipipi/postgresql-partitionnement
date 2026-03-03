-- =============================================================================
-- Phase 3a : Teardown de orders_flat
-- NOTE : SET LOGGED est volontairement omis.
--   ALTER TABLE SET LOGGED réécrit toute la table dans le WAL en une seule
--   passe (6 Go → plusieurs heures sur disque ordinaire). Pour un benchmark
--   de queries en lecture, les tables UNLOGGED sont équivalentes en performance.
--   Si vous avez besoin de durabilité, exécutez manuellement :
--     ALTER TABLE ecommerce.orders_flat SET LOGGED;
-- =============================================================================
SET search_path = ecommerce;

ALTER TABLE orders_flat SET (autovacuum_enabled = true);
