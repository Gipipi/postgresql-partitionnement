#!/bin/bash
# =============================================================================
# Chargement 100M lignes avec inserts parallèles
# Usage : ./03_run.sh [-h host] [-U user] [-d database] [-j workers]
# =============================================================================
set -euo pipefail

# ---- Valeurs par défaut (surchargeable via variables d'environnement) --------
PGHOST="${PGHOST:-localhost}"
PGUSER="${PGUSER:-postgres}"
PORT=5432
PGDATABASE="${PGDATABASE:-partitionnement}"
PARALLEL=4          # nombre de workers parallèles
TOTAL_BATCHES=100
BATCH_SIZE=1000000

# ---- Parsing des arguments ---------------------------------------------------
while getopts "h:U:d:j:" opt; do
    case $opt in
        h) PGHOST="$OPTARG" ;;
        U) PGUSER="$OPTARG" ;;
        d) PGDATABASE="$OPTARG" ;;
        j) PARALLEL="$OPTARG" ;;
        *) echo "Usage: $0 [-h host] [-U user] [-d database] [-j workers]"; exit 1 ;;
    esac
done

# ---- Validation -------------------------------------------------------------
if (( TOTAL_BATCHES % PARALLEL != 0 )); then
    echo "ERREUR: TOTAL_BATCHES ($TOTAL_BATCHES) doit être divisible par -j ($PARALLEL)"
    exit 1
fi

BATCHES_PER_WORKER=$(( TOTAL_BATCHES / PARALLEL ))
TOTAL_ROWS=$(( TOTAL_BATCHES * BATCH_SIZE ))
DIR="$(cd "$(dirname "$0")" && pwd)"
PSQL="psql -h $PGHOST -U $PGUSER -d $PGDATABASE -p $PORT"

echo "======================================================================="
echo " Chargement $TOTAL_ROWS lignes — $PARALLEL workers × $BATCHES_PER_WORKER batches × $BATCH_SIZE"
echo " Serveur : $PGHOST  Base : $PGDATABASE  User : $PGUSER"
echo "======================================================================="

# ---- Phase 1 : Setup --------------------------------------------------------
echo ""
echo "⏳ Phase 1/3 : Setup (UNLOGGED, autovacuum off, clients, produits)..."
T0=$(date +%s)
$PSQL -f "$DIR/03a_setup.sql"
echo "✅ Setup terminé ($(( $(date +%s) - T0 ))s)"

# ---- Phase 2 : Inserts parallèles -------------------------------------------
echo ""
echo "⏳ Phase 2/3 : Inserts parallèles ($PARALLEL workers)..."
T1=$(date +%s)

# run_worker : exécute psql dans un sous-shell, journalise dans un fichier
# temporaire, puis affiche avec le préfixe [wN]. Le code de retour est celui
# de psql (pas de sed), ce qui permet au shell parent de détecter les erreurs.
run_worker() {
    local wid=$1 start=$2 end=$3
    local log
    log=$(mktemp /tmp/pg_worker_XXXXXX.log)
    $PSQL \
        -v worker_id="$wid" \
        -v start_batch="$start" \
        -v end_batch="$end" \
        -v batch_size="$BATCH_SIZE" \
        -f "$DIR/03b_worker.sql" \
        >"$log" 2>&1
    local rc=$?
    sed "s/^/[w${wid}] /" "$log"
    rm -f "$log"
    return $rc
}

pids=()
for i in $(seq 1 "$PARALLEL"); do
    start=$(( (i-1) * BATCHES_PER_WORKER + 1 ))
    end=$(( i * BATCHES_PER_WORKER ))
    echo "  → Worker $i : batches $start → $end"
    run_worker "$i" "$start" "$end" &
    pids+=($!)
done

# Attendre tous les workers
failed=0
for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
        echo "ERREUR: worker $((i+1)) a échoué"
        failed=1
    fi
done
[[ $failed -eq 1 ]] && { echo "Abandon : un ou plusieurs workers ont échoué"; exit 1; }

echo "✅ Tous les workers ont terminé ($(( $(date +%s) - T1 ))s)"

# ---- Phase 3 : Teardown parallèle (LOGGED + autovacuum + index) -------------
#
# Stratégie :
#   3a. orders_flat : SET LOGGED + autovacuum (séquentiel, table unique)
#   3b. Partitions  : N workers en parallèle, chacun gère une tranche de 120/N
#                     partitions (SET LOGGED + autovacuum + 2 index)
#                     + les 3 premiers workers créent chacun 1 index orders_flat
#   3c. ANALYZE     : orders_flat et orders_partitioned en parallèle
#   3d. Vérification finale
#
PARTITIONS=120
FLAT_INDEXES=("customer_id idx_orders_flat_customer"
              "order_date  idx_orders_flat_date"
              "status      idx_orders_flat_status")

run_phase3_worker() {
    local wid=$1 part_start=$2 part_end=$3 flat_col=$4 flat_idx=$5
    local log
    log=$(mktemp /tmp/pg_phase3_XXXXXX.log)
    $PSQL \
        -v worker_id="$wid" \
        -v part_start="$part_start" \
        -v part_end="$part_end" \
        -v flat_col="$flat_col" \
        -v flat_idx="$flat_idx" \
        -f "$DIR/03d_phase3_worker.sql" \
        >"$log" 2>&1
    local rc=$?
    sed "s/^/[p$wid] /" "$log"
    rm -f "$log"
    return $rc
}

echo ""
echo "⏳ Phase 3a/4 : orders_flat → LOGGED + autovacuum..."
T2=$(date +%s)
$PSQL -f "$DIR/03c_teardown.sql"
echo "✅ orders_flat finalisé ($(( $(date +%s) - T2 ))s)"

echo ""
echo "⏳ Phase 3b/4 : Partitions → LOGGED + index ($PARALLEL workers en parallèle)..."
T3=$(date +%s)

# Répartition : ceiling(120 / PARALLEL) partitions par worker
PARTS_PER_WORKER=$(( (PARTITIONS + PARALLEL - 1) / PARALLEL ))

pids=()
for i in $(seq 1 "$PARALLEL"); do
    part_start=$(( (i-1) * PARTS_PER_WORKER + 1 ))
    part_end=$(( i * PARTS_PER_WORKER ))
    (( part_end > PARTITIONS )) && part_end=$PARTITIONS

    # Répartir les 3 index orders_flat sur les 3 premiers workers
    flat_col=""
    flat_idx=""
    idx_pos=$(( i - 1 ))
    if (( idx_pos < 3 )); then
        read -r flat_col flat_idx <<< "${FLAT_INDEXES[$idx_pos]}"
    fi

    echo "  → Worker $i : partitions $part_start → $part_end${flat_col:+ + index orders_flat($flat_col)}"
    run_phase3_worker "$i" "$part_start" "$part_end" "$flat_col" "$flat_idx" &
    pids+=($!)
done

failed=0
for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
        echo "ERREUR: phase3 worker $((i+1)) a échoué"
        failed=1
    fi
done
[[ $failed -eq 1 ]] && { echo "Abandon"; exit 1; }
echo "✅ Partitions finalisées ($(( $(date +%s) - T3 ))s)"

echo ""
echo "⏳ Phase 3c/4 : ANALYZE en parallèle..."
T4=$(date +%s)
$PSQL -c "SET search_path=ecommerce; ANALYZE orders_flat"        >/dev/null &
$PSQL -c "SET search_path=ecommerce; ANALYZE orders_partitioned" >/dev/null &
wait
echo "✅ ANALYZE terminé ($(( $(date +%s) - T4 ))s)"

echo ""
echo "⏳ Phase 3d/4 : Vérification..."
$PSQL -f "$DIR/03e_finalize.sql"

echo ""
echo "======================================================================="
echo " Durée totale : $(( $(date +%s) - T0 ))s"
echo "======================================================================="
