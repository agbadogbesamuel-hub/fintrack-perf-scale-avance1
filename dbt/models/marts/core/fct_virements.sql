-- ============================================================
-- FCT VIREMENTS — chaque virement génère 2 lignes (sortant + entrant)
-- ============================================================
-- Sprint 2 — double-écriture implémentée (UNION ALL ci-dessous).
--
-- Chaque ligne source doit produire 2 lignes dans le fait :
--   - une "sortant" pour compte_source_id (montant négatif)
--   - une "entrant" pour compte_dest_id (montant positif)
--
-- Attendus :
--   - virement_id (partagé entre les 2 lignes)
--   - virement_leg (sortant/entrant)
--   - compte_id (celui de la leg concernée)
--   - contrepartie_compte_id (l'autre)
--   - montant_signe
--
-- Indice : UNION ALL entre deux SELECT.
-- ============================================================

{{
    config(
        materialized='incremental',
        unique_key=['virement_id', 'virement_leg'],
        incremental_strategy='merge',
        cluster_by=['tenant_id', "date_trunc('month', date_virement)"],
        tags=['marts', 'core', 'fct', 'incremental']
    )
}}

with virements as (
    select * from {{ ref('stg_virements') }}
    where
        statut = 'execute'
        {% if is_incremental() %}
        and _loaded_at >= (
            select dateadd('day', -3, max(this_tbl._loaded_at))
            from {{ this }} as this_tbl
        )
        {% endif %}
),

legs as (
    select
        virement_id,
        tenant_id,
        compte_source_id as compte_id,
        compte_dest_id as contrepartie_compte_id,
        'sortant' as virement_leg,
        montant,
        -montant as montant_signe,
        devise,
        date_virement,
        statut,
        _loaded_at
    from virements

    union all

    select
        virement_id,
        tenant_id,
        compte_dest_id as compte_id,
        compte_source_id as contrepartie_compte_id,
        'entrant' as virement_leg,
        montant,
        montant as montant_signe,
        devise,
        date_virement,
        statut,
        _loaded_at
    from virements
)

select * from legs
