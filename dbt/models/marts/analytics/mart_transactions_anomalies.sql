-- ============================================================
-- MART — Détection d'anomalies sur transactions (Z-score par compte)
-- ============================================================
-- Une transaction est "anormale" si son montant s'écarte de plus de
-- 3 écarts-types de la moyenne mobile du compte.
--
-- Choix de conception :
--   - Fenêtre glissante en NOMBRE de transactions (ROWS BETWEEN 90
--     PRECEDING AND 1 PRECEDING), approximation de "90 jours". Un
--     RANGE temporel strict serait plus fidèle mais bien plus coûteux à
--     100M lignes ; au volume généré (~50 tx/compte sur 2 ans), 90 tx
--     couvrent en pratique au moins 90 jours d'historique.
--   - La transaction courante est EXCLUE de sa propre fenêtre
--     (1 PRECEDING) : sinon un montant extrême gonfle lui-même la
--     moyenne et l'écart-type, et masque sa propre anomalie.
--   - Historique minimum de 10 transactions : en dessous, l'écart-type
--     n'est pas significatif → z_score NULL, pas d'anomalie levée.
--
-- Sévérité (anomalies uniquement, NULL sinon) :
--   |z| ∈ ]3, 4[  → low   |   [4, 6[ → medium   |   ≥ 6 → high
-- ============================================================

{{
    config(
        materialized='table',
        cluster_by=['tenant_id', "date_trunc('month', date_transaction)"],
        tags=['marts', 'analytics', 'anomalies']
    )
}}

{% set seuil_z = 3 %}
{% set historique_min = 10 %}

with tx as (
    select
        transaction_id,
        tenant_id,
        compte_id,
        date_transaction,
        montant_eur
    from {{ ref('fct_transactions') }}
    where statut = 'validee'
),

stats as (
    select
        tx.*,
        avg(tx.montant_eur) over (
            partition by tx.compte_id order by tx.date_transaction, tx.transaction_id
            rows between 90 preceding and 1 preceding
        ) as moyenne_90j,
        stddev(tx.montant_eur) over (
            partition by tx.compte_id order by tx.date_transaction, tx.transaction_id
            rows between 90 preceding and 1 preceding
        ) as ecart_type_90j,
        count(tx.montant_eur) over (
            partition by tx.compte_id order by tx.date_transaction, tx.transaction_id
            rows between 90 preceding and 1 preceding
        ) as nb_tx_historique
    from tx
),

scores as (
    select
        *,
        case
            when nb_tx_historique >= {{ historique_min }}
                then (montant_eur - moyenne_90j) / nullif(ecart_type_90j, 0)
        end as z_score
    from stats
)

select
    transaction_id,
    tenant_id,
    compte_id,
    date_transaction,
    montant_eur,
    round(moyenne_90j, 2) as moyenne_90j,
    round(ecart_type_90j, 2) as ecart_type_90j,
    nb_tx_historique,
    round(z_score, 3) as z_score,
    coalesce(abs(z_score) > {{ seuil_z }}, false) as is_anomalie,
    case
        when abs(z_score) >= 6 then 'high'
        when abs(z_score) >= 4 then 'medium'
        when abs(z_score) > {{ seuil_z }} then 'low'
    end as severite

from scores
