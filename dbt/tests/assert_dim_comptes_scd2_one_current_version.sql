-- Chaque compte_id doit avoir exactement une version courante (is_current = true)
-- dans dim_comptes_scd2. Ce test échoue si un compte a 0 ou plusieurs versions
-- courantes (retourne les compte_id fautifs).

select
    compte_id,
    count(*) as nb_versions_courantes
from {{ ref('dim_comptes_scd2') }}
where is_current
group by compte_id
having count(*) != 1
