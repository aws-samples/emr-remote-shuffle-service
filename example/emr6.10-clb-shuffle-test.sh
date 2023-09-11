#!/bin/bash
# SPDX-FileCopyrightText: Copyright 2021 Amazon.com, Inc. or its affiliates.
# SPDX-License-Identifier: MIT-0

# "spark.celeborn.client.spark.push.unsafeRow.fastWrite.enabled": "false"

export EMRCLUSTER_NAME=emr-on-eks-rss
# export AWS_REGION=us-east-1
export ACCOUNTID=$(aws sts get-caller-identity --query Account --output text)
export VIRTUAL_CLUSTER_ID=$(aws emr-containers list-virtual-clusters --query "virtualClusters[?name == '$EMRCLUSTER_NAME' && state == 'RUNNING'].id" --output text)
export EMR_ROLE_ARN=arn:aws:iam::$ACCOUNTID:role/$EMRCLUSTER_NAME-execution-role
export S3BUCKET=${EMRCLUSTER_NAME}-${ACCOUNTID}-${AWS_REGION}
export ECR_URL="$ACCOUNTID.dkr.ecr.$AWS_REGION.amazonaws.com"

aws emr-containers start-job-run \
  --virtual-cluster-id $VIRTUAL_CLUSTER_ID \
  --name em613-clb-shuffle-dra-timeut96 \
  --execution-role-arn $EMR_ROLE_ARN \
  --release-label emr-6.10.0-latest \
  --job-driver '{
  "sparkSubmitJobDriver": {
      "entryPoint": "s3://'$S3BUCKET'/shuffle-test_2.12-1.0.jar",
      "sparkSubmitParameters": "--conf spark.driver.cores=1 --conf spark.driver.memory=2g --conf spark.executor.cores=4 --conf spark.executor.memory=6g"}}' \
  --retry-policy-configuration '{"maxAttempts": 3}' \
  --configuration-overrides '{
    "applicationConfiguration": [
      {
        "classification": "spark-defaults", 
        "properties": {
          "spark.kubernetes.container.image": "'$ECR_URL'/clb-spark-benchmark:emr6.13_clb",
          "spark.network.timeout": "2000s",
          "spark.executor.memoryOverhead": "2G",
          "spark.executor.heartbeatInterval": "300s",
          "spark.kubernetes.executor.podNamePrefix": "emr-clb-shuffle-test",
          "spark.kubernetes.driver.label.name":"emr-clb-shuffle-test",
          "spark.kubernetes.node.selector.eks.amazonaws.com/nodegroup": "c59b",
          "spark.serializer": "org.apache.spark.serializer.KryoSerializer",

          "spark.dynamicAllocation.enabled": "true",
          "spark.dynamicAllocation.minExecutors": "1",
          "spark.dynamicAllocation.maxExecutors": "96",
          "spark.dynamicAllocation.executorIdleTimeout": "10s",
          "spark.dynamicAllocation.shuffleTracking.enabled": "false",
          "spark.sql.adaptive.localShuffleReader.enabled":"false",

          "spark.celeborn.shuffle.chunk.size": "4m",
          "spark.celeborn.client.push.maxReqsInFlight": "128",
          "spark.celeborn.rpc.askTimeout": "2000s",
          "spark.celeborn.client.push.replicate.enabled": "true",
          "spark.celeborn.client.push.blacklist.enabled": "true",
          "spark.celeborn.client.push.excludeWorkerOnFailure.enabled": "true",
          "spark.celeborn.client.fetch.excludeWorkerOnFailure.enabled": "true",
          "spark.celeborn.client.commitFiles.ignoreExcludedWorker": "true",
          "spark.shuffle.manager": "org.apache.spark.shuffle.celeborn.SparkShuffleManager",
          "spark.shuffle.sort.io.plugin.class": "org.apache.spark.shuffle.celeborn.CelebornShuffleDataIO",
          "spark.celeborn.master.endpoints": "celeborn-master-0.celeborn-master-svc.celeborn:9097,celeborn-master-1.celeborn-master-svc.celeborn:9097,celeborn-master-2.celeborn-master-svc.celeborn:9097",
          "spark.sql.optimizedUnsafeRowSerializers.enabled":"false",

          "spark.metrics.appStatusSource.enabled":"true",
          "spark.ui.prometheus.enabled":"true",
          "spark.executor.processTreeMetrics.enabled":"true",
          "spark.kubernetes.driver.annotation.prometheus.io/scrape":"true",
          "spark.kubernetes.driver.annotation.prometheus.io/path":"/metrics/executors/prometheus/",
          "spark.kubernetes.driver.annotation.prometheus.io/port":"4040",
          "spark.kubernetes.driver.service.annotation.prometheus.io/scrape":"true",
          "spark.kubernetes.driver.service.annotation.prometheus.io/path":"/metrics/driver/prometheus/",
          "spark.kubernetes.driver.service.annotation.prometheus.io/port":"4040",
          "spark.metrics.conf.*.sink.prometheusServlet.class":"org.apache.spark.metrics.sink.PrometheusServlet",
          "spark.metrics.conf.*.sink.prometheusServlet.path":"/metrics/driver/prometheus/",
          "spark.metrics.conf.master.sink.prometheusServlet.path":"/metrics/master/prometheus/",
          "spark.metrics.conf.applications.sink.prometheusServlet.path":"/metrics/applications/prometheus/"
      }},
      {
        "classification": "spark-log4j",
        "properties": {
          "rootLogger.level" : "WARN"
          }
      }
      ],
    "monitoringConfiguration": {
      "s3MonitoringConfiguration": {"logUri": "s3://'$S3BUCKET'/elasticmapreduce/emr-containers"}}}'
