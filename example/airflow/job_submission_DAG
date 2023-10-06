from airflow import DAG

from datetime import timedelta, datetime

from airflow.providers.cncf.kubernetes.operators.spark_kubernetes import SparkKubernetesOperator

from airflow.providers.cncf.kubernetes.sensors.spark_kubernetes import SparkKubernetesSensor

from airflow.models import Variable

from kubernetes.client import models as k8s

from airflow.contrib.operators.kubernetes_pod_operator import KubernetesPodOperator

default_args={

   ‘depends_on_past’: False,

   ’email’: [‘abcd@gmail.com’],

   ’email_on_failure’: False,

   ’email_on_retry’: False,

   ‘retries’: 1,

   ‘retry_delay’: timedelta(minutes=5)

}

with DAG(

   ‘my-second-dag’,

   default_args=default_args,

   description='demo dag’,

   schedule_interval=timedelta(days=1),

   start_date=datetime(2023, 10, 07),

   catchup=False,

   tags=[demo]

) as dag:

   t1 = SparkKubernetesOperator(
       task_id=‘emr-spark-operator’,
       trigger_rule=“all_success”,
       depends_on_past=False,
       retries=3,
       application_file=“emr-operator-celeborn-dra.yaml",
       namespace=“spark-operator”,
       kubernetes_conn_id=“myk8s”,
       api_group=“sparkoperator.k8s.io”,
       api_version=“v1beta2”,
       do_xcom_push=True,
       dag=dag
   )