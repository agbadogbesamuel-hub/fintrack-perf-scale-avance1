-- ============================================================
-- DIM CATÉGORIES — avec hiérarchie récursive résolue (bridge)
-- ============================================================
-- TODO (Sprint 2) : Compléter la résolution hiérarchique.
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
select
    categorie_id,
    nom_categorie,
    type_categorie,
    groupe,
    categorie_parent_id,
    niveau_hierarchique,
    -- TODO : ajouter chemin_complet et id_racine
    nom_categorie as chemin_complet,
    categorie_id as id_racine

from {{ ref('stg_categories') }}
