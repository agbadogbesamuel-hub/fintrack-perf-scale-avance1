-- ============================================================
-- BRIDGE COMPTES ↔ TITULAIRES (relation many-to-many)
-- ============================================================
-- TODO (Sprint 5) : Créer une table bridge pour gérer les comptes joints
-- (un compte peut avoir plusieurs titulaires, un titulaire peut avoir
-- plusieurs comptes).
--
-- Le générateur n'expose pas encore les co-titulaires — vous devrez :
--   1. Enrichir le générateur Python pour créer une table raw_titulaires
--      et raw_compte_titulaires
--   2. Ajouter les DDL dans script 02
--   3. Créer les modèles staging correspondants
--   4. Implémenter cette bridge avec :
--      - allocation_factor (poids) pour ventilation des montants
--      - date_debut, date_fin (historisation des changements)
-- ============================================================

{{
    config(
        materialized='table',
        tags=['marts', 'core', 'bridge', 'todo']
    )
}}

-- Placeholder — un compte, un titulaire, factor = 1
select
    compte_id,
    compte_id as titulaire_id,
    1.0 as allocation_factor,
    date_ouverture as date_debut,
    cast(null as date) as date_fin,
    true as is_primary

from {{ ref('stg_comptes') }}
