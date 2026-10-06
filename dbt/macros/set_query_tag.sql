{% macro fintrack_set_query_tag() -%}
    {#-
        Positionne un query_tag Snowflake structuré pour tracer les coûts
        par équipe, projet, modèle et environnement.

        Appelé automatiquement via on-run-start dans dbt_project.yml.

        Nommée `fintrack_set_query_tag` (et non `set_query_tag`) pour éviter
        d'écraser la macro interne du même nom fournie par dbt-snowflake
        (>=1.9), qui est appelée autour de chaque matérialisation avec une
        signature différente et ferait planter tous les runs si on la
        redéfinissait ici.
    -#}
    {% if target.type == 'snowflake' %}
        {% set tag = 'team=data-eng|project=fintrack-perf-scale|target=' ~ target.name %}
        {% set sql %}
            alter session set query_tag = '{{ tag }}'
        {% endset %}
        {% do run_query(sql) %}
        {% do log("Query tag set: " ~ tag, info=True) %}
    {% endif %}
{%- endmacro %}


{% macro fintrack_unset_query_tag() -%}
    {% if target.type == 'snowflake' %}
        {% do run_query("alter session unset query_tag") %}
    {% endif %}
{%- endmacro %}
