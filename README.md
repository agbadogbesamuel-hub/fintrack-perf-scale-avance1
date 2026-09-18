# FinTrack Perf & Scale

Projet avancé de la série FinTrack Analytics — **niveau senior**.

Voir [`MISSION.md`](./MISSION.md) pour le briefing métier complet et les user stories sprintées.

---

## Contenu du repo

```
fintrack-perf-scale/
│
├── MISSION.md                         Briefing métier + user stories par sprint
├── README.md                          Ce fichier (setup technique)
├── .sqlfluff                          Config linter SQL
├── .pre-commit-config.yaml            Hooks Git
├── .github/workflows/                 CI GitHub Actions
│   └── dbt_ci.yml
│
├── dbt/                               Projet dbt
│   ├── dbt_project.yml
│   ├── packages.yml
│   ├── profiles.yml.example           Template — à copier vers ~/.dbt/
│   ├── models/
│   │   ├── staging/                   Vues staging (view + 2 incrementals)
│   │   ├── intermediate/              CTEs éphémères
│   │   └── marts/
│   │       ├── core/                  Dimensions et faits centraux
│   │       ├── finance/               Marts métier finance
│   │       └── analytics/             KPIs et analyses
│   ├── snapshots/                     SCD2 comptes
│   ├── macros/                        Macros custom + generic tests
│   ├── tests/                         Tests singuliers
│   ├── unit_tests/                    Tests unitaires (dbt 1.8+)
│   └── analyses/                      Analyses ad-hoc
│
├── scripts/
│   ├── python/
│   │   ├── generate_data.py           Générateur de données synthétiques
│   │   └── requirements.txt
│   └── snowflake/
│       ├── 01_setup_infrastructure.sql   Base, schémas, warehouses, rôles
│       ├── 02_ddl_raw_tables.sql         DDL avec clustering keys
│       ├── 03_stage_and_copy.sql         Stage + COPY INTO
│       ├── 04_performance_features.sql   SO, MV, clustering info
│       └── 05_audit_tables.sql           Tables d'audit pour hooks
│
├── orchestration/
│   ├── README.md
│   └── airflow_dag_fintrack.py        DAG production (squelette)
│
└── docs/                              À compléter pendant la mission
    ├── PERF_LOG.md
    ├── DESIGN.md
    └── CONTRACTS.md
```

---

## Prérequis

- Un compte **Snowflake** (trial gratuit ou payant — le trial suffit pour scale S/M)
- **Python 3.11+**
- **dbt-snowflake >= 1.8**
- **SnowSQL** pour uploader les CSV vers le stage interne
- **Git + GitHub** (pour la CI)

---

## Setup en 8 étapes

### 1. Cloner et créer un environnement virtuel

```bash
git clone <votre-repo> fintrack-perf-scale
cd fintrack-perf-scale
python -m venv .venv
source .venv/bin/activate
pip install -r scripts/python/requirements.txt
pip install dbt-snowflake==1.8.* sqlfluff sqlfluff-templater-dbt
pre-commit install
```

### 2. Provisionner Snowflake

Depuis Snowsight (rôle ACCOUNTADMIN), exécutez :

```bash
scripts/snowflake/01_setup_infrastructure.sql
```

Puis attribuez les rôles à votre utilisateur (dernières lignes du script).

### 3. Configurer dbt

```bash
cp dbt/profiles.yml.example ~/.dbt/profiles.yml
# Éditer les variables d'environnement :
export SNOWFLAKE_ACCOUNT=xy12345.eu-west-1
export SNOWFLAKE_USER=votre_user
export SNOWFLAKE_PASSWORD=***
```

Vérifier :

```bash
cd dbt
dbt debug --target dev
dbt deps
```

### 4. Créer les tables RAW

```bash
# Dans Snowsight, exécuter :
scripts/snowflake/02_ddl_raw_tables.sql
scripts/snowflake/05_audit_tables.sql
```

### 5. Générer et charger les données

```bash
# Générer (choisir un scale)
python scripts/python/generate_data.py --scale M --output data/raw/

# Uploader vers le stage Snowflake (SnowSQL)
snowsql -q "USE ROLE FINTRACK_INGESTION_ROLE; USE WAREHOUSE WH_INGESTION; \
           USE DATABASE FINTRACK_PROD; USE SCHEMA RAW; \
           PUT file://data/raw/*.csv.gz @FINTRACK_STAGE AUTO_COMPRESS=FALSE;"

# COPY INTO
snowsql -f scripts/snowflake/03_stage_and_copy.sql
```

### 6. Premier `dbt build`

```bash
cd dbt

# Build complet (initial full-refresh)
dbt build --target dev --exclude tag:todo

# Vérifier les modèles créés
dbt list --target dev --resource-type model
```

### 7. Vérifier les tests

```bash
dbt test --target dev --exclude tag:todo
dbt test --select unit_test:*   # dbt 1.8+
```

### 8. Générer et servir la doc

```bash
dbt docs generate --target dev
dbt docs serve --port 8080
```

---

## Presets de volume du générateur

| Scale | Transactions | Comptes | Durée génération | RAM |
|-------|--------------|---------|------------------|-----|
| XS    |         10k  |    200  |   ~30 sec        | <1 Go |
| S     |        100k  |     2k  |   ~3 min         | <1 Go |
| M     |          1M  |    20k  |   ~10 min        | 2 Go  |
| L     |         10M  |   200k  |   ~1 h           | 4 Go  |
| XL    |         50M  |     1M  |   ~5 h           | 8 Go  |
| XXL   |        100M  |     2M  |   ~10 h          | 16 Go |

**Recommandation :** commencez sur `M` pour valider votre pipeline, montez sur `L` pour benchmarker les optimisations du Sprint 3, `XL` uniquement si vous avez le crédit Snowflake.

---

## Convention Git

- `main` — production, protégée
- `staging` — pré-production, déployée depuis les PR mergées
- `feat/<sprint>-<us>-<slug>` — features (ex : `feat/sprint3-us31-incremental-merge`)
- `fix/<ticket>-<slug>` — corrections

Chaque PR doit :
- Passer la CI (lint + slim build)
- Contenir au moins un test si un modèle est ajouté/modifié
- Documenter les changements de matérialisation dans `docs/DESIGN.md`

---

## Commandes utiles

```bash
# Build seulement les modèles modifiés depuis prod
dbt build --select state:modified+ --defer --state target-prod/

# Run un tag précis
dbt run --select tag:staging
dbt run --select tag:critical

# Compiler sans exécuter (utile pour debug templating)
dbt compile --select fct_transactions

# Inspecter le lineage
dbt list --select +fct_transactions+

# Nettoyer les schémas CI après une PR
dbt run-operation drop_schema --args "{schema_name: CI_42}"
```

---

## Debug perf Snowflake

- **Voir un plan de requête :** Snowsight → History → cliquer la query → onglet Profile
- **Coûts par query_tag :**
  ```sql
  SELECT query_tag, SUM(credits_used_cloud_services)
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time > DATEADD(day, -7, CURRENT_TIMESTAMP())
  GROUP BY query_tag ORDER BY 2 DESC;
  ```
- **Vérifier le clustering :**
  ```sql
  SELECT SYSTEM$CLUSTERING_INFORMATION('RAW.raw_transactions');
  ```

---

## Support

- Voir `MISSION.md` pour le contexte et les livrables attendus
- Erreur ? Vérifier d'abord : rôle actif, warehouse repris, base courante, fichiers uploadés
- Coûts qui dérivent ? Auto-suspend n'a pas fonctionné, ou une query hors du query_tag
