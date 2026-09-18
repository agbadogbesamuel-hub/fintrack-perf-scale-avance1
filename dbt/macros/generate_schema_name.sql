{% macro generate_schema_name(custom_schema_name, node) -%}
    {#-
        Convention multi-environnement :
          - target.name = 'prod'  → schéma custom tel quel (STAGING, MARTS_CORE, etc.)
          - target.name = 'ci'    → CI_<custom>_<PR_ID>  (isolé par PR)
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
        {%- if custom_schema_name is none -%}
            CI_{{ default_schema }}_{{ pr_id }}
        {%- else -%}
            CI_{{ custom_schema_name | trim }}_{{ pr_id }}
        {%- endif -%}

    {%- else -%}
        {%- if custom_schema_name is none -%}
            {{ default_schema }}
        {%- else -%}
            {{ default_schema }}_{{ custom_schema_name | trim }}
        {%- endif -%}
    {%- endif -%}

{%- endmacro %}
