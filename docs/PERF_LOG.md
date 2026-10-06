# Performance Log — FinTrack Perf & Scale

À remplir pendant la mission. Ce document est un livrable obligatoire.

## Chargement initial

Méthodologie : les temps ci-dessous sont issus de l'historique réel Snowflake (`SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` / `COPY_HISTORY`, filtré sur `table_catalog_name = 'FINTRACK_PROD'`), pas d'une estimation. Chargement effectué via l'assistant de chargement Snowsight (upload des CSV) + exécution des `COPY INTO` du script `03_stage_and_copy.sql`.

| Scale | Taille CSV (Go) | Durée génération | Durée PUT | Durée COPY | Erreurs |
|-------|-----------------|------------------|-----------|------------|---------|
| M     | 0,32 Go compressé / 0,96 Go décompressé (dont transactions : 0,29 Go / 0,95 Go) | non tracée (pas de log d'exécution du script Python conservé) | **449,7 s (≈ 7 min 30)** pour `raw_transactions.csv.gz` (0,29 Go compressé) via `PUT` SnowSQL vers `@fintrack_stage` — mesuré directement, upload réussi | **49,1 s** pour `raw_transactions` (1 000 000 lignes) ; **≈ 57,5 s cumulé** pour les 6 tables (tenants 1,56s / catégories 1,04s / fx_rates 1,87s / comptes 1,91s / transactions 49,1s / virements 1,94s) | 0 erreur de parsing ; 2 échecs transitoires de `COPY INTO` (`raw_transactions` et `raw_virements`) avant succès, probablement stage pas encore synchronisé après l'upload UI — à surveiller si ça se reproduit |
| L     |                 |                  |           |            |         |
| XL    |                 |                  |           |            |         |

**Constat clé :** le `PUT` (449,7 s) domine très largement le `COPY INTO` (49,1 s) pour le même volume — **≈ 90% du temps de chargement total est passé dans l'upload réseau du client vers le stage, pas dans l'ingestion côté Snowflake**. Le chargement initial du 21/09 est passé par l'assistant "Load Data" de Snowsight (upload web) plutôt que par un `PUT` SnowSQL scripté ; la mesure ci-dessus a été faite a posteriori avec le même fichier pour documenter ce ratio. À garder en tête pour le scaling ×10 (rapport final) : au-delà d'un certain volume, paralléliser les PUT (plusieurs fichiers/threads) ou passer par un stage externe (S3 + Snowpipe) devient plus pertinent que d'optimiser le COPY INTO lui-même.

## Baseline / mesures Sprint 3

Warehouse : WH_DEV (dev) / WH_INGESTION (raw)  Target : dev  Date : 2026-09-25

Note méthodologique : au scale M, `stg_transactions`/`fct_transactions` tiennent sur seulement 8 micro-partitions — les colonnes "Bytes"/"Credits" par modèle individuel ne sont pas isolables proprement avec le tagging actuel (query_tag global par session, pas par modèle) ; elles nécessiteraient un query_tag par modèle (piste d'amélioration notée dans `DESIGN.md`). Les temps ci-dessous viennent d'un run réel (build complet après backfill de `_loaded_at`, cf. Étape 9) :

| Modèle | Rows | Elapsed (s) | Partitions (depth) | Notes |
|--------|------|-------------|--------------------|-------|
| stg_transactions | 1 000 000 | 23,71 | — (vue matérialisée en table incrémentale) | Merge complet (1M lignes traitées, backfill `_loaded_at` inclus) |
| fct_transactions | 945 243 | 15,33 (+ ~8s pre/post hooks audit) | 8 partitions, depth **1.0** | Clustering `(tenant_id, month)` optimal dès la création par dbt |
| mart_solde_journalier | 915 287 | 2,39 | — | Table simple, pas de fenêtre glissante coûteuse observée |
| mart_tenant_kpis_daily | 5 840 | 3,24 | — | Agrégat, petit volume |
| **Full run** (`dbt build --exclude tag:todo`, 88 nodes : modèles + tests + unit tests) | — | **84,46 s** | — | Très en dessous de l'objectif < 1h — attendu au scale M ; le vrai test de charge est à refaire au scale L (voir "Reste à faire" ci-dessous) |

**Clustering `fct_transactions` :** depth 1.0 dès la première création (dbt applique le `cluster_by` du modèle à la création de la table) — aucune optimisation supplémentaire nécessaire à ce volume. Le vrai travail de clustering a porté sur `raw_transactions` (RAW), qui avait dérivé de sa clé documentée (voir section Décisions ci-dessous).

**Reste à faire pour un vrai test de charge :** ces mesures sont au scale M (1M transactions). L'objectif CTO (< 1h, ÷4 le temps de run) porte sur 50-100M lignes (scale XL) — non testé ici faute de temps/crédits disponibles pour cette mission. Recommandation : rejouer ce même protocole (build complet chronométré + `SYSTEM$CLUSTERING_INFORMATION`) sur un scale L (10M lignes) minimum avant mise en prod, pour valider que le clustering `(tenant_id, mois)` tient la charge au-delà de 8 partitions.

## Sprint 4.2 — Validation FX historisé

> ⚠️ **Correction du 05/10 : la première validation (25/09) était circulaire et masquait un bug majeur.**

**Validation initiale (25/09), invalide.** 100 transactions non-EUR recalculées « indépendamment » via `int_fx_rates_daily` avec la **même formule** que le modèle (`montant * taux`). Résultat : 0 % d'écart. Mais le test comparait la formule à elle-même : il ne pouvait pas détecter une formule fausse.

**Bug découvert le 05/10** grâce au mart d'anomalies (Sprint 6) : le JPY représentait 34 % des anomalies pour 2 % des volumes. Le référentiel est coté **EUR → devise** (1 EUR = 173 JPY, `devise_source = 'EUR'`). Convertir une devise en EUR demande donc de **diviser** par le taux, alors que `fct_transactions` multipliait. Conséquence : tous les `montant_eur` non-EUR (45 % des transactions) étaient faux, par exemple 67 JPY comptés 11 624 € au lieu de 0,39 €. Les marts finance et KPIs en dépendent.

| Devise | Montant moyen (devise) | `montant_eur` moyen AVANT | APRÈS correction |
|---|---|---|---|
| JPY | 67,12 | 11 623,79 € | **0,39 €** |
| CZK | 67,50 | 1 633,90 € | **2,79 €** |
| USD | 68,25 | 76,99 € | **60,80 €** |
| GBP | 67,63 | 53,67 € | **85,30 €** |
| EUR | 67,76 | 67,76 € | 67,76 € |

**Correction :** `montant_eur = montant / taux_referentiel`, avec repli sur `montant * taux_change_applique` (convention inverse de la source) si aucune cotation n'existe. Un test unitaire (`unit_tests/test_fct_transactions_fx.yml` : 16 000 JPY à 160 donnent 100,00 €) verrouille désormais le sens de conversion. Avec l'ancienne formule, il aurait renvoyé 2 560 000 €.

**Nouvelle validation (05/10), vraiment indépendante :** 100 transactions non-EUR de jours ouvrés, recalculées en SQL direct depuis `FINTRACK_PROD.RAW.raw_fx_rates` (table brute, sans passer par dbt ni par le forward-fill), avec `montant / taux`.

| Mesure | Résultat |
|---|---|
| Échantillon | 100 transactions non-EUR (jours ouvrés) |
| Écart moyen | **0 %** |
| Écart max | **0 %** (0 transaction > 0,01 €) |

**Leçon :** un test de non-régression doit avoir une source de vérité indépendante du code testé : un exemple calculé à la main (test unitaire) ou les données brutes. Recalculer avec la même logique ne prouve rien.

## Sprint 3.2 — Merge vs Microbatch

**Protocole :** prototype `fct_transactions_microbatch.sql` (`incremental_strategy='microbatch'`, `event_time='date_transaction'` propagé sur `int_transactions_normalisees`, `batch_size='day'`, `lookback=3`), testé sur une fenêtre d'1 semaine (2024-06-01 → 2024-06-08, 7 batches) faute de pouvoir se permettre un backfill complet sur 2 ans (~730 batches) en phase d'exploration.

| Stratégie | Volume testé | Durée totale (wall-clock dbt) | Durée réelle des requêtes Snowflake | Détail |
|---|---|---|---|---|
| **Microbatch** | 7 jours, 9 190 lignes (7 batches) | **42 s** (concurrency=4) | **0,4 à 1,3 s par batch** (INSERT réel, ~140 Ko scannés/batch) | L'essentiel du temps (42s wall-clock vs <10s de calcul réel cumulé) est de l'**overhead d'orchestration dbt** : une compilation Jinja + une connexion + un `CREATE TEMP TABLE` + un `INSERT` par batch, indépendamment du volume de données. |
| **Merge** | Build complet, 945 243 lignes (1M brut) | **49,1 s** (une seule requête `MERGE`, cf. section Baseline) | — | Une seule requête set-based, quel que soit le nombre de jours couverts par la fenêtre de lookback. |

**Constat clé :** au scale M (~1 300 transactions/jour), le coût réel de calcul Snowflake est négligeable dans les deux approches (< 1,5s par jour de données). La différence vient de l'**overhead fixe par batch du microbatch** : 7 requêtes séparées pour 7 jours de données contre 1 seule requête `MERGE` pour n'importe quelle taille de fenêtre. Le microbatch ne devient avantageux que si le volume par jour est assez gros pour que le calcul domine l'overhead d'orchestration (typiquement au-delà de plusieurs millions de lignes/jour, donc plutôt au scale L/XL/production réelle), ou si on valorise le découpage (reprise d'un seul jour en échec, parallélisation naturelle d'un backfill historique sur plusieurs warehouses).

**Point d'attention découvert :** sur la fenêtre testée, le microbatch a produit 9 190 lignes contre 9 208 attendues par un filtrage manuel équivalent (écart ~0,2%) — les bornes de batch semblent calées sur un fuseau horaire (limite observée à `2024-05-31 17:00:00`, pas minuit UTC pile). À creuser/documenter si le microbatch est retenu en production (aligner `begin`/fuseau du warehouse).

**Recommandation :** **conserver `incremental_strategy='merge'`** pour `fct_transactions` au scale actuel (M, et vraisemblablement L). Raisons : (1) le cas d'usage central — une transaction `en_attente` qui redevient `validee` quelques jours plus tard — est nativement couvert par le lookback + `merge_update_columns` en une seule requête ; (2) au volume journalier actuel, l'overhead per-batch du microbatch domine largement le gain de parallélisation ; (3) le merge est plus simple à opérer et déboguer (une seule requête à auditer par run). À réévaluer si le volume journalier dépasse plusieurs millions de lignes/jour (scale XL/production réelle, cf. question scaling ×10 du rapport final), où le découpage par jour du microbatch permettrait de paralléliser sur plusieurs warehouses et d'isoler les incidents à un seul jour.

## Analyse Query Profile

Méthodologie : requêtes exécutées avec `USE_CACHED_RESULT = FALSE`, statistiques précises extraites via `GET_QUERY_OPERATOR_STATS(query_id)` (pruning exact par table, pas une estimation).

### Query 1 : lookup ponctuel par `external_transaction_id` (hors clé de clustering)

```sql
SELECT transaction_id, statut FROM raw_transactions
WHERE external_transaction_id = 'EXT-F629B825B4EC487C';
```

- Bytes scanned : 224 379 392 (≈ 214 Mo, quasi toute la table)
- Partitions scanned / total : 7 / 8
- Pruning efficiency : 12,5 %
- Node dominant : TableScan (pas de pruning possible, colonne hors clé de clustering)
- Total elapsed / execution time : 1 669 ms / 283 ms
- **Recommandation :** colonne non alignée avec la clé de clustering (`tenant_id`, mois) → pruning naturellement faible. **Testé Search Optimization Service dessus (voir décision ci-dessous) : aucun gain mesurable au scale actuel.** Si ce type de lookup devient fréquent en prod à plus gros volume (L/XL, table à centaines/milliers de partitions), ré-activer SOS et re-mesurer — à ce volume-ci (8 partitions), la table est trop petite pour que l'optimiseur exploite l'index SOS.

### Query 2 : filtre BI typique (tenant + mois), aligné sur la clé de clustering

```sql
SELECT tenant_id, statut, count(*), sum(montant_eur)
FROM fct_transactions
WHERE tenant_id = 3 AND date_transaction >= '2024-03-01' AND date_transaction < '2024-04-01'
GROUP BY tenant_id, statut;
```

- Bytes scanned : 29 431 808 (≈ 28 Mo)
- Partitions scanned / total : 2 / 8
- Pruning efficiency : 75 %
- Node dominant : TableScan + Aggregate (léger)
- Total elapsed / execution time : 906 ms / 367 ms
- **Recommandation :** la clé de clustering (`tenant_id`, `date_trunc('month', date_transaction)`) fonctionne comme prévu sur ce pattern de filtre — c'est exactement le cas d'usage pour lequel elle a été choisie. Rien à changer.

### Query 3 : jointure dashboard (transactions × comptes × tenants, filtré par tenant)

```sql
SELECT t.tenant_name, c.type_compte, count(*), sum(f.montant_eur)
FROM fct_transactions f
JOIN dim_comptes c ON f.compte_id = c.compte_id
JOIN dim_tenants t ON f.tenant_id = t.tenant_id
WHERE f.tenant_id = 3
GROUP BY t.tenant_name, c.type_compte;
```

- Bytes scanned : 36 215 550 (≈ 35 Mo, tables de dimension incluses)
- Partitions scanned / total : `fct_transactions` 2/8 (mêmes bénéfices du clustering que Query 2, même sans filtre de date) ; `dim_comptes` et `dim_tenants` 1/1 (tables trop petites pour que le pruning ait un sens)
- Pruning efficiency : 75 % sur la table de faits
- Node dominant : Join (2 jointures) + Aggregate
- Total elapsed / execution time : 2 182 ms / 321 ms
- **Recommandation :** le filtre `tenant_id` seul (première partie de la clé de clustering) suffit déjà à écarter 75% des partitions même sans filtre de date — bon signe pour les dashboards qui filtrent par tenant sans plage temporelle. Pas d'optimisation supplémentaire nécessaire à ce volume ; les dimensions sont trop petites pour bénéficier de quoi que ce soit.

## Décisions prises

- **Clustering key sur fct_transactions :** `(tenant_id, date_trunc('month', date_transaction))`, depth mesuré à 1.0 (cible < 3 ✅)  → Justification : confirmé par Query 2/3 — c'est le pattern de filtre BI dominant (dashboards par tenant, souvent avec plage de dates).
- **Clustering key sur `raw_transactions` (RAW) :** bug trouvé — la table live utilisait `(tenant_id, date_transaction)` (colonne brute) au lieu de `(tenant_id, DATE_TRUNC('MONTH', date_transaction))` comme spécifié dans `02_ddl_raw_tables.sql` (dérive entre le script et l'état réel de la base). Snowflake alertait lui-même sur le risque de reclustering coûteux avec une clé à cardinalité aussi élevée. Corrigé via `ALTER TABLE ... CLUSTER BY` pour aligner sur le DDL documenté (depth passé de 1.5 à 2.25 juste après l'ALTER, avant reclustering automatique en tâche de fond — reste < 3).
- **Search Optimization :** testée sur `raw_transactions.external_transaction_id` (activée, mesurée, puis **désactivée**)  → Coût estimé : build ≈ 0,0018 crédits, stockage ≈ 93 Mo/mois (négligeable à ce volume)  → Bénéfice : **aucun** — même plan de requête, mêmes partitions scannées (7/8) avant/après ; à seulement 8 micro-partitions, l'optimiseur Snowflake n'active même pas le chemin d'accès SOS (la table est trop petite pour qu'il soit rentable). Recommandation : ne pas activer en prod tant que `raw_transactions`/`fct_transactions` restent à ce volume ; ré-évaluer au scale L/XL où le nombre de partitions sera dans les centaines/milliers.
- **Materialized view :** non testée — aucun besoin identifié à ce stade (pas de requête répétitive assez coûteuse pour la justifier au scale M). À réévaluer si `mart_tenant_kpis_daily`/`mart_solde_journalier` deviennent des points chauds en prod.
- **Merge vs Microbatch :** choix **merge**  → Raison : au scale M, l'overhead d'orchestration par batch (une requête par jour) domine largement le calcul réel (< 1,5s/jour) ; le merge traite toute la fenêtre de lookback en une seule requête set-based, plus simple et plus rapide à ce volume. Voir section "Sprint 3.2 — Merge vs Microbatch" ci-dessus pour le détail chiffré.

## Remontée sur nouveau compte Snowflake (05/10)

L'essai gratuit du compte initial a expiré. Tout a été remonté sur un nouveau compte (AWS, Enterprise) à partir des scripts du repo, ce qui valide au passage leur rejouabilité.

| Étape | Durée | Détail |
|---|---|---|
| `01_setup_infrastructure.sql` | 55,1 s | bases, 5 warehouses, 5 rôles, resource monitor |
| `02_ddl_raw_tables.sql` + `05_audit_tables.sql` | 15,3 s | |
| `PUT` des 8 CSV (dont `raw_transactions` 0,31 Go) | 356 s pour transactions, ≈ 412 s au total | `PARALLEL=16` (449,7 s sur l'ancien compte) |
| `COPY INTO` `raw_transactions` | **45,4 s**, 1 000 000 lignes, **0 erreur** | 49,1 s sur l'ancien compte |
| `_loaded_at` renseigné | **100 % des lignes** | la correction de l'étape 9 (liste de colonnes explicite) fonctionne sur un chargement neuf |
| `dbt build --full-refresh` (124 nœuds, Sprint 6 inclus) | **100,2 s**, 120 PASS / 1 WARN attendu (test qualité) / 0 erreur | 84,5 s pour 88 nœuds sur l'ancien compte |

Bugs trouvés pendant la remontée :
- **Requête de monitoring de `03_stage_and_copy.sql` invalide** : `FROM INFORMATION_SCHEMA.COPY_HISTORY(...)` sans `TABLE(...)`. Corrigée.
- **Prototype microbatch dans le build standard** : sur une base vide, `fct_transactions_microbatch` rejouait chaque jour depuis `begin='2023-01-01'`, soit 1 374 batches (environ 2 h 30 estimées, arrêté au batch 254). Sur l'ancien compte, il n'avait été construit que sur une semaine, d'où le problème invisible jusque-là. Il est désactivé par défaut (`enabled=var('enable_microbatch_prototype', false)`), avec une commande bornée documentée dans le modèle.

Bug trouvé le 06/10 (vérification de non-régression du lint) : **`mart_solde_journalier` non déterministe**. Grain (compte, jour) cassé par un regroupement sur le tenant de la transaction (≠ tenant du compte pour 87,4 % des lignes générées), d'où 24 269 doublons et un solde cumulé qui variait d'un run à l'autre. Corrigé et couvert par un test d'unicité (890 635 lignes, empreinte identique sur 2 runs).

## Incrémental : mesure d'un vrai delta (05/10)

Protocole : `_loaded_at` échelonné pour simuler des chargements quotidiens (`date_transaction + 1 jour`), full-refresh, puis chargement du « lendemain » : 1 transaction passée de `en_attente` à `validee` (tx `38`) et 1 nouvelle transaction (`1000002`). Chiffres tirés de `target/run_results.json` (`rows_inserted` / `rows_updated` renvoyés par Snowflake).

| Run | `stg_transactions` | `fct_transactions` | Lignes traitées (fct) |
|---|---|---|---|
| Full-refresh | 10,99 s | 12,92 s | 945 243 (rebuild complet) |
| Incrémental (lookback 7 j) | 11,03 s | 12,37 s | **1 insérée + 10 581 mises à jour (1,1 %)** |

**Fonctionnel :** tx 38 passée à `validee`, tx 1000002 insérée, 945 245 lignes = 945 245 `transaction_id` distincts (**0 doublon**), en v1 comme en v2.

**Temps identique, et c'est attendu à ce volume.** Le profil du `MERGE` (`GET_QUERY_OPERATOR_STATS`) montre l'opérateur Merge à **82,5 %** du temps, avec un scan de la cible à **8 partitions sur 8**. Snowflake réécrit des micro-partitions entières (immuables) : les 10 581 lignes de la fenêtre sont réparties sur les 8 partitions, donc mettre à jour 1,1 % des lignes réécrit 100 % de la table. À 50-100 M lignes, il y aura des milliers de partitions rangées par `(tenant_id, mois)`, et les 7 derniers jours n'en toucheront qu'une petite fraction. C'est là que l'incrémental paie. **Au scale M, il ne peut pas montrer de gain de temps.** Il faut un test au scale L.

Deux pistes d'optimisation identifiées :
1. **`incremental_predicates`** (par ex. `DBT_INTERNAL_DEST.date_transaction >= dateadd(day, -30, current_date)`) pour élaguer le scan de la cible. À n'activer qu'après avoir mesuré le délai maximal réel entre une transaction et sa mise à jour de statut, sinon on rate des mises à jour tardives.
2. N'**updater que les lignes réellement modifiées** : aujourd'hui, les 10 581 lignes de la fenêtre sont réécrites alors que 1 seule a changé. C'est faisable avec une stratégie de merge personnalisée qui compare `updated_at`.

Note : le lookback se calcule par rapport au `max(_loaded_at)` **de la table cible**, pas par rapport à l'heure courante. Un premier essai où toutes les lignes avaient le même `_loaded_at` (chargement unique) a retraité 1 000 000 de lignes : toutes tombaient dans la fenêtre. En production, un rechargement massif en une fois provoquera donc un retraitement complet au run suivant (correct, mais coûteux).

## Coûts Snowflake

| Semaine | Credits WH_INGESTION | Credits WH_TRANSFORM | Credits WH_REPORTING | Total |
|---------|----------------------|----------------------|----------------------|-------|
|         |                      |                      |                      |       |
