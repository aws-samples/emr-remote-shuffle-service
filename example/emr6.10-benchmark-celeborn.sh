#!/bin/bash
# SPDX-FileCopyrightText: Copyright 2021 Amazon.com, Inc. or its affiliates.
# SPDX-License-Identifier: MIT-0

# need to create the job template first
# aws emr-containers create-job-template --cli-input-json file://example/pod-template/clb-dra-job-template.json

export EMRCLUSTER_NAME=emr-on-eks-rss
# export AWS_REGION=us-east-1
export ACCOUNTID=$(aws sts get-caller-identity --query Account --output text)
export VIRTUAL_CLUSTER_ID=$(aws emr-containers list-virtual-clusters --query "virtualClusters[?name == '$EMRCLUSTER_NAME' && state == 'RUNNING'].id" --output text)
export EMR_ROLE_ARN=arn:aws:iam::$ACCOUNTID:role/$EMRCLUSTER_NAME-execution-role
export S3BUCKET=${EMRCLUSTER_NAME}-${ACCOUNTID}-${AWS_REGION}
export ECR_URL="$ACCOUNTID.dkr.ecr.$AWS_REGION.amazonaws.com"
export JOB_TEMPLATE_ID=$(aws emr-containers list-job-templates --query "templates[?name == 'celeborn_dra_template'].id" --output text)

aws emr-containers start-job-run \
--virtual-cluster-id $VIRTUAL_CLUSTER_ID \
--name emr7-clb-dra-5sbacklog-10stimeout-cost \
--job-template-id $JOB_TEMPLATE_ID \
--job-template-parameters '{
    "EmrRoleARN": "'$EMR_ROLE_ARN'",
    "CustomImageURI": "'$ECR_URL'/clb-spark-benchmark:emr6.13_clb",
    "InputDataLocation": "s3://'$S3BUCKET'/BLOG_TPCDS-TEST-3T-partitioned",
    "OutputDataLocation": "s3://'$S3BUCKET'/EMRONEKS_TPCDS-TEST-3T-RESULT",
    "QueryList": "q1-v2.4,q2-v2.4,q3-v2.4,q24a-v2.4,q25-v2.4,q26-v2.4,q27-v2.4,q30-v2.4q31-v2.4,q32-v2.4,q33-v2.4,q34-v2.4,q36-v2.4,q37-v2.4,q39a-v2.4,q39b-v2.4,q41-v2.4,q42-v2.4,q43-v2.4,q52-v2.4,q53-v2.4,q55-v2.4,q56-v2.4,q60-v2.4,q61-v2.4,q63-v2.4,q73-v2.4,q77-v2.4,q83-v2.4,q86-v2.4,q98-v2.4",

    "DRA_enabled": "true",
    "DRA_shuffleTracking": "false",
    "AQE_localShuffleReader": "false",
    "DRA_maxExecutors": "100",
    "DRA_executorIdleTimeout": "10s",

    "PodNamePrefix": "clb-dra-notrack",
    "EKSNodegroup": "c59a",
    "LoggerLevel": "WARN",
    "LogS3BucketUri": "s3://'$S3BUCKET'/elasticmapreduce/emr-containers"
  }'