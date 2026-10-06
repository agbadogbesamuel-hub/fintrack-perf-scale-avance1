-- ============================================================
-- FCT TRANSACTIONS — prototype microbatch (dbt 1.9+, expérimental)
-- ============================================================
-- US 3.2 : évaluer incremental_strategy='microbatch' en remplacement
-- du merge classique de fct_transactions.sql. Même logique métier,
-- seule la stratégie d'incrémentalité change.
--
-- Le microbatch découpe l'exécution en une requête par fenêtre
-- event_time (ici 1 jour), avec un lookback de 3 jours pour capturer
-- les mises à jour tardives (ex: passage en_attente -> validee).
--
-- dbt (1.9+) injecte automatiquement le filtre de fenêtre temporelle
-- dans le ref() du modèle amont configuré avec event_time (voir
-- int_transactions_normalisees.sql) — pas besoin de filtrer
-- manuellement ici, même si ce ref est ephemeral.
--
-- Désactivé par défaut : sur une base vide, dbt rejouerait chaque jour
-- depuis `begin` (~1 400 batches, ~2h30) dans chaque build standard.
-- Pour le relancer sur une fenêtre bornée :
--   dbt run --select fct_transactions_microbatch --     --vars '{enable_microbatch_prototype: true}' --     --event-time-start 2024-06-01 --event-time-end 2024-06-08
-- ============================================================

{{
    config(
        enabled=var('enable_microbatch_prototype', false),
        materialized='incremental',
        incremental_strategy='microbatch',
        unique_key='transaction_id',
        event_time='date_transaction',
        batch_size='day',
        lookback=3,
        begin='2023-01-01',
        merge_update_columns=['statut', 'is_reconciled', 'aml_flag',
                              'aml_score', 'fraud_score', 'montant_eur',
                              'updated_at'],
        cluster_by=['tenant_id', "date_trunc('month', date_transaction)"],
        on_schema_change='append_new_columns',
        tags=['marts', 'core', 'fct', 'incremental', 'experimental', 'microbatch']
    )
}}

with base as (
    select * from {{ ref('int_transactions_normalisees') }}
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
    -- Référentiel coté EUR -> devise : on divise (cf. fct_transactions.sql)
    round(coalesce(
        b.montant / nullif(fx.taux, 0),
        b.montant * b.taux_change_applique,
        b.montant
    ), 2) as montant_eur,
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
