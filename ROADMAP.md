# Roadmap step-by-step — FinTrack Perf & Scale

Guide séquentiel pour boucler la mission. Suivez les étapes **dans l'ordre** : chaque étape indique quoi faire, où, et comment vérifier que c'est fait avant de passer à la suivante. Cochez au fur et à mesure.

État établi le 2026-09-21. Légende : ✅ déjà acquis — 👉 étape en cours à traiter — ⬜ pas commencé

---

## Phase A — Fondations (données en base)

Rien n'est testable tant que les données ne sont pas réellement dans Snowflake. C'est le préalable absolu.

### Étape 1 — Vérifier/finaliser le chargement Snowflake ✅
**Objectif :** confirmer que `RAW.raw_transactions` et les autres tables RAW contiennent bien les données générées.

**Fait le 22/09 :** confirmé via `dbt show --inline` (requête directe Snowflake) — `FINTRACK_PROD.RAW` contient bien 1 000 000 transactions, 20 000 comptes, 6 579 taux FX, 2 000 virements, 30 catégories, 8 tenants. Chargé le 21/09 vers 03h30 via l'assistant Snowsight (confirmé par `ACCOUNT_USAGE.COPY_HISTORY`/`QUERY_HISTORY`).

⚠️ **Effet de bord découvert et corrigé au passage :** `dbt/models/marts/core/dim_comptes_scd2.sql` contenait un tag Jinja `{{ dbt_utils.generate_surrogate_key([...]) }}` glissé dans un commentaire d'indication (lignes 10-11) — dbt évalue les `{{ }}` même en commentaire SQL, et cet appel plantait (`TypeError: bad operand type for unary -: 'str'`) **le parsing de tout le projet**, empêchant toute commande `dbt run`/`build`/`test`/`show` de fonctionner depuis le début. Corrigé (texte du commentaire conservé, plus interprété comme du Jinja). Un `.venv` a aussi été créé avec un vrai `dbt-snowflake` (1.12.1, le `dbt` en PATH global était dbt-fusion 2.0 preview, incompatible) — **pensez à activer ce `.venv` avant toute commande dbt** (`source .venv/Scripts/activate` sous Git Bash / `.venv\Scripts\activate` sous PowerShell).

**Actions :**
1. `snowsql` ou Snowsight → vérifier si les tables existent et sont peuplées :
   ```sql
   USE DATABASE FINTRACK_DEV; -- ou FINTRACK_PROD selon votre setup
   SELECT COUNT(*) FROM RAW.raw_transactions;
   SELECT COUNT(*) FROM RAW.raw_comptes;
   ```
2. Si vide ou tables absentes : exécuter dans l'ordre
   - `scripts/snowflake/02_ddl_raw_tables.sql`
   - `scripts/snowflake/05_audit_tables.sql`
   - Upload : `PUT file://data/raw/*.csv.gz @FINTRACK_STAGE AUTO_COMPRESS=FALSE;`
   - `scripts/snowflake/03_stage_and_copy.sql` (COPY INTO avec `ON_ERROR = CONTINUE`)
3. Noter le nombre de lignes chargées et le nombre d'erreurs de COPY (`SELECT * FROM information_schema.load_history` ou l'output du `COPY INTO`).

**Critère de fin :** `SELECT COUNT(*)` sur `raw_transactions` retourne un nombre cohérent avec le scale généré (regardez le fichier CSV décompressé si besoin, ou le README pour les ordres de grandeur par scale).

### Étape 2 — Documenter le chargement dans PERF_LOG.md ✅
**Fichier :** `docs/PERF_LOG.md`, section "Chargement initial".

**Fait le 22/09 :** tableau rempli avec des données réelles (pas des estimations) tirées de `ACCOUNT_USAGE.COPY_HISTORY`/`QUERY_HISTORY` pour le COPY, et d'un `PUT` chronométré manuellement pour l'upload. Constat notable : le PUT (449,7s) domine très largement le COPY (49,1s) — l'upload réseau est le vrai goulot d'étranglement, pas Snowflake. Seule case restée vide : durée de génération Python (aucun log n'existe pour la retrouver — négligeable pour la suite).

**Reste ouvert (pas bloquant) :** lignes L/XL du tableau à remplir seulement si vous testez ces scales plus tard (Sprint 3 recommande L pour les benchmarks perf).

---

## Phase B — Sprint 2 : modèles core manquants

### Étape 3 — `dim_categories` : hiérarchie récursive ✅
**Fichier :** `dbt/models/marts/core/dim_categories.sql`

**À faire :** remplacer le `select` passthrough par une CTE `WITH RECURSIVE` (syntaxe Snowflake) qui remonte les parents via `categorie_parent_id` jusqu'à la racine, et construit :
- `chemin_complet` (concaténation genre `"Loisirs > Restaurant > Fast-food"`)
- `id_racine` (categorie_id du nœud sans parent)
- garder `niveau_hierarchique` existant ou le recalculer via la profondeur de récursion

**Vérifier :**
```bash
cd dbt && dbt run --select dim_categories --target dev
dbt compile --select dim_categories   # pour relire le SQL généré si besoin de debug
```
Puis en base : contrôler à la main quelques catégories à plusieurs niveaux pour vérifier que `chemin_complet` est correct.

**Critère de fin :** `dbt run --select dim_categories` passe, `chemin_complet` reflète bien la hiérarchie (pas juste `nom_categorie`).

**Fait le 23/09.** Deux bugs bloquants trouvés et corrigés au passage (touchaient TOUS les modèles, pas que celui-ci) :
1. **Conflit de macros `set_query_tag`/`unset_query_tag`** : le projet définissait ses propres macros du même nom que celles internes de dbt-snowflake ≥1.9 (appelées automatiquement autour de chaque modèle), avec une signature incompatible → toute création de modèle plantait. Renommées en `fintrack_set_query_tag`/`fintrack_unset_query_tag` (voir `dbt/macros/set_query_tag.sql` et `dbt_project.yml`).
2. **`dbt run --select dim_categories` seul** échoue toujours avec "Schema ... does not exist" si `stg_categories` n'a jamais été buildé — il faut inclure les dépendances amont : `dbt run --select +dim_categories --target dev`.

Votre CTE récursive avait aussi 2 bugs (alias `ch`/`c` inexistants dans le `FROM` final, `chemin_complet`/`id_racine` jamais calculés dans la récursion elle-même) — corrigés : ces deux colonnes sont maintenant construites niveau par niveau à l'intérieur du `WITH RECURSIVE`.

**Découverte additionnelle :** le générateur (`generate_categories()` dans `scripts/python/generate_data.py`) fixait `categorie_parent_id = None` pour toutes les catégories — aucune hiérarchie n'existait dans les données, donc impossible de vérifier visuellement le résultat. Enrichi pour créer un noeud racine par `groupe` + un exemple à 3 niveaux (`Loisirs > Restaurant > Fast-food`, conforme à l'exemple du briefing). `raw_categories` régénéré (39 lignes) et rechargé dans Snowflake (TRUNCATE + COPY, table minuscule, aucun impact sur `raw_transactions`). Résultat vérifié : hiérarchie correcte sur 3 niveaux, tests `unique`/`not_null` passants.

### Étape 4 — `fct_virements` : double-écriture ✅
**Fichier :** `dbt/models/marts/core/fct_virements.sql`

**À faire :** compléter avec un `UNION ALL` entre la leg "sortant" (déjà présente) et une leg "entrant" (`compte_dest_id`, `montant` positif, `virement_leg = 'entrant'`, `contrepartie_compte_id` pointant vers l'autre compte).

**Vérifier :**
```bash
dbt run --select fct_virements --target dev
dbt test --select fct_virements --target dev
```
Contrôle manuel : `SELECT virement_id, COUNT(*) FROM fct_virements GROUP BY 1 HAVING COUNT(*) != 2` doit retourner 0 ligne.

**Critère de fin :** chaque `virement_id` a exactement 2 lignes (sortant + entrant), montants signés cohérents (somme des deux legs = 0).

**Fait le 23/09.** Bug trouvé au passage dans le squelette fourni : `{% if is_incremental() %} where ... {% endif %} and statut = 'execute'` produisait du SQL invalide en full-refresh (pas de `WHERE` avant le `and`) — corrigé en mettant `where statut = 'execute'` en premier et la condition incrémentale en `and` conditionnel. Double-écriture implémentée via `UNION ALL` (leg sortant : `montant_signe` négatif, `contrepartie_compte_id = compte_dest_id` ; leg entrant : inverse). Vérifié : 3554 lignes (1777 virements `execute` × 2), 0 virement avec un nombre de lignes ≠ 2, somme des `montant_signe` par virement = 0 partout. Tests `_core.yml` passants (`not_null`, `accepted_values` sortant/entrant). Tag `todo` retiré.

### Étape 5 — Retirer le tag `todo` sur ces deux modèles ✅
**Fait le 23/09** (avec l'étape 4). Le 05/10, tous les tags `todo` et en-têtes `TODO` restants ont été retirés ou remplacés par la décision prise.

Une fois les étapes 3 et 4 validées, retirez `'todo'` de la liste `tags` dans les configs (`dim_categories.sql` n'en avait pas, mais `fct_virements.sql` a `tags=[..., 'todo']`) pour qu'ils rentrent dans le run standard `dbt build --exclude tag:todo` sans y être exclus par erreur — ou au contraire pour qu'ils soient bien pris en compte dans les CI/futures commandes qui excluent `tag:todo`.

### Étape 6 — Bridge comptes ↔ titulaires (le plus gros morceau) ✅
Rien n'existe encore ici — 4 sous-étapes à faire dans l'ordre :

**6a. Générateur Python.** Fichier : `scripts/python/generate_data.py` ✅ **fait le 23/09.**
- `generate_comptes()` retourne maintenant `(compte_ids, comptes_meta)` — `comptes_meta` capture `type_compte`/`nom_client`/`prenom_client`/`date_ouverture` par compte, nécessaire pour générer des titulaires cohérents avec l'identité déjà affichée sur le compte.
- Nouvelle fonction `generate_titulaires_and_bridge()` : les comptes `type_compte == 'joint'` (10% des comptes, déjà existant dans le générateur) reçoivent 2 titulaires (`allocation_factor` 0.5/0.5) ; les autres 1 seul titulaire (`allocation_factor` 1.0, `is_primary=True`). `date_debut` = date d'ouverture du compte ; `date_fin` laissé vide (aucune rotation de titulaire simulée — la bridge supporte l'historisation mais le générateur ne produit que l'état courant, cf. `bridge_comptes_titulaires.sql` Sprint 5).
- `main()` mis à jour ([1/7] → [7/7]).

**6b. DDL.** Fichier : `scripts/snowflake/02_ddl_raw_tables.sql` ✅ **fait le 23/09.**
- `raw_titulaires` (titulaire_id, nom, prenom, email, telephone, date_naissance)
- `raw_compte_titulaires` (compte_id, titulaire_id, allocation_factor, date_debut, date_fin, is_primary), `CLUSTER BY (compte_id)` — plus pertinent que `tenant_id` ici puisque toutes les requêtes de cette bridge partent d'un `compte_id`.
- `COPY INTO` pour les 2 tables ajoutés dans `03_stage_and_copy.sql` (+ validation post-load).

**Chargé et vérifié en base (23/09) :** régénération scale M complète (12 min) → `raw_titulaires` (21 989 lignes) et `raw_compte_titulaires` (21 989 lignes, 1 989 comptes joints sur 20 000 — cohérent avec la pondération 10% de `type_compte='joint'`) créées via DDL dédié (sans toucher aux tables existantes) et chargées, 0 erreur `COPY INTO`.

**6c. Staging.** ✅ **fait le 23/09.** `stg_titulaires.sql` et `stg_compte_titulaires.sql` créés (pattern view standard), sources ajoutées dans `_sources.yml`, tests dans `_staging.yml` (`unique`/`not_null` + `dbt_utils.unique_combination_of_columns` sur `(compte_id, titulaire_id)`).

**6d. Bridge.** ✅ **fait le 23/09.** `bridge_comptes_titulaires.sql` réécrit — sélectionne directement `stg_compte_titulaires` (plus de placeholder 1:1). Tests ajoutés dans `_core.yml` (`not_null` sur les clés, `accepted_range [0,1]` sur `allocation_factor`).

**Vérifié fonctionnellement :** 21 989 lignes bridge, répartition 18 011 comptes à 1 titulaire / 1 989 comptes à 2 titulaires (joints), **0 compte** où la somme des `allocation_factor` (rattachements actifs) ≠ 1.0. Tous les tests dbt passent (10/10).

**6c. Régénérer et recharger les données.**
```bash
python scripts/python/generate_data.py --scale <votre_scale> --output data/raw/
# puis PUT + COPY INTO comme à l'étape 1, mais uniquement pour ces 2 nouvelles tables
```

**6d. Staging + bridge.**
- Créer `dbt/models/staging/stg_titulaires.sql` et `stg_compte_titulaires.sql` (suivre le pattern des autres modèles staging existants)
- Ajouter les sources correspondantes dans `dbt/models/staging/_sources.yml`
- Réécrire `dbt/models/marts/core/bridge_comptes_titulaires.sql` en joignant `stg_compte_titulaires` (avec `allocation_factor`, `date_debut`, `date_fin`, `is_primary` réels au lieu du placeholder 1:1)

**Vérifier :**
```bash
dbt run --select stg_titulaires stg_compte_titulaires bridge_comptes_titulaires --target dev
```
`SELECT compte_id, SUM(allocation_factor) FROM bridge_comptes_titulaires WHERE date_fin IS NULL GROUP BY 1` — vérifier que la somme des allocations par compte actif est cohérente (ex. = 1.0).

**Critère de fin :** au moins quelques comptes joints réellement présents avec plusieurs titulaires ; bridge peuplée avec des vraies valeurs, plus de placeholder 1:1.

### Étape 7 — Tests unitaires manquants ✅
**Fichier :** `dbt/unit_tests/` (ajouter `test_dim_categories.yml` et `test_fct_virements.yml`)

**À faire :** au moins 1-2 cas par modèle, sur le pattern de `test_stg_transactions.yml` déjà fourni (ex : pour `fct_virements`, vérifier qu'un virement source génère bien 2 lignes avec les bons signes ; pour `dim_categories`, vérifier qu'une catégorie à 3 niveaux produit le bon `chemin_complet`).

**Critère de fin :** `dbt test --select unit_test:*` passe sur tous les nouveaux tests.

**Fait le 24/09.** Bug bloquant trouvé (touchait TOUS les tests unitaires, y compris `test_stg_transactions.yml` déjà fourni, qui n'avait donc jamais tourné) : `model-paths` dans `dbt_project.yml` ne listait que `["models"]`, donc dbt ne scannait jamais le dossier `unit_tests/`. Ajouté `"unit_tests"` à `model-paths`.

Deuxième point bloquant (spécifique à dbt-core 1.12) : tout unit test sur un modèle utilisant `is_incremental()` doit désormais déclarer explicitement `overrides: {macros: {is_incremental: false}}`, sans quoi dbt refuse de parser le test (`Boolean override for 'is_incremental' must be provided`). Ajouté sur les 5 tests concernés (`stg_transactions` ×3, `fct_virements` ×2).

Créés : `test_dim_categories.yml` (racine sans parent ; hiérarchie 3 niveaux Loisirs > Restaurant > Fast-food, vérifie que `id_racine` pointe toujours vers la racine et pas le parent direct) et `test_fct_virements.yml` (double-écriture sortant/entrant ; exclusion des virements non `execute`). **7/7 tests unitaires passants** (`dbt test --select "resource_type:unit_test"`).

### Étape 8 — Checkpoint Sprint 2 ✅
```bash
dbt build --target dev --exclude tag:todo
dbt test --target dev --exclude tag:todo
```
**Critère de fin :** tout passe en vert (hors modèles encore explicitement tagués `todo` que vous n'avez pas encore traités dans les sprints suivants).

**Fait le 24/09 — build 100% vert : 90/90 (0 erreur, 0 skip).** Deux bugs bloquants supplémentaires trouvés et corrigés au passage (aucun rapport avec vos développements Sprint 2, ce sont des modèles/macros "fournis") :
1. **`int_fx_rates_daily.sql`** — le dernier `SELECT` (taux 1:1 EUR→EUR) lisait `date_cotation` depuis `date_spine`, qui n'a en réalité qu'une colonne `date_day` (celle de `dbt_utils.date_spine`). Corrigé en aliasant `date_day::date as date_cotation`. Ce bug bloquait `fct_transactions` et donc toute la cascade en aval (`mart_reconciliation`, `mart_tenant_kpis_daily`, `mart_solde_journalier`).
2. **`macros/log_incremental_run.sql`** — même famille de bug que `dim_comptes_scd2.sql` (Jinja actif dans un commentaire `--`) : la ligne "commentée" `-- {{ return(query) }}` s'exécutait quand même et court-circuitait la macro avant d'atteindre le `return("select 1 as noop")` réellement voulu. Résultat : le pre_hook de `fct_transactions` tentait un vrai `INSERT INTO FINTRACK_DEV.audit.dbt_run_log`, table qui n'existait pas → erreur. Corrigé en activant réellement l'insert (`return(query)`) et en créant le schéma `AUDIT`/table `dbt_run_log` dans `FINTRACK_DEV` (mêmes DDL que `05_audit_tables.sql`, adaptées à `FINTRACK_DEV`). Le pipeline a maintenant une vraie traçabilité des runs incrémentaux, comme prévu par `DESIGN.md`.

**Vérifié :** `fct_transactions` contient 945 243 lignes (cohérent : ~95% de 1M transactions passent le filtre `statut in ('validee','en_attente') and not is_reversal`).

**Phase B (Sprint 2) est complète.**

---

## Phase C — Sprint 3 : incrémental et performance (le cœur noté critique)

### Étape 9 — Valider le comportement du merge incrémental ✅
`stg_transactions` et `fct_transactions` sont déjà codés en incremental merge — il faut le **prouver**, pas juste faire confiance au code.

**Actions :**
1. Build complet initial : `dbt build --select stg_transactions fct_transactions --full-refresh --target dev`
2. En base, prendre une transaction `en_attente`, la faire passer à `validee` directement dans `RAW.raw_transactions` (update SQL manuel, en changeant aussi `updated_at`/`_loaded_at` pour qu'elle tombe dans la fenêtre de lookback)
3. Relancer sans full-refresh : `dbt run --select stg_transactions fct_transactions --target dev`
4. Vérifier qu'il n'y a **pas de duplicat** et que le statut est bien mis à jour :
   ```sql
   SELECT transaction_id, COUNT(*) FROM fct_transactions GROUP BY 1 HAVING COUNT(*) > 1; -- doit être vide
   SELECT statut FROM fct_transactions WHERE transaction_id = <id_testé>; -- doit être 'validee'
   ```

**Critère de fin :** test documenté (même juste dans vos notes), 0 duplicat, statut bien mergé.

**Fait le 25/09 — bug critique trouvé avant même de pouvoir tester quoi que ce soit :** `_loaded_at` était **NULL sur les 100% des lignes** de `raw_transactions`, `raw_comptes`, `raw_virements`, `raw_titulaires`, `raw_compte_titulaires`. Cause : les `COPY INTO` du script 03 ne listaient pas explicitement les colonnes cibles ; comme `_loaded_at` (dernière colonne de chaque DDL) est absente des CSV générés (censée être remplie par son `DEFAULT CURRENT_TIMESTAMP()`), Snowflake la charge à `NULL` au lieu d'appliquer le défaut dès qu'on ne fournit pas de liste de colonnes explicite. Avec `_loaded_at` NULL partout, la clause `where _loaded_at >= (select dateadd('day', -7, max(_loaded_at)) from {{ this }})` de **tous** les modèles incrémentaux (`stg_transactions`, `fct_transactions`, `stg_virements`, `fct_virements`) aurait filtré **0 ligne** sur tout run non-full-refresh — un bug silencieux qui aurait cassé la fraîcheur des données en production sans jamais lever d'erreur.

Corrigé :
1. `scripts/snowflake/03_stage_and_copy.sql` — chaque `COPY INTO` liste maintenant explicitement ses colonnes cibles (dans l'ordre exact du CSV, `_loaded_at` exclue) pour que son `DEFAULT` s'applique aux futurs chargements.
2. Rétro-rempli `_loaded_at` sur les données déjà chargées (`UPDATE ... SET _loaded_at = <timestamp réel de chargement> WHERE _loaded_at IS NULL`), puis full-refresh des 4 modèles incrémentaux pour propager.

**Test réalisé :** transaction `286964` passée `en_attente` → `validee` en RAW (avec `_loaded_at` rafraîchi), puis `dbt run --select stg_transactions fct_transactions` (sans `--full-refresh`). Résultat : `transaction_id=286964` → `statut='validee'`, **exactement 1 ligne** ; `945 243` lignes totales = `945 243` `transaction_id` distincts sur toute la table → **0 duplicat**. Merge incrémental validé.

*Note méthodologique :* comme toutes les lignes backfillées partagent le même timestamp initial, ce run a retraité l'intégralité des 1M lignes (pas un vrai delta) — suffisant pour valider la non-duplication du merge, mais pas pour mesurer un vrai gain de temps delta-only. Ça, c'est l'objet de l'Étape 12 (mesures avant/après avec des runs successifs à `_loaded_at` réellement échelonnés).

### Étape 10 — Prototyper la stratégie microbatch ✅
**Nouveau fichier :** `dbt/models/marts/core/fct_transactions_microbatch.sql` (copie de `fct_transactions.sql` adaptée)

**À faire :** config avec `incremental_strategy='microbatch'`, `event_time='date_transaction'`, `batch_size='day'`, `lookback=3` (dbt 1.9+ requis — vérifiez votre version dbt-fusion/dbt-core installée, cf `dbt --version`).

**Vérifier :**
```bash
dbt run --select fct_transactions_microbatch --target dev --full-refresh
```
Comparer le temps d'exécution à celui de `fct_transactions` (merge) sur un run incrémental équivalent.

**Critère de fin :** modèle qui tourne, temps mesuré et noté, recommandation motivée écrite (merge vs microbatch pour ce cas d'usage — pensez au fait que les updates de statut post-insertion ne collent pas naturellement au modèle microbatch qui traite des fenêtres d'`event_time` figées).

**Fait le 25/09.** `fct_transactions_microbatch.sql` créé. Deux obstacles techniques résolus en cours de route :
1. Cette version de dbt (1.12) n'expose **pas** de variable Jinja `event_time_start`/`event_time_end` utilisable directement dans le corps du modèle (contrairement à ce que suggère une partie de la doc dbt) — le filtrage par fenêtre n'est appliqué automatiquement par dbt QUE si le `ref()` amont a lui-même un `event_time` configuré. Ajouté `event_time='date_transaction'` sur `int_transactions_normalisees` (ephemeral — ça fonctionne quand même) pour que le filtrage s'injecte automatiquement.
2. Testé sur 1 semaine (7 batches) plutôt qu'un backfill complet 2 ans (~730 batches, disproportionné pour une exploration).

**Résultat chiffré (voir `docs/PERF_LOG.md` section dédiée) :** microbatch = 42s wall-clock pour 7 jours/9190 lignes, mais le calcul Snowflake réel n'est que de 0,4-1,3s par batch — l'essentiel du temps est de l'overhead d'orchestration dbt (1 requête par jour). Merge = 49,1s pour 945k lignes en 1 seule requête. **Recommandation : garder `merge`** au scale actuel (M/L) — à réévaluer si le volume quotidien atteint plusieurs millions de lignes/jour. Détail complet et point d'attention (léger décalage de fuseau horaire sur les bornes de batch, ~0,2% d'écart) documentés dans PERF_LOG.md.

### Étape 11 — Clustering & Search Optimization ✅
**Actions :**
1. `SELECT SYSTEM$CLUSTERING_INFORMATION('FCT_TRANSACTIONS');` (ou nom qualifié complet du schema `MARTS_CORE`) — noter le clustering depth
2. Si depth ≥ 3 : revoir la clé de clustering ou forcer un `ALTER TABLE ... RECLUSTER`
3. Décider (avec justification coût/bénéfice) d'activer Search Optimization sur `external_transaction_id` et `iban` — les commandes sont déjà écrites en commentaire dans `scripts/snowflake/04_performance_features.sql`, à décommenter/exécuter si la décision est oui
4. Dans Snowsight, repérer 3 requêtes BI fréquentes (jointures fct_transactions + dim, filtres tenant/date), ouvrir leur Query Profile, noter : bytes scanned, partitions scannées/total, % pruning, node dominant, spill local/remote

**Critère de fin :** les 3 Query Profiles sont capturés (texte ou capture d'écran), une décision claire est prise sur Search Optimization.

**Fait le 25/09.** Bug de drift trouvé : `raw_transactions` (RAW) était clusterée sur `(tenant_id, date_transaction)` — la colonne brute à cardinalité élevée — au lieu de `(tenant_id, DATE_TRUNC('MONTH', date_transaction))` comme documenté dans `02_ddl_raw_tables.sql`. Snowflake alertait lui-même sur le risque de reclustering coûteux. Corrigé via `ALTER TABLE ... CLUSTER BY`. `fct_transactions`, lui, avait déjà la bonne clé (dbt l'applique à la création) — depth 1.0, aucun souci.

Search Optimization testée pour de vrai (activée, mesurée, comparée, puis désactivée) sur `raw_transactions.external_transaction_id` : **0 bénéfice mesurable** au scale M — même plan de requête, mêmes partitions scannées (7/8) avant/après. À seulement 8 micro-partitions, l'optimiseur Snowflake n'active même pas le chemin d'accès SOS. Décision : ne pas l'activer en prod à ce volume, réévaluer au scale L/XL.

3 Query Profiles capturés avec des chiffres exacts (`GET_QUERY_OPERATOR_STATS`, pas d'estimation) : lookup non-clé (12,5% pruning), filtre tenant+mois (75% pruning, clé de clustering qui fonctionne comme prévu), jointure dashboard (75% pruning sur la table de faits même sans filtre de date). Détail complet dans `docs/PERF_LOG.md`.

### Étape 12 — Remplir PERF_LOG.md Sprint 3 ✅
**Fichier :** `docs/PERF_LOG.md`, sections "Baseline", "Après optimisations Sprint 3", "Analyse Query Profile", "Décisions prises".

**Critère de fin :** toutes les cellules des tableaux sont remplies avec de vrais chiffres avant/après, gains calculés en %, décisions justifiées par écrit.

**Fait le 25/09.** Tableaux remplis avec les mesures réelles des étapes 9-11 (rows/elapsed/depth par modèle, build complet 84,46s). Limite honnête documentée : ces mesures sont au scale M (1M tx) — l'objectif CTO (<1h sur 50-100M lignes) n'a pas été testé à cette échelle faute de temps/crédits ; recommandation explicite de rejouer le protocole au scale L avant mise en prod.

### Étape 13 — Checkpoint objectif de mission ✅
Vérifier que le run complet passe sous la barre des 1h (objectif CTO) :
```bash
time dbt build --target dev --exclude tag:todo
```
**Critère de fin :** temps mesuré et noté, écart par rapport à l'objectif documenté (même si pas encore atteint à ce stade, notez où vous en êtes).

**Fait le 25/09.** Build complet mesuré à **84,46 s** au scale M — très largement sous l'objectif d'1h. **Mais ce n'est pas une validation de l'objectif CTO** : la cible mission (50-100M lignes, scale XL) est ~50-100× le volume testé ici (1M lignes). À ce volume trivial (8 partitions), le temps de run ne dit quasiment rien sur le comportement à l'échelle réelle. Documenté honnêtement dans PERF_LOG.md : **il reste à rejouer ce protocole au scale L (10M lignes) minimum** pour une vraie validation de l'objectif "< 1h" — c'est un test de charge qui n'a pas pu être fait dans le cadre de cette mission (temps/crédits Snowflake), à faire avant mise en production.

**Phase C (Sprint 3, la partie critique) est complète pour le scale M testé**, avec cette réserve explicite sur le passage à l'échelle documentée pour le rapport final.

---

## Phase D — Sprint 4 : historisation & FX

### Étape 14 — Exécuter le snapshot et peupler l'historique ✅
```bash
dbt snapshot --select snapshot_comptes --target dev
```
Puis modifier manuellement le statut/KYC de 2-3 comptes dans `RAW.raw_comptes`, relancer le snapshot 3 fois (avec un peu de délai entre chaque si vous voulez des timestamps distincts) pour obtenir plusieurs versions historisées.

**Critère de fin :** `SELECT compte_id, COUNT(*) FROM snapshots.snapshot_comptes GROUP BY 1 ORDER BY 2 DESC` montre au moins un compte avec 2+ versions.

**Fait le 25/09.** Snapshot déjà initialisé (20 000 comptes) lors d'un build précédent. 4 changements provoqués sur 3 comptes, en 3 runs de snapshot successifs : `compte_id=12622` (actif→suspendu→actif, 3 versions), `compte_id=16167` (basic/actif→advanced/actif→advanced/cloture, 3 versions), `compte_id=5260` (aml_flag clean→watchlist_check, 2 versions). Historique vérifié via `dbt_valid_from`/`dbt_valid_to` — cohérent, chaînage correct.

### Étape 15 — Compléter `dim_comptes_scd2` ✅
**Fichier :** `dbt/models/marts/core/dim_comptes_scd2.sql`

**À faire :**
- Ajouter la surrogate key : `{{ dbt_utils.generate_surrogate_key(['compte_id', 'date_debut_validite']) }}`
- Ajouter `version_number` via `row_number() over (partition by compte_id order by date_debut_validite)`

**Vérifier :**
```bash
dbt run --select dim_comptes_scd2 --target dev
```
```sql
SELECT compte_id, COUNT(*) FROM dim_comptes_scd2 WHERE is_current GROUP BY 1 HAVING COUNT(*) != 1; -- doit être vide
```

**Critère de fin :** requête ci-dessus vide → exactement une version courante par compte.

**Fait le 25/09.** Surrogate key ajoutée (`dbt_utils.generate_surrogate_key(['compte_id', 'dbt_valid_from'])`), `version_number` via `row_number() over (partition by compte_id order by dbt_valid_from)`. Contrainte "1 version courante par compte" implémentée comme un vrai test dbt (`tests/assert_dim_comptes_scd2_one_current_version.sql`, pas juste une vérification manuelle) + tests `unique`/`not_null` sur `compte_sk` dans `_core.yml`. Vérifié sur les 3 comptes de test de l'Étape 14 : `version_number` 1/2/3 dans le bon ordre chronologique, `is_current` correct. 6/6 tests passants.

### Étape 16 — Valider le FX historisé ✅
Écrire une requête/test ad hoc (dans `dbt/analyses/` ou juste en SQL exploratoire) qui recalcule `montant_eur` pour 100 transactions échantillonnées et compare à la valeur stockée.

```sql
SELECT transaction_id,
       montant_eur AS montant_eur_calcule,
       montant * taux_change_applique AS montant_eur_source,
       ABS(montant_eur - montant * taux_change_applique) / NULLIF(montant_eur, 0) AS ecart_pct
FROM fct_transactions
SAMPLE (100 ROWS)
```

**Critère de fin :** écart moyen < 0.01% confirmé et noté quelque part (PERF_LOG ou DESIGN).

**Fait le 25/09.** Sur 100 transactions non-EUR, écart 0% entre `montant_eur` stocké et le recalcul indépendant depuis `int_fx_rates_daily`. Point notable : les 100 mêmes transactions diffèrent toutes du `taux_change_applique` brut de `raw_transactions` — preuve concrète que le recalcul depuis le référentiel est réellement nécessaire (pas un exercice théorique). Documenté dans `docs/PERF_LOG.md` section "Sprint 4.2".

**Phase D (Sprint 4) est complète.**

---

## Phase E — Sprint 5 : CI/CD & orchestration

### Étape 17 — Secrets GitHub et manifest prod ✅ (partiel — voir note)
1. Dans les settings du repo GitHub → Secrets → ajouter `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_CI_USER`, `SNOWFLAKE_CI_PASSWORD`
2. Dans `.github/workflows/dbt_ci.yml`, remplacer le placeholder de récupération du manifest (`echo "Placeholder..."`) par une vraie commande — au minimum un `aws s3 cp` ou équivalent si vous avez un stockage d'artifacts ; à défaut, générer le manifest prod localement une fois (`dbt compile --target prod` après un run réussi) et le committer dans un dossier `prod-artifacts/` versionné, en attendant une vraie solution de stockage
3. Vérifier que le target `ci` existe bien dans `profiles.yml.example`/votre `~/.dbt/profiles.yml`

**Critère de fin :** une PR de test déclenche le workflow et le job `lint` + `build-slim` s'exécutent sans erreur de config (même si le contenu du diff est minimal).

**Fait le 25/09 — ce qui était de mon ressort (pas d'accès GitHub, aucun remote configuré sur ce repo) :**
1. **Manifest prod** : remplacé le placeholder par un vrai mécanisme fonctionnel. `prod-artifacts/` est volontairement gitignoré (jamais commité) — au lieu d'inventer un S3 qui n'existe pas pour ce compte, créé `.github/workflows/dbt_prod_deploy.yml` (déclenché sur push vers `main`) qui build en `prod` et publie `manifest.json` comme artifact GitHub Actions ; `dbt_ci.yml` télécharge ce dernier artifact via `dawidd6/action-download-artifact` avant son build Slim CI, avec repli automatique sur un build complet si aucun artifact n'existe encore (tout premier PR).
2. **Version dbt en CI** : alignée sur `dbt-snowflake>=1.9,<2.0` (celle réellement validée dans cette mission) au lieu de `1.8.*` — évite une divergence entre ce qui a été testé ici et ce qui tournerait en CI.
3. **Bug trouvé : macro `drop_schema` inexistante.** Le cleanup CI (et le README) appellent `dbt run-operation drop_schema --args "{schema_name: ...}"`, mais cette macro n'existait nulle part dans le projet — le cleanup aurait toujours échoué. Créée dans `dbt/macros/drop_schema.sql`, testée avec succès.
4. **Bug trouvé : fragmentation de schéma en CI.** `generate_schema_name.sql` produisait un schéma différent par modèle en CI (`CI_staging_42`, `CI_marts_core_42`, ...), alors que le cleanup ne connaît qu'un seul nom (`CI_42`) — le nettoyage n'aurait jamais rien supprimé. Corrigé : en CI, tous les modèles d'un même PR partagent désormais un seul schéma `CI_<PR_ID>` (le `custom_schema_name` par modèle est ignoré uniquement dans cette branche).
5. **Testé en conditions réelles** (target `ci` local, `DBT_CI_PR_ID=test99`) : build isolé dans `CI_TEST99` confirmé (un seul schéma), puis `drop_schema` a bien supprimé le schéma — cycle complet validé.

**Ce qui reste de votre côté (accès GitHub requis, je ne peux pas le faire) :**
- Créer le repo GitHub (ou configurer le remote si vous en avez déjà un) et pousser cette branche.
- Ajouter les secrets du repo (Settings → Secrets and variables → Actions) : `SNOWFLAKE_ACCOUNT` (identifiant de compte, cf. Snowsight → Account Details), `SNOWFLAKE_CI_USER` (votre login), `SNOWFLAKE_CI_PASSWORD`, et pour le workflow de déploiement prod : `SNOWFLAKE_PROD_USER`, `SNOWFLAKE_PRIVATE_KEY` (contenu de la clé privée p8 pour l'auth par paire de clés du target `prod`), `SNOWFLAKE_PRIVATE_KEY_PASSPHRASE` si la clé en a une.
- Ouvrir une PR de test pour vérifier que `dbt_ci.yml` passe au vert (c'est aussi le livrable final "PR de démonstration", Phase G).

### Étape 18 — Compléter le DAG Airflow ✅
**Fichier :** `orchestration/airflow_dag_fintrack.py`

**À faire :**
- Sensors de fraîcheur sur les sources (S3/API) avant le `TaskGroup("ingestion")`
- Notification Slack sur échec : ajouter `on_failure_callback` avec `SlackWebhookOperator` (ou callback custom)
- Différencier les `retries`/`retry_delay` entre ingestion (souvent plus de retries, réseau instable) et transformation dbt (moins de retries, coûteux en warehouse)
- Ajouter un `sla=timedelta(...)` par tâche cohérent avec les SLA fraîcheur du briefing (2h gold / 6h silver / 24h bronze)

**Critère de fin :** DAG qui se parse sans erreur (`python orchestration/airflow_dag_fintrack.py` ou `airflow dags list` si vous avez un Airflow local), tous les points ci-dessus couverts.

**Fait le 25/09.** Les 4 points complétés :
1. `FileSensor` de fraîcheur avant l'ingestion (mode `reschedule`, commenté pour expliquer qu'un vrai déploiement AWS utiliserait `S3KeySensor` — gardé en `FileSensor` pour rester cohérent avec le mode d'upload actuel du projet, PUT local vers stage Snowflake).
2. Notification Slack sur échec via `on_failure_callback` (connexion Airflow `slack_webhook` à créer), appliqué au niveau du DAG donc à toutes les tâches.
3. Retries différenciés : ingestion 4 essais/2min avec backoff exponentiel (échecs souvent transitoires), dbt 1 seul essai/5min (un échec de modèle est déterministe — retenter ne corrige rien et gaspille des crédits warehouse).
4. SLA en échelle cumulative depuis le début du run, plafonnée à 2h sur `dbt_test` (la tâche critique la plus tardive) — aligné sur la SLA de fraîcheur la plus stricte (tenants gold, cf. MISSION.md).

**Limite honnête :** Airflow n'est pas installé dans cet environnement (ni dans `requirements.txt`, ni dans le `.venv` — installer le package complet pour un seul fichier aurait été disproportionné). Seule la syntaxe Python a été vérifiée (`py_compile`, OK). **Le DAG n'a pas été testé contre une vraie instance Airflow** — contrairement au reste de la mission qui a été validé en conditions réelles contre Snowflake. À faire de votre côté avant mise en prod : `airflow dags list-import-errors` (ou équivalent) sur une instance réelle, et vérifier que la connexion `slack_webhook` + les chemins (`/opt/data/...`, `/opt/dbt/...`, `/opt/scripts/...`) correspondent à votre déploiement.

**Phase E (Sprint 5, CI/CD & orchestration) est complète pour tout ce qui ne nécessite pas d'accès GitHub/Airflow externe.**

---

## Phase F — Sprint 6 : analytics avancés, contracts, bonus

### Étape 19 — `mart_cohortes_retention` ✅
**Fait le 05/10.** Spine 0..12 via `table(generator(rowcount => 13))`, `cross join` cohortes × offsets, `left join` des comptes actifs (≥ 1 tx `validee` dans le mois). Exclusion des mois pas encore écoulés (sinon les cohortes récentes afficheraient 0 %). Tests dans `marts/analytics/_analytics.yml` (unicité cohorte+offset, taux entre 0 et 100). Exécuté et vérifié le 05/10 sur le nouveau compte (voir plus bas).

**Fichier :** `dbt/models/marts/analytics/mart_cohortes_retention.sql`

**À faire :** construire une "spine" de `mois_offset` (0 à 12) croisée avec chaque cohorte (`cross join`), puis pour chaque `(cohort_mois, mois_offset)` compter les comptes de la cohorte ayant eu au moins 1 transaction validée dans le mois `cohort_mois + mois_offset`. Calculer `taux_retention_pct = nb_utilisateurs_actifs / nb_utilisateurs_cohorte * 100`.

**Vérifier :** `dbt run --select mart_cohortes_retention --target dev` puis contrôle visuel que le taux décroît globalement avec `mois_offset` croissant (comportement attendu en rétention).

### Étape 20 — `mart_transactions_anomalies` ✅
**Fait le 05/10.** Fenêtre `ROWS BETWEEN 90 PRECEDING AND 1 PRECEDING` (transaction courante exclue de sa propre moyenne), historique minimum de 10 tx avant de scorer, `is_anomalie = |z| > 3`, sévérité low/medium/high (NULL hors anomalie). Unit test `unit_tests/test_mart_transactions_anomalies.yml` + tests génériques.

**Fichier :** `dbt/models/marts/analytics/mart_transactions_anomalies.sql`

**À faire :** window functions `AVG()` et `STDDEV()` sur `montant_eur` par `compte_id`, fenêtre glissante `ROWS BETWEEN 89 PRECEDING AND CURRENT ROW` (approximation 90 jours en nombre de transactions, ou passer par une jointure sur une fenêtre de dates si vous voulez du temporel strict). Calculer `z_score = (montant_eur - moyenne_90j) / NULLIF(ecart_type_90j, 0)`, `is_anomalie = ABS(z_score) > 3`, `severite` en fonction de la magnitude du z-score (ex : low <4, medium <6, high ≥6).

**Vérifier :** `SELECT COUNT(*) FROM mart_transactions_anomalies WHERE is_anomalie` — doit être un nombre non nul mais raisonnable (pas 50% des lignes).

### Étape 21 — Contracts et versioning ✅
**Fait le 05/10.** `contract.enforced: true` sur `fct_transactions` (43 colonnes typées, précision explicite sur les montants), `versions:` v1 (fichier et nom de table inchangés via `defined_in` + `alias`, dépréciation 2027-03-31) et v2 (`fct_transactions_v2.sql` = v1 + `montant_hors_taxes`, prérelease). `exposures.yml` créé. Exécuté le 05/10 : contrat respecté du premier coup. Au passage, le lookback des incrémentaux utilise maintenant vraiment `var('incremental_lookback_days')` (il était codé en dur à 7, ce qui ne respectait pas le critère de la US 3.1).

1. Dans `dbt/models/marts/core/_core.yml`, passer `contract.enforced: true` sur `fct_transactions`
2. Créer un nouveau fichier modèle `fct_transactions_v2.sql` (copie de v1 + colonne `montant_hors_taxes`), déclarer le bloc `versions:` dans `_core.yml` selon l'exemple déjà présent dans `docs/CONTRACTS.md`
3. `dbt run --select fct_transactions fct_transactions_v2 --target dev` pour valider que le contrat est respecté (dbt refusera de builder si les types déclarés dans `_core.yml` ne matchent pas la sortie SQL)

**Critère de fin :** build vert avec contract enforced, v1 et v2 coexistent.

### Étape 22 — Data Observability (bonus, si le temps le permet) ⏳ non fait
Non fait. Snowflake est de nouveau disponible depuis le 05/10, donc cette étape est faisable. Procédure ci-dessous.

1. Décommenter `elementary-data/elementary` dans `dbt/packages.yml`, `dbt deps`
2. Configurer et générer le rapport HTML (`edr report` ou équivalent selon la CLI Elementary installée)
3. Repérer et documenter au moins 1 anomalie de volumétrie détectée

### Remontée sur un nouveau compte Snowflake et exécution du Sprint 6 ✅ (05/10)
L'essai gratuit a expiré : tout a été remonté sur un nouveau compte depuis les scripts du repo (infra, DDL, PUT/COPY, droits), puis `dbt build --full-refresh` : **120 PASS, 1 WARN attendu, 0 erreur, 100,2 s (124 nœuds)**. Détail dans `docs/PERF_LOG.md`.

Résultats Sprint 6 vérifiés en base :
- **Contrat** : v1 = 43 colonnes, v2 = 44 ; `montant_eur` en `NUMBER(38,2)` (centimes conservés) ; `montant_hors_taxes` exact sur 100 % des lignes.
- **Cohortes** : rétention stable autour de 85 % de M+0 à M+12. C'est attendu, le générateur ne simule pas d'attrition. Découverte : **53,5 % des transactions précèdent l'ouverture de leur compte** (dates générées indépendamment). Le mart ne garde plus que les cohortes entièrement observables, et un test de qualité en `warn` (`tests/assert_transactions_apres_ouverture_compte.sql`) signale l'incohérence.
- **Anomalies** : 3,3 % des transactions (29 972), réparties comme les volumes par devise. C'est plus que les 0,3 % d'une loi normale, car les montants suivent une loi log-normale à queue lourde. Piste : z-score sur `log(montant)`.

🐞 **Bug majeur trouvé grâce au mart d'anomalies : conversion FX inversée.** Le JPY faisait 34 % des anomalies pour 2 % des volumes. Le référentiel est coté EUR → devise, donc il faut **diviser** par le taux, alors que `fct_transactions` multipliait (67 JPY comptés 11 624 €). La validation de l'étape 16 l'avait manqué parce qu'elle réutilisait la même formule. Corrigé, verrouillé par `unit_tests/test_fct_transactions_fx.yml`, puis revalidé contre `raw_fx_rates` brut : 0 % d'écart.

Preuves rejouées sur le nouveau compte :
- **Merge (étape 9), cette fois avec un vrai delta** : 1,1 % des lignes retraitées, statut mis à jour, nouvelle ligne insérée, 0 doublon. Temps identique au full-refresh au scale M : le MERGE réécrit les 8 micro-partitions de la table.
- **SCD2 (étapes 14-15)** : comptes 12622 (3 versions), 16167 (3), 5260 (2) ; une seule version courante par compte.

Autres corrections : requête `COPY_HISTORY` invalide dans `03_stage_and_copy.sql` ; prototype microbatch désactivé par défaut (il rejouait 1 374 jours dans chaque build sur une base vide).

### Préparation de la CI (06/10) ✅
- **`profiles.yml` absent en CI** : le workflow cherchait `dbt/profiles.yml`, or ce fichier est gitignoré, et le `profiles.yml.example` cité dans le README n'existe pas. La CI aurait échoué dès `dbt deps`. Le fichier est désormais généré dans le workflow (jobs `lint` et `build-slim`) à partir des secrets via `env_var()`.
- **Lint sqlfluff : 95 violations → 0.** `sqlfluff fix` pour les cas automatiques, correction à la main pour les 11 autres (références qualifiées dans les sous-requêtes de lookback, alias explicites dans la CTE récursive, `GROUP BY` explicite).
- **Non-régression vérifiée** par empreinte (`count(*)` + `hash_agg(*)`) des 22 tables avant/après : 18 identiques ; 3 diffèrent uniquement parce qu'elles utilisent `current_date()` et que la date a changé entre les deux builds ; la 4e a révélé le bug ci-dessous.
- 🐞 **`mart_solde_journalier` avait un grain faux.** Il regroupait par le `tenant_id` de la transaction, qui diffère de celui du compte dans 87,4 % des cas (données synthétiques). Résultat : 24 269 doublons (compte, jour), et un solde cumulé **non déterministe** (égalités dans l'`ORDER BY` de la fenêtre, résultat différent à chaque run). Corrigé : grain = (compte, jour), tenant pris dans `dim_comptes`. Ajout de `marts/finance/_finance.yml` avec un test d'unicité. Résultat identique sur 2 runs consécutifs.
- Build complet : **123 PASS, 1 WARN attendu, 0 erreur.**

---

## Phase G — Clôture

### Étape 23 — `docs/DESIGN.md` ✅
**Fait le 05/10** : Kimball vs Data Vault, bridge, matérialisations, clustering, stratégie incrémentale, CI/CD.

Compléter les sections encore vides : "Choix Kimball vs Data Vault" (justifier Kimball vu le contexte BI multi-tenant) et "Bridge tables" (décrire le pattern `bridge_comptes_titulaires` mis en place à l'étape 6).

### Étape 24 — `docs/CONTRACTS.md` ✅
**Fait le 05/10.**

Remplacer le template par la stratégie réellement appliquée à l'étape 21 (dates de dépréciation réelles, consommateurs réels si connus, etc.).

### Étape 25 — PR de démonstration ✅
**Fait le 06/10** : PR #1 `feat/perf-scale-sprints-2-6` → `main`, **CI verte** (lint sqlfluff + Slim CI en build complet : 123 PASS, puis nettoyage du schéma `CI_1`).

Trois bugs du workflow, invisibles tant qu'aucune vraie PR n'avait tourné, ont été corrigés en route :
1. **Lint en exit 128** : clone superficiel, donc `git diff origin/main...HEAD` sans merge-base. Ajout de `fetch-depth: 0`.
2. **`DBT_PROFILES_DIR: ./dbt` relatif** : les steps dbt tournent dans `./dbt`, le chemin pointait donc vers `dbt/dbt/`. Passé en chemin absolu (`${{ github.workspace }}/dbt`).
3. **Récupération du manifest prod en 404** : `dbt_prod_deploy.yml` n'existe pas encore sur `main` au premier PR, et `if_no_artifact_found` ne couvre pas ce cas. Étape passée en `continue-on-error`, avec retour automatique au build complet.

S'y ajoute un piège de lint : l'indentation attendue autour de `{% if is_incremental() %}` différait selon que la table existe (dev) ou non (CI). Le lint passait en local et échouait en CI. Corrigé dans `fct_virements` en isolant le filtre incrémental dans sa propre CTE.

⚠️ Avant de merger : désactiver le workflow **dbt Prod Deploy** (Actions → dbt Prod Deploy → ⋯ → Disable workflow). Il n'a pas d'authentification par clé configurée et échouerait à chaque push sur `main`.

Ouvrir une PR (branche `feat/...` selon la convention du README) regroupant un sous-ensemble représentatif des changements, vérifier que la CI passe entièrement au vert (lint + slim build + cleanup).

### Étape 26 — Rapport final (2-3 pages) ✅
**Fait le 05/10** : `docs/RAPPORT_FINAL.md`.

Répondre aux 4 questions du `MISSION.md` :
1. Gains de performance chiffrés (issus de `PERF_LOG.md`)
2. Merge vs microbatch — pourquoi ce choix (issu de l'étape 10)
3. 3 principaux risques opérationnels du pipeline en prod
4. Comment scaler ×10 (1 milliard tx/mois) — architecture cible

---

## Suivi rapide

| Phase | Étapes | Statut |
|---|---|---|
| A — Fondations données | 1-2 | ✅ |
| B — Sprint 2 modèles core | 3-8 | ✅ |
| C — Sprint 3 perf (critique) | 9-13 | ✅ (scale M — L/XL non testé, cf. réserve Étape 13) |
| D — Sprint 4 historisation/FX | 14-16 | ✅ |
| E — Sprint 5 CI/CD & orchestration | 17-18 | ✅ (partiel — secrets GitHub/test Airflow réel restent à faire par vous) |
| F — Sprint 6 analytics/contracts/bonus | 19-22 | ✅ 19-21 exécutés et vérifiés (05/10) ; 22 (Elementary) non fait |
| G — Clôture | 23-26 | ✅ docs, rapport, PR #1 avec CI verte |

Mettez à jour les ✅/⬜ au fil de l'eau — dites-moi à quelle étape vous voulez qu'on démarre et je vous accompagne dessus en détail.
