-- Qualité de données : une transaction ne peut pas précéder l'ouverture de
-- son compte. En warn (et non error) : le dataset synthétique tire les dates
-- d'ouverture (2021-2026) indépendamment des dates de transaction (2023-2024),
-- ~53% des lignes sont concernées. En production, ce test passerait en error.
{{ config(severity='warn') }}

select
    f.transaction_id,
    f.compte_id,
    f.date_transaction,
    c.date_ouverture
from {{ ref('fct_transactions') }} f
inner join {{ ref('dim_comptes') }} c on f.compte_id = c.compte_id
where f.date_transaction::date < c.date_ouverture
