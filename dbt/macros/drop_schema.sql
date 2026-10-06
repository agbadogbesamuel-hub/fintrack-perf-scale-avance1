{% macro drop_schema(schema_name) %}
    {#-
        Supprime un schéma (et son contenu) — utilisé par la CI pour nettoyer
        le schéma isolé CI_<PR_ID> en fin de job (voir .github/workflows/dbt_ci.yml
        et README.md "Commandes utiles").
    -#}
    {% set sql %}
        drop schema if exists {{ target.database }}.{{ schema_name }} cascade
    {% endset %}
    {% do log("Dropping schema " ~ target.database ~ "." ~ schema_name, info=True) %}
    {% do run_query(sql) %}
{% endmacro %}
