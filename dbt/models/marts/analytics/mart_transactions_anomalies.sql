-- ============================================================
-- MART — Détection d'anomalies sur transactions (Z-score par compte)
-- ============================================================
-- TODO (Sprint 6) : Compléter la détection statistique.
-- Une transaction est "anormale" si son montant s'écarte de plus de
-- 3 écarts-types de la moyenne mobile sur 90 jours du compte.
--
-- Attendus :
--   - transaction_id, compte_id, date_transaction, montant_eur
--   - moyenne_90j, ecart_type_90j, z_score
--   - is_anomalie (boolean)
--   - severite (low / medium / high)
--
-- Indice : window functions AVG() et STDDEV() avec ROWS BETWEEN
-- N PRECEDING pour la fenêtre glissante.
-- ============================================================

{{
    config(
        materialized='table',
        tags=['marts', 'analytics', 'anomalies', 'todo']
    )
}}

-- Squelette à compléter
select
    transaction_id,
    compte_id,
    date_transaction,
    montant_eur,
    montant_eur as moyenne_90j,
    0.0 as ecart_type_90j,
    0.0 as z_score,
    false as is_anomalie,
    'low' as severite

from {{ ref('fct_transactions') }}
where statut = 'validee'
