-- ============================================================
-- MART — Analyse de cohortes de rétention
-- ============================================================
-- TODO (Sprint 6) : Modèle avancé — cohorte définie par le mois
-- d'ouverture du compte, mesure du taux d'utilisateurs actifs sur
-- les 12 mois suivants.
--
-- Attendus :
--   - cohort_mois (mois d'ouverture)
--   - mois_offset (0 = mois d'ouverture, 1 = M+1, ...)
--   - nb_utilisateurs_cohorte
--   - nb_utilisateurs_actifs (au moins 1 tx validée dans le mois)
--   - taux_retention_pct
--
-- Un utilisateur est "actif" un mois donné s'il a au moins 1 transaction
-- validée dans ce mois.
--
-- Indice : DATE_TRUNC('month', ...) + cross join spine
-- ============================================================

{{
    config(
        materialized='table',
        tags=['marts', 'analytics', 'retention', 'todo']
    )
}}

-- Squelette à compléter
select
    date_trunc('month', date_ouverture)::date as cohort_mois,
    0 as mois_offset,
    count(*) as nb_utilisateurs_cohorte,
    count(*) as nb_utilisateurs_actifs,
    100.0 as taux_retention_pct

from {{ ref('dim_comptes') }}
group by 1
