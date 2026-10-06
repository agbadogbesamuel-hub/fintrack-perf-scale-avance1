"""
FinTrack — DAG Airflow orchestrant l'ingestion et dbt.

Task groups : ingestion (sensor de fraîcheur + upload/COPY), dbt
(snapshot -> run -> test -> docs), reverse_etl.

Retries différenciés : l'ingestion (réseau/upstream, souvent transitoire)
retente plus souvent et plus vite que dbt (échec généralement déterministe
— un modèle cassé ne se corrige pas tout seul au 2e essai, autant échouer
vite et alerter plutôt que gaspiller des crédits warehouse en retries).

SLA : la fraîcheur contractuelle la plus stricte est celle des tenants
gold (2h, cf. MISSION.md). Les `sla=` ci-dessous forment une échelle
cumulative depuis le début du run (sémantique Airflow : le SLA se mesure
depuis le data_interval_start du DAG, pas depuis le début de la tâche)
plafonnée à 2h sur la dernière tâche critique (dbt_test) — si on la
dépasse, les tenants gold ne sont déjà plus dans les clous.

Notification Slack sur échec : callback DAG-level (s'applique à toutes
les tâches), utilise la connexion Airflow `slack_webhook` (à créer dans
Admin > Connections, type "HTTP", host = URL du webhook Slack).
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.sensors.filesystem import FileSensor
from airflow.utils.task_group import TaskGroup


def notify_slack_on_failure(context):
    """on_failure_callback — poste un message dans Slack via la connexion
    HTTP `slack_webhook`. Import différé pour ne pas exiger le provider
    Slack si jamais Slack n'est pas configuré dans un environnement donné.
    """
    from airflow.providers.slack.hooks.slack_webhook import SlackWebhookHook

    task_instance = context["task_instance"]
    dag_run = context["dag_run"]
    message = (
        f":red_circle: *Échec* `{task_instance.task_id}` "
        f"(DAG `{task_instance.dag_id}`, run `{dag_run.run_id}`)\n"
        f"<{task_instance.log_url}|Voir les logs>"
    )
    SlackWebhookHook(slack_webhook_conn_id="slack_webhook").send(text=message)


# Retries "réseau" (ingestion) : tolérants, on retente vite plusieurs fois.
INGESTION_RETRY_ARGS = {
    "retries": 4,
    "retry_delay": timedelta(minutes=2),
    "retry_exponential_backoff": True,
    "max_retry_delay": timedelta(minutes=20),
}

# Retries "transformation" (dbt) : un échec de modèle est presque toujours
# déterministe (bug SQL, donnée invalide, contrainte violée) — retenter
# 5 fois ne le corrige pas et ne fait que retarder l'alerte + gaspiller
# des crédits warehouse. On retente une seule fois (glitch réseau vers
# Snowflake) puis on laisse échouer et on alerte.
DBT_RETRY_ARGS = {
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

default_args = {
    "owner": "data-platform",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": True,
    "email_on_retry": False,
    "on_failure_callback": notify_slack_on_failure,
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
    # Ingestion (sensor fraîcheur -> upload CSV -> stage -> COPY INTO)
    # =============================================
    with TaskGroup("ingestion") as ingestion:

        # En production, la source réelle est le core banking system qui
        # dépose un extract quotidien (S3 ou API) — remplacer par un
        # S3KeySensor / HttpSensor selon l'intégration retenue. FileSensor
        # ici pour matcher le mode de dépôt actuel du projet (CSV générés
        # localement puis PUT vers le stage Snowflake, cf. scripts/snowflake/
        # 03_stage_and_copy.sql), et pour que le DAG reste testable sans
        # dépendance cloud supplémentaire.
        wait_for_source_files = FileSensor(
            task_id="wait_for_source_files",
            filepath="/opt/data/raw/raw_transactions.csv.gz",
            poke_interval=60,
            timeout=timedelta(minutes=30).total_seconds(),
            mode="reschedule",  # libère le worker slot entre les pokes
            sla=timedelta(minutes=30),
            **INGESTION_RETRY_ARGS,
        )

        upload_to_stage = BashOperator(
            task_id="upload_to_stage",
            bash_command=(
                "snowsql -f /opt/scripts/upload_and_copy.sql "
                "-o output_format=csv -o header=false"
            ),
            sla=timedelta(minutes=45),
            **INGESTION_RETRY_ARGS,
        )

        wait_for_source_files >> upload_to_stage

    # =============================================
    # dbt : snapshot → run → test
    # =============================================
    DBT_DIR = "/opt/dbt/fintrack_perf_scale"

    with TaskGroup("dbt") as dbt_group:

        dbt_deps = BashOperator(
            task_id="dbt_deps",
            bash_command=f"cd {DBT_DIR} && dbt deps",
            sla=timedelta(minutes=50),
            **DBT_RETRY_ARGS,
        )

        dbt_snapshot = BashOperator(
            task_id="dbt_snapshot",
            bash_command=f"cd {DBT_DIR} && dbt snapshot --target prod",
            sla=timedelta(minutes=55),
            **DBT_RETRY_ARGS,
        )

        dbt_run_staging = BashOperator(
            task_id="dbt_run_staging",
            bash_command=(
                f"cd {DBT_DIR} && "
                f"dbt run --target prod --select tag:staging"
            ),
            sla=timedelta(hours=1, minutes=10),
            **DBT_RETRY_ARGS,
        )

        dbt_run_marts = BashOperator(
            task_id="dbt_run_marts",
            bash_command=(
                f"cd {DBT_DIR} && "
                f"dbt run --target prod --select tag:marts"
            ),
            sla=timedelta(hours=1, minutes=40),
            **DBT_RETRY_ARGS,
        )

        dbt_test = BashOperator(
            task_id="dbt_test",
            bash_command=f"cd {DBT_DIR} && dbt test --target prod --exclude tag:todo",
            # Dernière tâche critique avant le plafond gold (2h) — voir
            # docstring du module.
            sla=timedelta(hours=2),
            **DBT_RETRY_ARGS,
        )

        dbt_docs_generate = BashOperator(
            task_id="dbt_docs_generate",
            bash_command=f"cd {DBT_DIR} && dbt docs generate --target prod",
            # Non bloquant pour la fraîcheur des données consommées —
            # pas de SLA strict, mais toujours alerté sur échec (retries
            # par défaut du DAG).
        )

        dbt_deps >> dbt_snapshot >> dbt_run_staging >> dbt_run_marts >> dbt_test >> dbt_docs_generate

    # =============================================
    # Post-processing : reverse ETL, notifications
    # =============================================
    reverse_etl = BashOperator(
        task_id="reverse_etl_hightouch",
        bash_command="curl -X POST https://api.hightouch.io/trigger/fintrack_sync",
        sla=timedelta(hours=2, minutes=15),
        **INGESTION_RETRY_ARGS,
    )

    ingestion >> dbt_group >> reverse_etl
