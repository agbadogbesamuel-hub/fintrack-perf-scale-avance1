-- ============================================================
-- FCT TRANSACTIONS — table de faits principale
-- ============================================================
-- Volume cible : 50-100M lignes.
-- Stratégie : incremental merge sur transaction_id,
-- clustering (tenant_id, mois), colonnes essentielles seulement.
--
-- TODO (Sprint 3) — Optimisations à explorer :
--   1. Passer sur microbatch strategy (dbt 1.9+) pour traitement
--      par fenêtres temporelles
--   2. Ajouter Search Optimization sur external_transaction_id
--   3. Envisager un modèle versioning (v1 / v2) via dbt contracts
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key='transaction_id',
        incremental_strategy='merge',
        merge_update_columns=['statut', 'is_reconciled', 'aml_flag',
                              'aml_score', 'fraud_score', 'montant_eur',
                              'updated_at'],
        cluster_by=['tenant_id', "date_trunc('month', date_transaction)"],
        on_schema_change='append_new_columns',
        tags=['marts', 'core', 'fct', 'incremental', 'critical'],
        pre_hook=[
            "{{ log_incremental_run('fct_transactions', 'pre') }}"
        ],
        post_hook=[
            "{{ log_incremental_run('fct_transactions', 'post') }}"
        ]
    )
}}

with base as (
    select * from {{ ref('int_transactions_normalisees') }}

    {% if is_incremental() %}
        where _loaded_at >= (select dateadd('day', -7, max(_loaded_at)) from {{ this }})
    {% endif %}
),

fx as (
    select
        date_cotation,
        devise_cible as devise,
        taux
    from {{ ref('int_fx_rates_daily') }}
)

select
    -- Clés
    b.transaction_id,
    b.external_transaction_id,
    b.tenant_id,
    b.compte_id,
    b.categorie_id,

    -- Temporalité
    b.date_transaction,
    b.jour_transaction,
    b.semaine_transaction,
    b.mois_transaction,
    b.date_valeur,
    b.date_settlement,

    -- Montants
    b.montant,
    b.devise,
    -- Recalcul FX depuis notre référentiel (source de vérité)
    round(b.montant * coalesce(fx.taux, b.taux_change_applique, 1), 2) as montant_eur,
    b.montant_signe,
    b.montant_signe_eur,
    b.frais,
    b.montant_net,

    -- Type et statut
    b.type_operation,
    b.sens,
    b.statut,
    b.moyen_paiement,
    b.canal,

    -- Enrichissements
    b.type_compte,
    b.customer_segment,
    b.pays_compte,
    b.nom_categorie,
    b.type_categorie,
    b.groupe,

    -- Marchand
    b.marchand_nom,
    b.marchand_categorie,
    b.marchand_pays,
    b.marchand_mcc,

    -- Compliance
    b.aml_score,
    b.aml_flag,
    b.fraud_score,
    b.is_flagged_for_review,

    -- Rapprochement
    b.is_reconciled,
    b.reconciliation_batch_id,

    -- Metadata
    b.source_system,
    b.created_at,
    b.updated_at,
    b._loaded_at

from base b
left join fx
    on b.jour_transaction = fx.date_cotation
   and b.devise = fx.devise
where b.statut in ('validee', 'en_attente')
  and b.is_reversal = false
