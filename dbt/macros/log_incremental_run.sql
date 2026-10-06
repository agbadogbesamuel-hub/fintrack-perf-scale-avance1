{% macro log_incremental_run(model_name, phase) %}
    {#-
        Journalise les runs incrémentaux dans <database_cible>.AUDIT.dbt_run_log
        (le schéma AUDIT doit exister dans chaque database cible — voir
        scripts/snowflake/05_audit_tables.sql).

        Usage dans un modèle :
            pre_hook = "{{ log_incremental_run('fct_transactions', 'pre') }}"
            post_hook = "{{ log_incremental_run('fct_transactions', 'post') }}"
    -#}

    {% if execute %}
        {% set query %}
            insert into {{ target.database }}.audit.dbt_run_log (
                run_id, model_name, phase, invocation_id,
                target_name, run_started_at, logged_at
            )
            values (
                '{{ invocation_id }}',
                '{{ model_name }}',
                '{{ phase }}',
                '{{ invocation_id }}',
                '{{ target.name }}',
                '{{ run_started_at }}',
                current_timestamp()
            )
        {% endset %}
        {{ log("Logging " ~ phase ~ " hook for " ~ model_name, info=True) }}
        {{ return(query) }}
    {% endif %}
{% endmacro %}
