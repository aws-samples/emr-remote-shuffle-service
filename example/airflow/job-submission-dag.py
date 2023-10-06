from airflow import DAG
from datetime import timedelta, datetime
from airflow.providers.cncf.kubernetes.operators.spark_kubernetes import SparkKubernetesOperator
from airflow.providers.cncf.kubernetes.sensors.spark_kubernetes import SparkKubernetesSensor
from airflow.models import Variable
from airflow.utils.dates import days_ago

default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': days_ago(1),
    'email': ['airflow@example.com'],
    'email_on_failure': False,
    'email_on_retry': False,
    'max_active_runs': 1,
    'retries': 3
}
dag = DAG(
    'demo2',
    default_args=default_args,
    schedule_interval=timedelta(days=1),
    tags=['demo']
)
submit = SparkKubernetesOperator(
   task_id='n-spark-pi',
   application_file="spark-pi.yaml",
   namespace="spark-operator",
   trigger_rule="all_success",
   depends_on_past=False,
   kubernetes_conn_id="myk8s",
   api_group="sparkoperator.k8s.io",
   api_version="v1beta2",
   do_xcom_push=True,
   dag=dag
)
sensor = SparkKubernetesSensor(
    task_id='task_monitor',
    namespace="spark-operator",
    application_name="{{ task_instance.xcom_pull(task_ids='emr_spark_operator')['metadata']['name'] }}",
    kubernetes_conn_id="myk8s",
    dag=dag,
    api_group="sparkoperator.k8s.io",
    attach_log=True
)

submit >> sensor