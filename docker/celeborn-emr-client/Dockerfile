#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

ARG SPARK_BASE_IMAGE=public.ecr.aws/emr-on-eks/spark/emr-6.10.0:latest
ARG java_image_tag=8-jdk-focal

FROM eclipse-temurin:${java_image_tag} AS clb-client
ARG SPARK_VERSION=3.3
ARG CELEBORN_VERSION=0.5
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

RUN yum install bind-utils -y

WORKDIR /home/hadoop
USER hadoop:hadoop