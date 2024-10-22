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
  --name em613-clb-shuffle-dra-timeout96 \
  --execution-role-arn $EMR_ROLE_ARN \
  --release-label emr-6.10.0-latest \
  --job-driver '{
  "sparkSubmitJobDriver": {
      "entryPoint": "s3://'$S3BUCKET'/app_code/shuffle-test_2.12-1.0.jar",
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
          "spark.dynamicAllocation.minExecutors": "1"
          "spark.dynamicAllocation.executorIdleTimeout": "10s",
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
          "spark.celeborn.master.endpoints": "celeborn-master-0.celeborn-master-svc.celeborn:9097,celeborn-master-1.celeborn-master-svc.celeborn:9097,celeborn-master-2.celeborn-master-svc.celeborn:9097",
          "spark.sql.optimizedUnsafeRowSerializers.enabled":"false"
          
          # NOTE: only set the following 2 for Spark 3.5+ to turn off the shuffle tracking
          "spark.shuffle.sort.io.plugin.class": "org.apache.spark.shuffle.celeborn.CelebornShuffleDataIO",
          "spark.dynamicAllocation.shuffleTracking.enabled": "false"
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
