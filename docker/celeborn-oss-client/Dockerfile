# // Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# // SPDX-License-Identifier: MIT-0
# Open source Apache Spark 4.1 / Scala 2.13 / Java 17 (Docker Official Image)
ARG SPARK_BASE_IMAGE=spark:4.1.4-scala2.13-java17-python3-ubuntu
ARG java_image_tag=17-jdk-jammy

# Celeborn client jars are architecture-independent: build once on the native platform.
FROM --platform=$BUILDPLATFORM eclipse-temurin:${java_image_tag} AS rss-client
ARG SPARK_VERSION=4.1
ARG CELEBORN_VERSION=0.7.0
ARG JDK_VERSION=17
# Git ref to build: a release tag (default), a branch such as `main`, or a full commit SHA.
# Keep it the same as the Celeborn server image.
ARG CELEBORN_GIT_REF=v${CELEBORN_VERSION}

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
# build celeborn binary (shallow fetch works for tags, branches and commit SHAs)
RUN git init -q /celeborn && cd /celeborn && \
    git remote add origin https://github.com/apache/celeborn.git && \
    git fetch -q --depth 1 origin "${CELEBORN_GIT_REF}" && \
    git checkout -q FETCH_HEAD && \
    git log -1 --format='Building celeborn %H (%cd)'
WORKDIR /celeborn
RUN ./build/make-distribution.sh -Pspark-${SPARK_VERSION} -Pjdk-${JDK_VERSION} && \
    cat *.tgz | tar -xvzf - && \
    mv apache-celeborn-*-bin /opt/celeborn

# Build the TPC-DS benchmark utility (Spark 4 / Scala 2.13 branch)
FROM --platform=$BUILDPLATFORM sbtscala/scala-sbt:eclipse-temurin-17.0.19_10_1.12.13_2.13.18 AS sbt
RUN git clone --depth 1 -b spark-4.0 https://github.com/aws-samples/emr-on-eks-benchmark.git /tmp/emr-on-eks-benchmark \
    && cd /tmp/emr-on-eks-benchmark/spark-sql-perf/ \
    && sbt +package
# Use the compiled Databricks SQL perf library to build benchmark utility
RUN mkdir -p /tmp/emr-on-eks-benchmark/benchmark/libs \
    && cp /tmp/emr-on-eks-benchmark/spark-sql-perf/target/scala-2.13/*.jar /tmp/emr-on-eks-benchmark/benchmark/libs \
    && cd /tmp/emr-on-eks-benchmark/benchmark && sbt assembly

FROM ${SPARK_BASE_IMAGE}
USER root

COPY --from=rss-client /opt/celeborn/spark/ ${SPARK_HOME}/jars/
COPY --from=sbt /tmp/emr-on-eks-benchmark/benchmark/target/scala-2.13/*.jar ${SPARK_HOME}/examples/jars/

WORKDIR ${SPARK_HOME}
# non-root user (uid 185) defined by the official Spark image
USER spark
