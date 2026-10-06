-- ============================================================
-- DIM COMPTES SCD Type 2 — historisation des changements
-- ============================================================
-- Sprint 4 — implémenté à partir du snapshot snapshot_comptes.
-- Unicité de la version courante : tests/assert_dim_comptes_scd2_one_current_version.sql
--
-- Attendus :
--   - Une ligne par version (date_debut_validite, date_fin_validite)
--   - Colonnes techniques : is_current, version_number
--   - Surrogate key : dbt_utils.generate_surrogate_key(['compte_id', 'date_debut_validite'])
--
-- Indice : utiliser dbt_valid_from et dbt_valid_to du snapshot.
-- Voir docs/DESIGN.md section "SCD2 Pattern".
-- ============================================================

{{
    config(
        materialized='table',
        tags=['marts', 'core', 'dim', 'scd2'],
        cluster_by=['compte_id']
    )
}}

select
    {{ dbt_utils.generate_surrogate_key(['compte_id', 'dbt_valid_from']) }} as compte_sk,
    compte_id,
    tenant_id,
    statut,
    kyc_level,
    aml_flag,
    email,
    type_compte,
    dbt_valid_from as date_debut_validite,
    dbt_valid_to as date_fin_validite,
    (dbt_valid_to is null) as is_current,
    row_number() over (partition by compte_id order by dbt_valid_from) as version_number

from {{ ref('snapshot_comptes') }}
