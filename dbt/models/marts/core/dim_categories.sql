-- ============================================================
-- DIM CATÉGORIES — avec hiérarchie récursive résolue (bridge)
-- ============================================================
-- Sprint 2 — implémenté (CTE WITH RECURSIVE ci-dessous, testé dans
-- unit_tests/test_dim_categories.yml).
-- La table catégories a un champ categorie_parent_id qui peut créer
-- une hiérarchie sur plusieurs niveaux.
--
-- Attendus :
--   - categorie_id
--   - nom_categorie
--   - chemin_complet (ex : "Loisirs > Restaurant > Fast-food")
--   - niveau (1 = racine)
--   - id_racine
--
-- Indice : utiliser une CTE récursive Snowflake (WITH RECURSIVE)
-- ============================================================

{{
    config(
        materialized='table',
        tags=['marts', 'core', 'dim']
    )
}}

-- Version simplifiée pour démarrer — à remplacer par la version récursive
with recursive categorie_hierarchie as (
    select
        categorie_id,
        nom_categorie,
        type_categorie,
        groupe,
        categorie_parent_id,
        1 as niveau_hierarchique,
        nom_categorie as chemin_complet,
        categorie_id as id_racine
    from {{ ref('stg_categories') }}
    where categorie_parent_id is null

    union all

    select
        c.categorie_id,
        c.nom_categorie,
        c.type_categorie,
        c.groupe,
        c.categorie_parent_id,
        ch.niveau_hierarchique + 1 as niveau_hierarchique,
        ch.chemin_complet || ' > ' || c.nom_categorie as chemin_complet,
        ch.id_racine
    from {{ ref('stg_categories') }} as c
    inner join categorie_hierarchie as ch on c.categorie_parent_id = ch.categorie_id
)

select
    categorie_id,
    nom_categorie,
    type_categorie,
    groupe,
    categorie_parent_id,
    niveau_hierarchique,
    chemin_complet,
    id_racine

from categorie_hierarchie
