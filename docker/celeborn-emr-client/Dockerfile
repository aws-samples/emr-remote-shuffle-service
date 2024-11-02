# // Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# // SPDX-License-Identifier: MIT-0
ARG SPARK_BASE_IMAGE=public.ecr.aws/emr-on-eks/spark/emr-6.10.0:latest
ARG java_image_tag=8-jdk-focal

FROM eclipse-temurin:${java_image_tag} AS clb-client
ARG SPARK_VERSION=3.3
ARG CELEBORN_VERSION=0.4
ARG JDK_VERSION=8

# install maven
RUN apt-get update && apt-get install -y git
# build celeborn binary
RUN git clone https://github.com/apache/celeborn.git -b branch-${CELEBORN_VERSION}
WORKDIR celeborn
RUN ./build/make-distribution.sh -Pspark-${SPARK_VERSION} -Pjdk-${JDK_VERSION} && \
    cat *.tgz | tar -xvzf - && \
    mv apache-celeborn-*-bin /opt/celeborn

FROM mozilla/sbt:8u292_1.5.4 AS sbt
# Build the Databricks SQL perf library
RUN git clone https://github.com/aws-samples/emr-on-eks-benchmark.git /tmp/emr-on-eks-benchmark \
    && cd /tmp/emr-on-eks-benchmark/spark-sql-perf/ \
    && sbt +package   
     
# Use the compiled Databricks SQL perf library to build benchmark utility
RUN cd /tmp/emr-on-eks-benchmark/ && mkdir /tmp/emr-on-eks-benchmark/benchmark/libs \
    && cp /tmp/emr-on-eks-benchmark/spark-sql-perf/target/scala-2.12/*.jar /tmp/emr-on-eks-benchmark/benchmark/libs \
    && cd /tmp/emr-on-eks-benchmark/benchmark && sbt assembly

FROM ${SPARK_BASE_IMAGE}
USER root

COPY --from=clb-client /opt/celeborn/spark ${SPARK_HOME}/jars
COPY --from=sbt /tmp/emr-on-eks-benchmark/benchmark/target/scala-2.12/*jar ${SPARK_HOME}/examples/jars/

WORKDIR /home/hadoop
USER hadoop:hadoop

