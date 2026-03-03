# PostgreSQL 18 — Comprendre le Partitionnement

## Qu'est-ce que le partitionnement ?

Le partitionnement consiste à **diviser physiquement une grande table en plusieurs sous-tables** (partitions), tout en les exposant comme une table unique côté applicatif. Chaque ligne vit dans **exactement une** partition.

PostgreSQL supporte le partitionnement déclaratif depuis la v10, et il n'a cessé d'être amélioré depuis.

---

## Les 3 types de partitionnement

### 1. RANGE — Par plage de valeurs
Le plus courant. Idéal pour les dates.
```sql
PARTITION BY RANGE (order_date)
-- ex: une partition par mois ou par année
```

### 2. LIST — Par liste de valeurs discrètes
Utile pour des catégories connues à l'avance.
```sql
PARTITION BY LIST (status)
-- ex: 'pending', 'completed', 'cancelled'
```

### 3. HASH — Par hachage (distribution uniforme)
Quand il n'y a pas de dimension temporelle ou catégorielle naturelle.
```sql
PARTITION BY HASH (customer_id)
-- ex: 8 partitions de taille ~égale
```

---

## Pourquoi partitionner ?

| Bénéfice | Explication |
|---|---|
| **Partition Pruning** | Le query planner ignore les partitions non concernées par le WHERE |
| **Maintenance rapide** | `DROP PARTITION` au lieu d'un `DELETE` massif (instantané vs heures) |
| **Index plus petits** | Chaque partition a ses propres index → moins de niveaux B-tree |
| **I/O parallèle** | Chaque partition peut être lue en parallèle |
| **VACUUM plus efficace** | Le vacuum traite des unités plus petites |

---

## La règle d'or : la clé de partitionnement

Une bonne clé de partition doit :
- ✅ Être présente dans la majorité des clauses `WHERE`
- ✅ Avoir suffisamment de cardinalité pour le nombre de partitions voulu
- ✅ Ne pas changer souvent (changer la valeur = déplacer la ligne entre partitions)
- ❌ Éviter les colonnes trop chaudes (ex: `status` avec 90% des lignes en 'active')

**Pour un e-commerce : `order_date` est le candidat idéal.**

---

## Partition Pruning en action

```sql
-- Sans partitionnement : Seq Scan sur 100M lignes
-- Avec partitionnement par mois : Seq Scan sur ~833K lignes (1/120 de la table)

EXPLAIN SELECT * FROM orders WHERE order_date >= '2024-01-01' AND order_date < '2024-02-01';

-- Résultat attendu avec partitionnement :
-- Append
--   -> Seq Scan on orders_2024_01  (seule cette partition est lue !)
```

---

## Sub-partitionnement

Il est possible de partitionner des partitions :
```sql
-- Partition par année, puis par mois à l'intérieur
PARTITION BY RANGE (order_date)
  -> orders_2024 PARTITION BY RANGE (order_date)
    -> orders_2024_01
    -> orders_2024_02
    ...
```

---

## Limites à connaître

- Les **clés étrangères** vers une table partitionnée sont supportées depuis PG12, mais restent coûteuses
- Un `UNIQUE` ou `PRIMARY KEY` doit **inclure la clé de partition**
- Les **default partitions** peuvent bloquer l'ajout de nouvelles partitions (lock)
- Au-delà de ~1000 partitions, le planning lui-même peut devenir coûteux
