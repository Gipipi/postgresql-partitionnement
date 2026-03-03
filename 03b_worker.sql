-- =============================================================================
-- Worker de chargement — lancé en parallèle par 03_run.sh
-- Variables psql injectées via -v :
--   :worker_id    identifiant du worker (pour les logs)
--   :start_batch  premier batch à traiter (inclus)
--   :end_batch    dernier batch à traiter  (inclus)
--   :batch_size   nombre de lignes par batch
-- =============================================================================
SET search_path = ecommerce;
SET synchronous_commit       = off;
SET work_mem                 = '256MB';
SET session_replication_role = replica;   -- court-circuite les FK triggers

-- Injection des paramètres via set_config : la substitution psql :'var'
-- fonctionne ici (hors bloc dollar-quoté), puis current_setting() les relit
-- dans le DO block sans aucune interpolation côté client.
SELECT set_config('app.worker_id',   :'worker_id',   false);
SELECT set_config('app.start_batch', :'start_batch', false);
SELECT set_config('app.end_batch',   :'end_batch',   false);
SELECT set_config('app.batch_size',  :'batch_size',  false);

DO $body$
DECLARE
    batch_size  INT := current_setting('app.batch_size')::INT;
    start_b     INT := current_setting('app.start_batch')::INT;
    end_b       INT := current_setting('app.end_batch')::INT;
    worker_id   INT := current_setting('app.worker_id')::INT;
    i           INT;
    t_start     TIMESTAMPTZ;
    t_end       TIMESTAMPTZ;
BEGIN
    FOR i IN start_b..end_b LOOP
        t_start := clock_timestamp();

        -- Génération unique → flat via RETURNING → partitioned (pas de relecture disque)
        WITH gen AS (
            SELECT
                (1 + floor(random() * 1_000_000))::BIGINT AS customer_id,
                timestamp '2015-01-01'
                    + (random()^0.7
                       * EXTRACT(EPOCH FROM (timestamp '2025-01-01' - timestamp '2015-01-01'))
                      ) * INTERVAL '1 second'                              AS order_date,
                (ARRAY['pending','processing','shipped','delivered','cancelled'])[1 + floor(random() * 5)::INT]  AS status,
                (random() * 500 + 5)::NUMERIC(12,2)                                                            AS total_amount,
                (ARRAY['FR','DE','GB','ES','IT','BE','NL','PL','PT','SE'])[1 + floor(random() * 10)::INT]       AS country_code
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

        RAISE NOTICE 'Worker % — Batch %/% terminé — durée: %ms',
            worker_id, i, end_b,
            EXTRACT(MILLISECONDS FROM (t_end - t_start))::INT;
    END LOOP;
END;
$body$;
