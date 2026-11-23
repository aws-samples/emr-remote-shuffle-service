#!/bin/bash
# TPC-DS 3TB on EMR on EKS 8.1.0 (Spark 4.1.1), with or without Celeborn 0.7.0.
# Both modes use the SAME image, data, queries, executor shape/count and nodes;
# the only difference is the shuffle implementation.
#
#   ./run-tpcds.sh norss      # vanilla Spark shuffle to local NVMe
#   ./run-tpcds.sh celeborn   # Celeborn remote shuffle service
set -euo pipefail

MODE=${1:?usage: $0 norss|celeborn}
export AWS_REGION=${AWS_REGION:-us-west-2}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

VC_NAME=${VC_NAME:-emr-c1315601-20260804-loadtest-mcp-1}
VIRTUAL_CLUSTER_ID=$(aws emr-containers list-virtual-clusters --region "$AWS_REGION" --states RUNNING \
  --query "virtualClusters[?name=='$VC_NAME'].id | [0]" --output text)
EXEC_ROLE_ARN=arn:aws:iam::$ACCOUNT_ID:role/emr-on-loadtest-mcp-execution-role
BUCKET=emr-on-loadtest-mcp-$ACCOUNT_ID-$AWS_REGION
DATA=s3://emr-on-eks-nvme-$ACCOUNT_ID-$AWS_REGION/BLOG_TPCDS-TEST-3T-partitioned
# Celeborn client must match the server: both built from apache/celeborn main 6b153a5 (1.0.0-SNAPSHOT)
IMAGE=${IMAGE:-public.ecr.aws/myang-poc/celeborn-rss:emr8.1.0_clb1.0.0-SNAPSHOT-6b153a5}
RUN_ID=${MODE}-$(date -u +%Y%m%d-%H%M%S)
RESULT=s3://$BUCKET/celeborn-bench/results/$RUN_ID
# default = all 104 TPC-DS v2.4 queries (the API rejects an empty argument)
ALL_QUERIES=q1-v2.4,q2-v2.4,q3-v2.4,q4-v2.4,q5-v2.4,q6-v2.4,q7-v2.4,q8-v2.4,q9-v2.4,q10-v2.4,q11-v2.4,q12-v2.4,q13-v2.4,q14a-v2.4,q14b-v2.4,q15-v2.4,q16-v2.4,q17-v2.4,q18-v2.4,q19-v2.4,q20-v2.4,q21-v2.4,q22-v2.4,q23a-v2.4,q23b-v2.4,q24a-v2.4,q24b-v2.4,q25-v2.4,q26-v2.4,q27-v2.4,q28-v2.4,q29-v2.4,q30-v2.4,q31-v2.4,q32-v2.4,q33-v2.4,q34-v2.4,q35-v2.4,q36-v2.4,q37-v2.4,q38-v2.4,q39a-v2.4,q39b-v2.4,q40-v2.4,q41-v2.4,q42-v2.4,q43-v2.4,q44-v2.4,q45-v2.4,q46-v2.4,q47-v2.4,q48-v2.4,q49-v2.4,q50-v2.4,q51-v2.4,q52-v2.4,q53-v2.4,q54-v2.4,q55-v2.4,q56-v2.4,q57-v2.4,q58-v2.4,q59-v2.4,q60-v2.4,q61-v2.4,q62-v2.4,q63-v2.4,q64-v2.4,q65-v2.4,q66-v2.4,q67-v2.4,q68-v2.4,q69-v2.4,q70-v2.4,q71-v2.4,q72-v2.4,q73-v2.4,q74-v2.4,q75-v2.4,q76-v2.4,q77-v2.4,q78-v2.4,q79-v2.4,q80-v2.4,q81-v2.4,q82-v2.4,q83-v2.4,q84-v2.4,q85-v2.4,q86-v2.4,q87-v2.4,q88-v2.4,q89-v2.4,q90-v2.4,q91-v2.4,q92-v2.4,q93-v2.4,q94-v2.4,q95-v2.4,q96-v2.4,q97-v2.4,q98-v2.4,q99-v2.4,ss_max-v2.4
QUERIES=${QUERIES:-$ALL_QUERIES}
EXECUTORS=${EXECUTORS:-19}

CELEBORN_MASTERS=celeborn-master-0.celeborn-master-svc.celeborn.svc.cluster.local:9097,celeborn-master-1.celeborn-master-svc.celeborn.svc.cluster.local:9097

COMMON='
  "spark.kubernetes.container.image": "'$IMAGE'",
  "spark.kubernetes.driver.podTemplateFile": "s3://'$BUCKET'/celeborn-bench/pod-templates/driver.yaml",
  "spark.kubernetes.executor.podTemplateFile": "s3://'$BUCKET'/celeborn-bench/pod-templates/executor.yaml",
  "spark.kubernetes.executor.podNamePrefix": "'$MODE'",
  "spark.driver.cores": "2",
  "spark.driver.memory": "8g",
  "spark.driver.memoryOverhead": "1g",
  "spark.executor.cores": "4",
  "spark.executor.memory": "6g",
  "spark.executor.memoryOverhead": "2g",
  "spark.dynamicAllocation.enabled": "true",
  "spark.dynamicAllocation.maxExecutors": "'$EXECUTORS'",
  "spark.dynamicAllocation.executorIdleTimeout": "30s",
  "spark.shuffle.service.enabled": "false",
  "spark.serializer": "org.apache.spark.serializer.KryoSerializer",
  "spark.network.timeout": "2000s",
  "spark.executor.heartbeatInterval": "300s"'

if [ "$MODE" = celeborn ]; then
  EXTRA=',
  "spark.shuffle.manager": "org.apache.spark.shuffle.celeborn.SparkShuffleManager",
  "spark.celeborn.master.endpoints": "'$CELEBORN_MASTERS'",
  "spark.sql.adaptive.localShuffleReader.enabled": "false",
  "spark.celeborn.client.spark.push.unsafeRow.fastWrite.enabled": "false",
  "spark.celeborn.client.push.replicate.enabled": "false",
  "spark.celeborn.client.push.excludeWorkerOnFailure.enabled": "true",
  "spark.celeborn.client.fetch.excludeWorkerOnFailure.enabled": "true",
  "spark.celeborn.client.commitFiles.ignoreExcludedWorker": "true"'
elif [ "$MODE" = norss ]; then
  EXTRA=''
else
  echo "unknown mode $MODE" >&2; exit 1
fi

aws emr-containers start-job-run --region "$AWS_REGION" \
  --virtual-cluster-id "$VIRTUAL_CLUSTER_ID" \
  --name "tpcds3t-emr8.1-$RUN_ID" \
  --execution-role-arn "$EXEC_ROLE_ARN" \
  --release-label emr-spark-8.1.0-latest \
  --job-driver '{
    "sparkSubmitJobDriver": {
      "entryPoint": "local:///usr/lib/spark/examples/jars/eks-spark-benchmark-assembly-1.0.jar",
      "entryPointArguments": ["'$DATA'","'$RESULT'","/opt/tpcds-kit/tools","parquet","3000","1","false","'$QUERIES'","true"],
      "sparkSubmitParameters": "--class com.amazonaws.eks.tpcds.BenchmarkSQL"
    }}' \
  --configuration-overrides '{
    "applicationConfiguration": [{
      "classification": "spark-defaults",
      "properties": {'"$COMMON$EXTRA"'
      }}],
    "monitoringConfiguration": {
      "persistentAppUI": "ENABLED",
      "s3MonitoringConfiguration": {"logUri": "s3://'$BUCKET'/celeborn-bench/logs/"}
    }}' \
  --query '{id:id,name:name}' --output text
echo "results -> $RESULT"
