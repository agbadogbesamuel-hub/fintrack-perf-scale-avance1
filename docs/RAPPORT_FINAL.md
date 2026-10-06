# Rapport final — Mission FinTrack Perf & Scale

**Périmètre testé :** Snowflake + dbt-core 1.12 (dbt-snowflake), dataset synthétique scale **M**
(1 000 000 transactions, 20 000 comptes, 8 tenants, 2 ans d'historique).
**Sources des chiffres :** `docs/PERF_LOG.md` (mesures réelles issues de `QUERY_HISTORY`,
`COPY_HISTORY` et `GET_QUERY_OPERATOR_STATS`, pas d'estimations).

---

## 1. Gains de performance obtenus

| Mesure | Résultat | Commentaire |
|---|---|---|
| Build complet (`dbt build --full-refresh`, 124 nœuds : modèles + tests + unit tests) | **100,2 s** (nouveau compte) ; 84,5 s pour 88 nœuds sur l'ancien | objectif CTO < 1 h |
| `fct_transactions` (945 243 lignes) | 15,3 s | 1 seule requête `MERGE` |
| `stg_transactions` (1 M lignes) | 23,7 s | merge complet |
| Clustering depth `fct_transactions` | **1,0** | cible < 3 |
| Pruning requête BI tenant + mois | **75 %** des partitions écartées | clé `(tenant_id, mois)` efficace |
| Chargement initial | PUT 449,7 s / COPY 49,1 s | 90 % du temps = upload réseau |
| Exactitude FX (100 tx non-EUR) | **0 % d'écart** vs `raw_fx_rates` brut, après correction du sens de conversion | cible < 0,01 % |
| Incrémental : lignes retraitées par run | **1,1 %** (10 582 / 945 243) | temps identique au full-refresh au scale M, cf. limite |

**Leviers mis en place :**
- **Incrémental merge avec lookback** (`stg_transactions`, `fct_transactions`, `fct_virements`) :
  seules les données chargées dans les N derniers jours sont retraitées, et non les
  50-100 M lignes à chaque run. C'est le levier principal face au « 4 h en prod ».
- **Clustering aligné sur les filtres BI**, avec correction d'une dérive sur `raw_transactions`
  (clé sur timestamp brut, à forte cardinalité, que Snowflake signalait comme coûteuse).
- **Décisions par la mesure** : Search Optimization et microbatch ont été testés puis
  **écartés** parce que mesurés sans gain au volume actuel. On évite ainsi des coûts
  inutiles (objectif ÷2 sur le compute).
- **Fiabilisation** : 15+ bugs bloquants ou silencieux corrigés. Les deux plus graves :
  - `_loaded_at` NULL sur 100 % des lignes, qui aurait rendu chaque run incrémental vide
    sans lever d'erreur : le pipeline aurait cessé de rafraîchir les données en prod.
  - **Conversion FX inversée** (`montant * taux` au lieu de `montant / taux`, le référentiel
    étant coté EUR → devise). Les montants EUR de 45 % des transactions étaient faux
    (67 JPY comptés 11 624 €). Une première validation l'avait manqué parce qu'elle réutilisait
    la même formule. C'est le mart d'anomalies qui l'a révélé. C'est désormais verrouillé
    par un test unitaire.

**Limite mesurée de l'incrémental :** sur un vrai delta (1,1 % des lignes), le run
incrémental prend le même temps que le full-refresh (environ 12 s). Le profil du `MERGE`
montre pourquoi : Snowflake réécrit des micro-partitions entières, et la table n'en compte
que 8. Toute mise à jour touche donc toutes les partitions. Le gain n'apparaît qu'à grande
échelle (milliers de partitions rangées par tenant et par mois). Pistes :
`incremental_predicates`, et ne mettre à jour que les lignes réellement modifiées.

**Limite à assumer :** ces chiffres sont au scale M, soit 50 à 100× moins que la prod
(8 micro-partitions seulement). Ils montrent que l'architecture fonctionne, **pas** que
l'objectif « < 1 h sur 100 M lignes » est atteint. Le protocole (build chronométré +
`SYSTEM$CLUSTERING_INFORMATION` + Query Profiles) est documenté et doit être rejoué au
scale L (10 M) au minimum avant la mise en prod. Il n'a pas été possible de mesurer
l'objectif de coût (÷2) faute d'historique de facturation de l'ancien pipeline sur ce
compte.

---

## 2. Merge plutôt que microbatch : pourquoi

| | Merge | Microbatch |
|---|---|---|
| Mesure | 49,1 s pour 945 k lignes, 1 requête | 42 s pour **7 jours / 9 190 lignes**, 7 requêtes |
| Calcul Snowflake réel | — | 0,4 à 1,3 s par batch |
| Temps dominant | le calcul | l'**overhead dbt** par batch (compilation, connexion, table temporaire) |

**Choix : merge**, pour trois raisons :
1. **Le cas métier central est la mise à jour de statut** : une transaction `en_attente`
   qui devient `validee` plusieurs jours après. Le merge le couvre nativement (lookback +
   `merge_update_columns`, testé : 0 doublon, statut bien mis à jour). Le microbatch
   découpe par `event_time` (date de transaction) figé. Il faut donc un `lookback`
   suffisant pour retraiter les vieux jours, et la logique devient plus fragile.
2. **À ~1 300 tx/jour**, l'overhead fixe par batch écrase le calcul : 7× plus de requêtes
   pour un volume dérisoire.
3. **Exploitabilité** : une seule requête à auditer par run.

Point d'attention relevé : les bornes de batch suivent le fuseau horaire de la session
(≈ 0,2 % d'écart observé). **Le microbatch redevient pertinent** à plusieurs millions de
lignes par jour, pour paralléliser un backfill sur plusieurs warehouses ou rejouer un
seul jour en échec (cf. §4).

---

## 3. Les 3 principaux risques opérationnels en production

1. **Échec silencieux de l'incrémental.** La fraîcheur repose entièrement sur `_loaded_at`
   (déjà trouvé NULL partout une fois). Tout chargement qui ne remplit pas cette colonne,
   ou un retard supérieur au lookback de 7 jours, fait « réussir » les runs sans nouvelles
   données.
   *Mitigation :* tests `source freshness` sur `_loaded_at` branchés sur les SLA (2 h / 6 h
   / 24 h), test `not_null` sur `_loaded_at` en RAW, alerte Slack déjà câblée dans le DAG,
   moniteurs de volumétrie Elementary.
2. **Dérive entre le code et l'état réel de Snowflake.** Exemples vécus : clé de clustering
   modifiée hors code, tables `audit` absentes de `FINTRACK_DEV`, schéma CI fragmenté.
   Les scripts SQL hors dbt (`scripts/snowflake/*.sql`) ne sont pas rejoués
   automatiquement.
   *Mitigation :* infrastructure as code (Terraform / schemachange) pour le hors-dbt,
   contrats dbt (en place sur `fct_transactions`), vérification périodique de
   `SYSTEM$CLUSTERING_INFORMATION`.
3. **Coût et performance au vrai volume non validés.** Pas de test de charge au-delà de
   1 M lignes. Une seule jointure mal prunée ou une fenêtre (`mart_transactions_anomalies`,
   `mart_solde_journalier`) en `table` full rebuild peut faire exploser crédits et SLA à
   100 M lignes. Les secrets GitHub, la CI et le DAG Airflow n'ont pas encore tourné sur
   une vraie infrastructure.
   *Mitigation :* test au scale L avant go-live, resource monitors 75/90/100 % (Sprint 1),
   query_tag par modèle pour attribuer les coûts, passage en incrémental des marts lourds.

---

## 4. Absorber 10× le volume (1 milliard de transactions / mois)

À ~33 M transactions par jour, le batch toutes les quelques heures ne tient plus les SLA
gold (2 h). Architecture cible :

**Ingestion :** remplacer le `PUT` local (déjà 90 % du temps de chargement au scale M) par
un **stage externe S3 + Snowpipe / Snowpipe Streaming** alimenté en continu par les
tenants. Les fichiers sont découpés en 100-250 Mo compressés pour paralléliser le COPY.

**Transformation :**
- **Passage au microbatch** sur `fct_transactions` (batch jour, voire heure). À ce volume,
  le calcul domine l'overhead, et les backfills deviennent parallélisables et rejouables
  jour par jour. Les mises à jour de statut sont gérées via `lookback` sur les jours
  récents.
- Ou **Dynamic Tables** Snowflake avec `TARGET_LAG` par niveau de SLA (gold 1 h,
  silver 4 h) pour les marts agrégés, ce qui retire une partie de l'orchestration.
- `int_transactions_normalisees` passe d'ephemeral à table incrémentale, pour ne plus
  recalculer les jointures d'enrichissement à chaque run.
- Tous les marts lourds en incrémental (`mart_solde_journalier`, anomalies).

**Stockage et requêtes :** clustering conservé `(tenant_id, mois)`, éventuellement
`(tenant_id, jour)` sur les faits très chauds. **Search Optimization réactivée** sur
`external_transaction_id` / `iban` : à des milliers de partitions, le lookup ponctuel
(12,5 % de pruning aujourd'hui) devient rentable. Materialized views ou Dynamic Tables
pour les KPIs du dashboard exécutif.

**Compute et isolation :** warehouses par classe de SLA (gold sur un warehouse dédié
multi-cluster), voire **par tenant** pour les plus gros, afin d'éviter les effets « voisin
bruyant » et de refacturer le coût exact à chaque banque. Query_tag par modèle et par tenant.

**Gouvernance :** contrats étendus à tous les modèles publics, Elementary pour la
volumétrie et la fraîcheur, row access policies par `tenant_id` (isolation stricte des
données entre banques concurrentes).

---

## Livrables et état

| Livrable | État |
|---|---|
| Repo dbt complet, modèles testés | ✅ Sprints 1-6 exécutés sur Snowflake (nouveau compte, 05/10) : 120 PASS, 1 WARN attendu, 0 erreur |
| `docs/PERF_LOG.md` | ✅ |
| `docs/DESIGN.md` | ✅ |
| `docs/CONTRACTS.md` | ✅ |
| PR de démonstration, CI verte | ⏳ nécessite un repo GitHub + secrets (workflows prêts) |
| Rapport Elementary (bonus) | ⏳ non réalisé, nécessite un warehouse actif |
