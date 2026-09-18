"""
FinTrack — DAG Airflow orchestrant l'ingestion et dbt.

TODO (Sprint 5) : Compléter selon vos besoins :
    - Sensors sur la fraîcheur des sources (S3, API core banking)
    - Notifications Slack sur échec
    - Retry policies différenciées ingestion / transformation
    - SLA sur chaque tâche

Ce fichier est un squelette de démarrage.
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator
from airflow.utils.task_group import TaskGroup


default_args = {
    "owner": "data-platform",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": True,
    "email_on_retry": False,
}


with DAG(
    dag_id="fintrack_daily_pipeline",
    default_args=default_args,
    description="Pipeline FinTrack quotidien — ingestion + dbt",
    schedule="0 3 * * *",   # 03:00 tous les jours
    start_date=datetime(2024, 1, 1),
    catchup=False,
    max_active_runs=1,
    tags=["fintrack", "dbt", "prod"],
) as dag:

    # =============================================
    # Ingestion (upload CSV → stage → COPY INTO)
    # =============================================
    with TaskGroup("ingestion") as ingestion:

        upload_to_stage = BashOperator(
            task_id="upload_to_stage",
            bash_command=(
                "snowsql -f /opt/scripts/upload_and_copy.sql "
                "-o output_format=csv -o header=false"
            ),
        )

    # =============================================
    # dbt : snapshot → run → test
    # =============================================
    DBT_DIR = "/opt/dbt/fintrack_perf_scale"

    with TaskGroup("dbt") as dbt_group:

        dbt_deps = BashOperator(
            task_id="dbt_deps",
            bash_command=f"cd {DBT_DIR} && dbt deps",
        )

        dbt_snapshot = BashOperator(
            task_id="dbt_snapshot",
            bash_command=f"cd {DBT_DIR} && dbt snapshot --target prod",
        )

        dbt_run_staging = BashOperator(
            task_id="dbt_run_staging",
            bash_command=(
                f"cd {DBT_DIR} && "
                f"dbt run --target prod --select tag:staging"
            ),
        )

        dbt_run_marts = BashOperator(
            task_id="dbt_run_marts",
            bash_command=(
                f"cd {DBT_DIR} && "
                f"dbt run --target prod --select tag:marts"
            ),
        )

        dbt_test = BashOperator(
            task_id="dbt_test",
            bash_command=f"cd {DBT_DIR} && dbt test --target prod --exclude tag:todo",
        )

        dbt_docs_generate = BashOperator(
            task_id="dbt_docs_generate",
            bash_command=f"cd {DBT_DIR} && dbt docs generate --target prod",
        )

        dbt_deps >> dbt_snapshot >> dbt_run_staging >> dbt_run_marts >> dbt_test >> dbt_docs_generate

    # =============================================
    # Post-processing : reverse ETL, notifications
    # =============================================
    reverse_etl = BashOperator(
        task_id="reverse_etl_hightouch",
        bash_command="curl -X POST https://api.hightouch.io/trigger/fintrack_sync",
    )

    ingestion >> dbt_group >> reverse_etl
