-- ============================================================
-- BRIDGE COMPTES ↔ TITULAIRES (relation many-to-many)
-- ============================================================
-- Un compte peut avoir plusieurs titulaires (comptes joints,
-- type_compte='joint' côté générateur) ; un titulaire peut être
-- rattaché à plusieurs comptes.
--
-- allocation_factor : poids de ventilation des montants du compte
--   entre ses titulaires (0.5/0.5 pour un compte joint à 2, 1.0 pour
--   un compte à titulaire unique).
-- date_debut / date_fin : historisation du rattachement compte <->
--   titulaire (date_fin NULL = rattachement toujours actif).
-- ============================================================

{{
    config(
        materialized='table',
        tags=['marts', 'core', 'bridge']
    )
}}

select
    compte_id,
    titulaire_id,
    allocation_factor,
    date_debut,
    date_fin,
    is_primary

from {{ ref('stg_compte_titulaires') }}
