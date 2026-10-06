-- ============================================================
-- MART — Analyse de cohortes de rétention
-- ============================================================
-- Cohorte = mois d'ouverture du compte. Pour chaque cohorte, on mesure
-- la part des comptes "actifs" sur les 12 mois suivants (M+0 à M+12).
--
-- Un compte est "actif" un mois donné s'il a au moins 1 transaction
-- validée dans ce mois.
--
-- Construction :
--   1. cohortes  : taille de chaque cohorte (dénominateur)
--   2. offsets   : spine 0..12 (table(generator()) Snowflake)
--   3. cross join cohortes × offsets → une ligne par (cohorte, M+N),
--      y compris les mois sans aucun actif (taux = 0, pas de trou)
--   4. left join sur les comptes actifs par (cohorte, offset)
--
-- Fenêtre d'observation : seuls les mois couverts par les données de
-- transactions sont mesurables.
--   - cohortes ouvertes AVANT le 1er mois de données exclues : leurs
--     premiers offsets tomberaient avant le début de l'historique et
--     afficheraient une fausse rétention de 0% ;
--   - offsets APRÈS le dernier mois de données exclus : mois pas encore
--     écoulés (sinon les cohortes récentes chuteraient à 0%).
-- ============================================================

{{
    config(
        materialized='table',
        tags=['marts', 'analytics', 'retention']
    )
}}

with comptes as (
    select
        compte_id,
        date_trunc('month', date_ouverture)::date as cohort_mois
    from {{ ref('dim_comptes') }}
    where date_ouverture is not null
),

cohortes as (
    select
        cohort_mois,
        count(*) as nb_utilisateurs_cohorte
    from comptes
    group by cohort_mois
),

offsets as (
    -- 13 lignes numérotées 0..12 (row_number car seq4() peut avoir des trous)
    select row_number() over (order by seq4()) - 1 as mois_offset
    from table(generator(rowcount => 13))
),

activite as (
    -- Mois d'activité distincts par compte (au moins 1 tx validée)
    select distinct
        compte_id,
        mois_transaction as mois_activite
    from {{ ref('fct_transactions') }}
    where statut = 'validee'
),

fenetre as (
    select min(mois_activite) as mois_min, max(mois_activite) as mois_max from activite
),

actifs as (
    select
        c.cohort_mois,
        datediff('month', c.cohort_mois, a.mois_activite) as mois_offset,
        count(distinct c.compte_id) as nb_utilisateurs_actifs
    from comptes as c
    inner join activite as a on c.compte_id = a.compte_id
    where datediff('month', c.cohort_mois, a.mois_activite) between 0 and 12
    group by c.cohort_mois, datediff('month', c.cohort_mois, a.mois_activite)
)

select
    co.cohort_mois,
    o.mois_offset,
    dateadd('month', o.mois_offset, co.cohort_mois)::date as mois_observe,
    co.nb_utilisateurs_cohorte,
    coalesce(a.nb_utilisateurs_actifs, 0) as nb_utilisateurs_actifs,
    round(
        100.0 * coalesce(a.nb_utilisateurs_actifs, 0)
        / nullif(co.nb_utilisateurs_cohorte, 0), 2
    ) as taux_retention_pct

from cohortes as co
cross join offsets as o
left join actifs as a
    on
        co.cohort_mois = a.cohort_mois
        and o.mois_offset = a.mois_offset
where
    co.cohort_mois >= (select f.mois_min from fenetre as f)
    and dateadd('month', o.mois_offset, co.cohort_mois) <= (select f.mois_max from fenetre as f)
