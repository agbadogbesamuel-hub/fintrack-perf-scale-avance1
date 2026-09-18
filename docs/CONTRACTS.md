# Model contracts & versioning

À remplir en Sprint 6.

## Modèles publics (contract enforcé)

| Modèle | Version | Consommateurs |
|--------|---------|---------------|
| fct_transactions | v1 (draft) | Metabase, Hightouch, Data Science |
| dim_comptes | v1 (draft) | Metabase, CRM sync |
| mart_tenant_kpis_daily | v1 (draft) | Dashboard exécutif |

## Stratégie de migration

Quand casser le contrat d'un modèle public :

1. Créer une nouvelle version `_v2` avec les changements
2. Marquer l'ancienne comme `deprecated` avec date de retrait
3. Notifier les consommateurs via `exposures.yml`
4. Attendre 30 jours minimum
5. Supprimer l'ancienne version

## Exemple

```yaml
models:
  - name: fct_transactions
    latest_version: 2
    config:
      contract:
        enforced: true
    versions:
      - v: 1
        defined_in: fct_transactions_v1
        deprecation_date: '2024-12-31'
      - v: 2
        defined_in: fct_transactions_v2
```
