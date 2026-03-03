# Benchmark Partitionnement PostgreSQL 18
## Guide d'exécution complet

---

## Prérequis

- Cluster PostgreSQL 18 accessible
- Client `psql` et `bash` installés
- ~25 GB d'espace disque libre (tables UNLOGGED, sans WAL overhead)

---

## Structure des fichiers

```
02_schema_ecommerce.sql       DDL : tables, partitions (sans index)
03_run.sh                     Chargement parallèle — script principal
  ├── 03a_setup.sql             Phase 1 : UNLOGGED, autovacuum off, clients, produits
  ├── 03b_worker.sql            Phase 2 : worker d'insertion (lancé N fois en parallèle)
  ├── 03c_teardown.sql          Phase 3a: autovacuum restauré sur orders_flat
  ├── 03d_phase3_worker.sql     Phase 3b: autovacuum + index par tranche de partitions
  └── 03e_finalize.sql          Phase 3d: vérification finale
03_data_generation.sql        Chargement mono-session (fallback, non recommandé)
04_benchmark_queries.sql      6 tests comparatifs avec EXPLAIN ANALYZE
01_partitioning_concepts.md   Documentation théorique
```

---

## Ordre d'exécution

### 0. Créer la base de données

La base doit exister avant toute exécution de script :

```bash
psql -h <SERVEUR_IP> -p 5432 -U postgres \
  -c "CREATE DATABASE partitionnement;"
```

---

### 1. Créer le schéma

```bash
psql -h <SERVEUR_IP> -p 5432 -U postgres -d partitionnement \
  -f 02_schema_ecommerce.sql
```

Vérification :
```sql
SELECT count(*) FROM pg_tables
WHERE tablename LIKE 'orders_2%' AND schemaname = 'ecommerce';
-- Attendu : 120
```

> Les index ne sont **pas** créés ici — ils le sont après le chargement
> des données, en une seule passe sur des données statiques (beaucoup plus rapide).

---

### 2. Charger les données (100M lignes)

```bash
chmod +x 03_run.sh
./03_run.sh
```

Options disponibles :

| Option | Défaut | Description |
|--------|--------|-------------|
| `-h`   | `localhost` | Hôte PostgreSQL |
| `-U`   | `postgres`  | Utilisateur |
| `-d`   | `partitionnement` | Base de données |
| `-j`   | `4`         | Nombre de workers parallèles |

Exemple avec paramètres explicites :
```bash
./03_run.sh -h 192.168.1.10 -U postgres -d partitionnement -j 4
```

> **Contrainte** : le nombre de workers (`-j`) doit diviser 100 exactement.
> Valeurs valides : 1, 2, 4, 5, 10, 20, 25, 50, 100.

#### Phases du chargement

```
Phase 1   Setup         UNLOGGED + autovacuum off + 1M clients + 500 produits    ~10s
Phase 2   Inserts       4 workers × 25 batches × 1M lignes (CTE INSERT+RETURNING) ~2-5 min
Phase 3a  Teardown      autovacuum restauré sur orders_flat                        ~1s
Phase 3b  Index         4 workers : 240 index de partitions + 3 index orders_flat  ~2-5 min
Phase 3c  ANALYZE       orders_flat et orders_partitioned en parallèle             ~1-2 min
Phase 3d  Vérification  Comptage et tailles                                        ~30s
```

#### Optimisations intégrées

| Technique | Gain | Détail |
|-----------|------|--------|
| Tables UNLOGGED | ~3-5× | Élimine l'écriture WAL pendant le chargement |
| INSERT … RETURNING CTE | ~30% | Les données sont générées une seule fois en mémoire et alimentent les deux tables sans relecture disque |
| `session_replication_role = replica` | ~10% | Court-circuite les 100M vérifications de FK |
| Indexes créés après coup | ~20% | Une seule passe B-tree sur données statiques |
| Inserts parallèles (Phase 2) | ~2-3× | N sessions psql indépendantes, séquences thread-safe |
| Index parallèles (Phase 3b) | ~N× | Partitions indépendantes, CREATE INDEX sans conflit |
| ANALYZE parallèle (Phase 3c) | ~2× | Les deux tables simultanément |

#### Note sur UNLOGGED

Les tables restent **UNLOGGED** après le chargement. Pour des requêtes de lecture
(le but de ce benchmark), cela n'a aucun impact sur les performances. L'absence
de WAL lors du chargement évite plusieurs heures d'écriture (`ALTER TABLE SET LOGGED`
sur 6 Go déclenche une réécriture complète dans le WAL).

Pour rétablir la durabilité si nécessaire :
```sql
ALTER TABLE ecommerce.orders_flat SET LOGGED;
-- puis pour chaque partition :
DO $$ DECLARE r RECORD; BEGIN
    FOR r IN SELECT inhrelid::regclass AS p FROM pg_inherits
             WHERE inhparent = 'ecommerce.orders_partitioned'::regclass
    LOOP EXECUTE format('ALTER TABLE %s SET LOGGED', r.p); END LOOP;
END; $$;
```

---

### 3. Lancer le benchmark

```bash
psql -h <SERVEUR_IP> -p 5432 -U postgres -d partitionnement \
  -f 04_benchmark_queries.sql 2>&1 | tee resultats_benchmark.txt
```

---

## Observation durant les EXPLAIN ANALYZE

### Partition Pruning (Tests 1 & 2)

**Sans partitionnement :**
```
Seq Scan on orders_flat
   rows=100000000   ← scanne TOUT
   Buffers: shared hit=XXXXX
```

**Avec partitionnement :**
```
Append
  -> Seq Scan on orders_2023_01   ← 1 seule partition sur 120
     rows=833000
     Buffers: shared hit=XXX      ← 120× moins de buffers
```

### Index Bitmap Scan (Test 3)

Avec la clé de partition dans le WHERE, PostgreSQL utilise les index
locaux de chaque partition — plus petits, moins de niveaux B-tree à traverser.

### Maintenance (Test 6)

| Opération | Sans partition | Avec partition |
|---|---|---|
| Supprimer 1 mois | DELETE → scan complet + VACUUM | DETACH PARTITION + DROP → quasi-instantané |
| Archiver 1 an | Plusieurs heures | Quelques secondes |

---

## Interpréter les résultats

### Métriques clés dans EXPLAIN ANALYZE

```
Execution Time: 4523 ms          ← durée totale
Buffers: shared hit=150000       ← pages lues du cache
         shared read=80000       ← pages lues du disque (coûteux)
Rows Removed by Filter: 9900000  ← lignes scannées inutilement
```

**Plus les `shared read` sont bas, mieux c'est. donc modifier le SHARED_BUFFERS pour tester les temps de réponses**

### Ratio de pruning attendu

Pour une requête sur 1 mois / 10 ans :
- Ratio théorique : 1/120 = 0.83% des données scannées
- En pratique : 1–5% (overhead de planning + stats)

---

## Tests avancés

### Cache froid vs cache chaud

```bash
# Cache froid (simuler un accès disque réel)
echo 3 > /proc/sys/vm/drop_caches   # sur le serveur, en root

# Cache chaud : lancer la même requête 3 fois
# → les 2e et 3e passages utilisent le shared_buffers
```

### Partition-wise join

```sql
SET enable_partitionwise_join      = on;
SET enable_partitionwise_aggregate = on;
-- Déjà activé dans 04_benchmark_queries.sql
```

### Parallélisme par partition

```sql
SET max_parallel_workers_per_gather = 4;

EXPLAIN (ANALYZE, BUFFERS)
SELECT date_trunc('month', order_date), sum(total_amount)
FROM orders_partitioned
GROUP BY 1;
-- Observer les "Worker X" : chaque worker traite des partitions différentes
```

