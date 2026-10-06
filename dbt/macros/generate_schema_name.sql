{% macro generate_schema_name(custom_schema_name, node) -%}
    {#-
        Convention multi-environnement :
          - target.name = 'prod'  → schéma custom tel quel (STAGING, MARTS_CORE, etc.)
          - target.name = 'ci'    → CI_<PR_ID>, un seul schéma pour TOUS les modèles
            d'un même PR (custom_schema_name ignoré), pour que le cleanup en fin de
            job (`dbt run-operation drop_schema --args "{schema_name: CI_<PR_ID>}"`,
            voir .github/workflows/dbt_ci.yml) nettoie tout en une seule commande.
            Une variante "CI_<custom>_<PR_ID>" éclaterait le build sur plusieurs
            schémas que le cleanup actuel ne connaît pas et ne supprimerait jamais.
          - target.name = 'dev'   → DEV_<user>_<custom>  (isolé par développeur)
    -#}

    {%- set default_schema = target.schema -%}

    {%- if target.name == 'prod' -%}
        {%- if custom_schema_name is none -%}
            {{ default_schema }}
        {%- else -%}
            {{ custom_schema_name | trim }}
        {%- endif -%}

    {%- elif target.name == 'ci' -%}
        {%- set pr_id = env_var('DBT_CI_PR_ID', 'unknown') -%}
        CI_{{ pr_id }}

    {%- else -%}
        {%- if custom_schema_name is none -%}
            {{ default_schema }}
        {%- else -%}
            {{ default_schema }}_{{ custom_schema_name | trim }}
        {%- endif -%}
    {%- endif -%}

{%- endmacro %}
