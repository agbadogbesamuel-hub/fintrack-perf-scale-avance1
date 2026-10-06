-- ============================================================
-- MART — Solde journalier par compte (avec forward-fill)
-- ============================================================
-- Agrège transactions + virements pour produire le solde de chaque
-- compte à chaque date, y compris les jours sans mouvement.
--
-- Grain : une ligne par (compte_id, jour). Le tenant est celui du compte
-- (dim_comptes), pas celui porté par chaque transaction : grouper aussi par
-- le tenant de la transaction créait des doublons (compte, jour) et rendait
-- le solde cumulé non déterministe (égalités dans l'ORDER BY de la fenêtre).
--
-- Décision Sprint 4 : reste en table — 2,4 s au scale M (cf. PERF_LOG).
-- À passer en incremental si le volume le justifie (scale L/XL).
-- ============================================================

{{
    config(
        materialized='table',
        cluster_by=['tenant_id', 'jour'],
        tags=['marts', 'finance', 'solde']
    )
}}

with tx as (
    select
        compte_id,
        jour_transaction as jour,
        sum(montant_signe_eur) as solde_tx_eur
    from {{ ref('fct_transactions') }}
    where statut = 'validee'
    group by compte_id, jour_transaction
),

vir as (
    select
        compte_id,
        date_virement::date as jour,
        sum(case when virement_leg = 'sortant' then -montant else montant end) as solde_vir_eur
    from {{ ref('fct_virements') }}
    group by compte_id, date_virement::date
),

flux_jour as (
    select
        coalesce(tx.compte_id, vir.compte_id) as compte_id,
        coalesce(tx.jour, vir.jour) as jour,
        coalesce(tx.solde_tx_eur, 0) as flux_transactions,
        coalesce(vir.solde_vir_eur, 0) as flux_virements
    from tx
    full outer join vir
        on
            tx.compte_id = vir.compte_id
            and tx.jour = vir.jour
),

comptes as (
    select
        compte_id,
        tenant_id,
        solde_initial,
        date_ouverture
    from {{ ref('dim_comptes') }}
)

select
    c.tenant_id,
    f.compte_id,
    f.jour,
    f.flux_transactions,
    f.flux_virements,
    f.flux_transactions + f.flux_virements as flux_total_jour,

    c.solde_initial + sum(f.flux_transactions + f.flux_virements) over (
        partition by f.compte_id
        order by f.jour
        rows between unbounded preceding and current row
    ) as solde_cumule_eur

from flux_jour as f
inner join comptes as c on f.compte_id = c.compte_id
