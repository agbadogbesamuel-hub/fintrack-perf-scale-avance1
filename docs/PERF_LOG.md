# Performance Log — FinTrack Perf & Scale

À remplir pendant la mission. Ce document est un livrable obligatoire.

## Chargement initial

| Scale | Taille CSV (Go) | Durée génération | Durée PUT | Durée COPY | Erreurs |
|-------|-----------------|------------------|-----------|------------|---------|
| M     |                 |                  |           |            |         |
| L     |                 |                  |           |            |         |
| XL    |                 |                  |           |            |         |

## Baseline (avant optimisations)

Warehouse : ______  Target : ______  Date : ______

| Modèle | Rows | Bytes | Elapsed (s) | Partitions scanned | Credits |
|--------|------|-------|-------------|--------------------|---------|
| stg_transactions |  |  |  |  |  |
| fct_transactions |  |  |  |  |  |
| mart_solde_journalier |  |  |  |  |  |
| mart_tenant_kpis_daily |  |  |  |  |  |
| **Full run** |  |  |  |  |  |

## Après optimisations Sprint 3

Warehouse : ______  Target : ______  Date : ______

| Modèle | Rows | Bytes | Elapsed (s) | Partitions scanned | Credits | Gain |
|--------|------|-------|-------------|--------------------|---------|------|
| stg_transactions |  |  |  |  |  |  |
| fct_transactions |  |  |  |  |  |  |
| **Full run** |  |  |  |  |  |  |

## Analyse Query Profile

### Query 1 : ______

- Bytes scanned : ______
- Partitions scanned / total : ______ / ______
- Pruning efficiency : ______%
- Node dominant : ______
- Bytes spilled to local / remote : ______
- **Recommandation :** ______

### Query 2 : ______

[...]

### Query 3 : ______

[...]

## Décisions prises

- **Clustering key sur fct_transactions :** ______  → Justification : ______
- **Search Optimization :** activée sur ______  → Coût estimé : ______  → Bénéfice : ______
- **Materialized view :** activée sur ______  → Justification : ______
- **Merge vs Microbatch :** choix ______  → Raison : ______

## Coûts Snowflake

| Semaine | Credits WH_INGESTION | Credits WH_TRANSFORM | Credits WH_REPORTING | Total |
|---------|----------------------|----------------------|----------------------|-------|
|         |                      |                      |                      |       |
