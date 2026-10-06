{{
    config(
        materialized='view',
        tags=['staging', 'core']
    )
}}

with source as (
    select * from {{ source('fintrack_raw', 'raw_compte_titulaires') }}
)

select
    compte_id,
    titulaire_id,
    allocation_factor,
    date_debut,
    date_fin,
    is_primary,
    _loaded_at

from source
