-- ============================================================
-- FCT TRANSACTIONS v2 — version "prérelease" du modèle public
-- ============================================================
-- Ajout non cassant : colonne montant_hors_taxes.
-- v1 reste la version par défaut (latest_version: 1 dans _core.yml) :
-- tout ref('fct_transactions') continue de pointer sur v1. Les
-- consommateurs migrent explicitement via ref('fct_transactions', v=2).
--
-- v2 lit v1 au lieu de dupliquer la logique métier : une seule source
-- de vérité pour le FX, les filtres de statut, etc. Incrémental merge
-- avec la même fenêtre de lookback que v1, pour ne pas reconstruire
-- 50-100M lignes à chaque run.
--
-- montant_hors_taxes : hypothèse d'un taux de TVA unique
-- (var taux_tva_defaut, 20%) — à remplacer par un référentiel TVA par
-- pays/catégorie quand la finance l'aura fourni.
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key='transaction_id',
        incremental_strategy='merge',
        cluster_by=['tenant_id', "date_trunc('month', date_transaction)"],
        on_schema_change='append_new_columns',
        tags=['marts', 'core', 'fct', 'incremental']
    )
}}

select
    v1.*,
    round(v1.montant_eur / (1 + {{ var('taux_tva_defaut') }}), 2) as montant_hors_taxes

from {{ ref('fct_transactions', v=1) }} as v1

{% if is_incremental() %}
where
    v1._loaded_at >= (
        select dateadd('day', -{{ var('incremental_lookback_days') }}, max(this_tbl._loaded_at))
        from {{ this }} as this_tbl
    )
{% endif %}
