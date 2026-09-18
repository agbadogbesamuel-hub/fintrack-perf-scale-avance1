{% macro set_query_tag() -%}
    {#-
        Positionne un query_tag Snowflake structuré pour tracer les coûts
        par équipe, projet, modèle et environnement.

        Appelé automatiquement via on-run-start dans dbt_project.yml.
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


{% macro unset_query_tag() -%}
    {% if target.type == 'snowflake' %}
        {% do run_query("alter session unset query_tag") %}
    {% endif %}
{%- endmacro %}
