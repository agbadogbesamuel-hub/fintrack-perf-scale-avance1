# Design decisions — FinTrack Perf & Scale

Décisions d'architecture prises pendant la mission (sprints 1 à 6).

## Modélisation

### Choix Kimball vs Data Vault
- **Kimball (étoile : faits + dimensions conformes)** retenu.
- Les consommateurs sont des dashboards BI multi-tenant (Metabase, dashboard exécutif)
  et du reverse ETL. Ils veulent des tables larges, dénormalisées, faciles à filtrer
  par `tenant_id` / date. C'est exactement ce que donne une étoile, avec un minimum
  de jointures au moment de la requête.
- Data Vault (hubs / links / satellites) apporte surtout de l'auditabilité et de
  l'agilité quand les **sources sont nombreuses et changeantes**. Ici, il n'y a
  qu'un seul format d'entrée normalisé (le RAW FinTrack), et le besoin d'audit
  réglementaire est couvert plus simplement par le **snapshot SCD2**
  (`dim_comptes_scd2`) et la table `audit.dbt_run_log`.
- Data Vault multiplierait les jointures (×3 à ×5 tables par entité) sur une table
  de 50-100M lignes, à l'opposé de l'objectif CTO de réduire temps et coûts.
- À reconsidérer si FinTrack ingère un jour des formats natifs différents par
  banque partenaire : un Raw Vault en amont des marts Kimball serait alors
  pertinent.

### Grain des tables de faits
- `fct_transactions` : une ligne = une transaction validée ou en_attente, non-reversal
- `fct_virements` : une ligne = une leg de virement (sortant OU entrant, donc 2 lignes par virement)

### Bridge tables
- `bridge_comptes_titulaires` résout la relation **many-to-many** compte ↔ titulaire
  (comptes joints : 1 compte → 2 titulaires ; 1 titulaire → plusieurs comptes).
- Grain : une ligne = un rattachement (compte_id, titulaire_id, période).
- `allocation_factor` : poids de ventilation (1.0 pour un titulaire unique,
  0.5 / 0.5 pour un compte joint à 2). Invariant vérifié : **la somme des facteurs
  des rattachements actifs vaut 1.0 pour chaque compte** (0 exception sur 20 000
  comptes). Ventiler les dépenses par personne revient donc à
  `sum(f.montant_eur * b.allocation_factor)` sans double comptage.
- Historisation : `date_debut` / `date_fin` (NULL = actif). La bridge supporte les
  changements de titulaire dans le temps. Le générateur ne produit aujourd'hui que
  l'état courant.
- `is_primary` identifie le titulaire principal (courrier, KYC de référence).
- Données : 21 989 rattachements, dont 1 989 comptes joints (≈ 10 %, cohérent avec
  la pondération `type_compte='joint'` du générateur).
- Accès `private` : la bridge s'utilise via une jointure documentée. Elle n'est pas
  exposée telle quelle aux consommateurs BI.

## Matérialisations

| Modèle | Matérialisation | Raison |
|--------|-----------------|--------|
| stg_transactions | incremental (merge) | 50-100M lignes, updates de statut post-insertion |
| fct_transactions | incremental (merge) | idem, colonnes update ciblées via merge_update_columns |
| int_transactions_normalisees | ephemeral | évite matérialisation intermédiaire coûteuse |
| int_fx_rates_daily | table | petit volume, requêté par tous les faits |
| fct_transactions_v2 | incremental (merge) | lit v1 + 1 colonne ; même lookback, pas de rebuild complet |
| fct_transactions_microbatch | incremental (microbatch), **désactivé par défaut** | prototype de comparaison (cf. PERF_LOG), non retenu ; sur base vide il rejouerait ~1 400 batches journaliers |
| fct_virements | incremental (merge, clé virement_id + virement_leg) | double-écriture, 2 lignes / virement |
| dim_comptes_scd2 | table | reconstruite depuis le snapshot, petite volumétrie |
| bridge_comptes_titulaires | table | ~22k lignes |
| mart_solde_journalier | table | 2,4 s au scale M ; à passer en incremental si dérive au scale L/XL |
| mart_cohortes_retention | table | agrégat (cohorte × 13 offsets), quelques centaines de lignes |
| mart_transactions_anomalies | table | window functions sur tout l'historique du compte ; à passer en incremental (fenêtre = 90 tx précédentes) au scale XL |

## Clustering keys

| Table | Clustering key | Justification |
|-------|----------------|---------------|
| raw_transactions | (tenant_id, DATE_TRUNC('MONTH', date_transaction)) | Filtres BI dominants |
| raw_comptes | (tenant_id, date_ouverture) | Multi-tenant, requêtes par cohorte |
| raw_fx_rates | (date_cotation) | Toujours filtré par date |
| raw_compte_titulaires | (compte_id) | Toutes les lectures partent d'un compte |
| fct_transactions (+ v2, anomalies) | (tenant_id, DATE_TRUNC('MONTH', date_transaction)) | Depth mesurée 1.0 ; 75 % de pruning sur les filtres tenant (+ mois), cf. PERF_LOG |

Règle suivie : **ne jamais clusteriser sur une colonne timestamp brute** (cardinalité
trop élevée → reclustering coûteux). On tronque toujours au mois. Une dérive réelle a
été trouvée et corrigée sur `raw_transactions` au Sprint 3.

## Stratégie incrémentale

- `merge` sur `transaction_id` avec **fenêtre de lookback** (`var('incremental_lookback_days')`,
  7 j) sur `_loaded_at`. On retraite les N derniers jours chargés pour capter les
  changements de statut (`en_attente` → `validee`).
- `merge_update_columns` limité aux colonnes qui évoluent (statut, AML, fraude,
  rapprochement) : moins d'écritures qu'un update complet.
- Prérequis critique découvert : `_loaded_at` doit être alimenté. Les `COPY INTO`
  listent désormais explicitement leurs colonnes, sinon le `DEFAULT CURRENT_TIMESTAMP()`
  ne s'applique pas et le filtre incrémental ne retourne rien, sans aucune erreur.
- Microbatch évalué puis écarté au scale actuel (overhead d'orchestration par batch).

## Contracts & versioning

`fct_transactions` est sous contrat (`enforced: true`) et versionné (v1 latest, v2
prérelease). Détail et processus de migration : `docs/CONTRACTS.md`.

## CI/CD

- Slim CI : `state:modified+` avec `--defer` sur le manifest prod. Ce manifest est
  publié comme artifact GitHub par `dbt_prod_deploy.yml` à chaque push sur `main`
  (repli en build complet si absent).
- Un schéma unique `CI_<PR_ID>` par PR (override dans `generate_schema_name`),
  supprimé en fin de job par la macro `drop_schema`.

## SCD Type 2

Pattern retenu pour `dim_comptes_scd2` : `check` strategy avec `check_cols`.
Surrogate key `compte_sk = generate_surrogate_key(compte_id, dbt_valid_from)`,
`version_number` = `row_number()` par compte, `is_current` = `dbt_valid_to is null`.
Invariant « exactement une version courante par compte » porté par un test singulier
(`tests/assert_dim_comptes_scd2_one_current_version.sql`).
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

Positionné automatiquement via `on-run-start` (macros renommées `fintrack_set_query_tag` /
`fintrack_unset_query_tag` pour ne pas entrer en conflit avec les macros internes de
dbt-snowflake ≥ 1.9).

Piste d'amélioration : un query_tag **par modèle** (et non par session) permettrait
d'attribuer les crédits Snowflake modèle par modèle dans `QUERY_HISTORY`.
