{{
    config(
        materialized='view',
        tags=['staging', 'core']
    )
}}

with source as (
    select * from {{ source('fintrack_raw', 'raw_titulaires') }}
)

select
    titulaire_id,
    nom,
    prenom,
    email,
    telephone,
    date_naissance,
    _loaded_at

from source
