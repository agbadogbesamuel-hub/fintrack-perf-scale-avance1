# Model contracts & versioning

Stratégie appliquée en Sprint 6 (étape 21). Fichiers concernés :
`dbt/models/marts/core/_core.yml`, `fct_transactions.sql` (v1),
`fct_transactions_v2.sql` (v2), `dbt/models/exposures.yml`.

## Modèles publics

| Modèle | Contrat | Version(s) | Consommateurs (cf. `exposures.yml`) |
|--------|---------|------------|--------------------------------------|
| fct_transactions | **enforced** (43 colonnes typées) | v1 = latest, v2 = prérelease | Dashboard exécutif, sync CRM Hightouch, marts finance/analytics |
| dim_comptes | non (prochain candidat) | — | Sync CRM Hightouch |
| mart_tenant_kpis_daily | non (prochain candidat) | — | Dashboard exécutif |

## Ce que garantit le contrat

`contract.enforced: true` sur `fct_transactions` : à chaque build, dbt compare
les colonnes produites par le SQL (noms **et** types) avec celles déclarées dans
`_core.yml`. Une colonne renommée, supprimée ou dont le type change fait échouer
le build **avant** que la table ne soit modifiée. Un dashboard ne casse donc plus
par accident.

Deux points d'implémentation :

- **Types numériques avec précision explicite** (`number(38,2)` pour les montants).
  Sous contrat, dbt crée la table avec les types du YAML. Un `number` nu devient
  `NUMBER(38,0)` sur Snowflake et arrondirait silencieusement les montants à l'euro.
- **Contrainte `not_null` sur `transaction_id`**, réellement appliquée par
  Snowflake. Les autres contraintes (PK, FK) ne sont pas vérifiées par Snowflake,
  elles restent donc portées par les tests dbt (`unique`, `relationships`).

## Versioning : v1 → v2

| | v1 | v2 |
|---|---|---|
| Fichier | `fct_transactions.sql` (`defined_in`) | `fct_transactions_v2.sql` |
| Table Snowflake | `fct_transactions` (`alias`, nom inchangé) | `fct_transactions_v2` |
| Changement | — | + `montant_hors_taxes` (montant_eur / (1 + TVA)) |
| `ref('fct_transactions')` pointe vers | **oui** (`latest_version: 1`) | non, `ref('fct_transactions', v=2)` explicite |
| Date de dépréciation | 2027-03-31 | — |

Choix assumés :

- **v1 garde son nom de table et son fichier.** Aucun dashboard ni historique
  incrémental n'est cassé par l'introduction du versioning.
- **v2 lit v1** (`select v1.*, ... from ref('fct_transactions', v=1)`) au lieu de
  dupliquer la logique (FX, filtres de statut). Il n'y a qu'une seule source de
  vérité, et v2 reste incrémental (merge, même lookback).
- **v2 n'est pas encore `latest`.** C'est une prérelease : les consommateurs
  l'adoptent quand ils sont prêts. Une fois tous migrés, on passe
  `latest_version: 2`.
- `deprecation_date` sur v1 : dbt émet un avertissement à chaque compilation d'un
  modèle qui référence v1. C'est le rappel automatique de migration.

## Processus de migration (rupture de contrat)

1. Créer `_vN+1` avec les changements, en `versions:` dans le YAML (contrat hérité
   via `include: all`, colonnes ajoutées/retirées explicitement).
2. Déclarer / vérifier les consommateurs dans `exposures.yml` et les prévenir
   (#data-platform).
3. Poser une `deprecation_date` sur l'ancienne version, **≥ 30 jours** après
   l'annonce.
4. Les consommateurs migrent vers `ref('modele', v=N+1)`. Une fois tous migrés,
   passer `latest_version: N+1`.
5. À la date de dépréciation, supprimer l'ancienne version (fichier + entrée YAML).

Changements **non cassants** (ajout de colonne optionnelle) : pas besoin de
nouvelle version. On ajoute la colonne au SQL et au YAML dans la même PR, et
`on_schema_change='append_new_columns'` l'ajoute à la table incrémentale.
v2 sert ici de démonstration du mécanisme.

## Validation (05/10)

Exécuté sur Snowflake (`dbt build --full-refresh`) : contrat respecté du premier coup.

- `fct_transactions` (v1) : 43 colonnes ; `fct_transactions_v2` : 44 colonnes.
- `montant_eur` créé en `NUMBER(38,2)` : les centimes sont conservés sur 935 628 lignes, ce
  qui confirme l'intérêt de la précision explicite.
- `montant_hors_taxes = round(montant_eur / 1.2, 2)` vérifié sur 100 % des lignes de v2.

Pour un environnement où `fct_transactions` existait avant le contrat, la première
exécution doit être un `--full-refresh`, afin de recréer la table avec les types du contrat.
