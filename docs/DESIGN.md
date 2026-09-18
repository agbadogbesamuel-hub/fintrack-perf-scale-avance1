# Design decisions — FinTrack Perf & Scale

À remplir pendant la mission.

## Modélisation

### Choix Kimball vs Data Vault
- ______

### Grain des tables de faits
- `fct_transactions` : une ligne = une transaction validée ou en_attente, non-reversal
- `fct_virements` : une ligne = une leg de virement (sortant OU entrant, donc 2 lignes par virement)

### Bridge tables
- ______

## Matérialisations

| Modèle | Matérialisation | Raison |
|--------|-----------------|--------|
| stg_transactions | incremental (merge) | 50-100M lignes, updates de statut post-insertion |
| fct_transactions | incremental (merge) | idem, colonnes update ciblées via merge_update_columns |
| int_transactions_normalisees | ephemeral | évite matérialisation intermédiaire coûteuse |
| int_fx_rates_daily | table | petit volume, requêté par tous les faits |
| mart_solde_journalier | table | complexité window function, à évaluer en incremental si dérive |

## Clustering keys

| Table | Clustering key | Justification |
|-------|----------------|---------------|
| raw_transactions | (tenant_id, DATE_TRUNC('MONTH', date_transaction)) | Filtres BI dominants |
| raw_comptes | (tenant_id, date_ouverture) | Multi-tenant, requêtes par cohorte |
| raw_fx_rates | (date_cotation) | Toujours filtré par date |

## SCD Type 2

Pattern retenu pour `dim_comptes_scd2` : `check` strategy avec `check_cols`.
Colonnes surveillées : statut, kyc_level, aml_flag, email, type_compte, customer_segment, is_pep.

## Convention de nommage

- `stg_<entity>` : staging
- `int_<action>_<entity>` : intermediate
- `dim_<entity>` : dimension
- `fct_<entity>` : fact
- `bridge_<entity1>_<entity2>` : bridge
- `mart_<domain>_<subject>` : mart consommable

## Query tags

Format : `team=<team>|project=<project>|target=<target>`

Positionné automatiquement via `on-run-start`.
