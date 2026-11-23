# TPC-DS 3TB benchmark: EMR on EKS 8.1.0 with and without Apache Celeborn

This benchmark runs the same TPC-DS job twice on EMR on EKS 8.1.0 (Apache Spark 4.1.1):

- **norss**: Spark's built-in sort shuffle, writing to the executors' own disks.
- **celeborn**: shuffle data pushed to an Apache Celeborn cluster on the same EKS cluster.

Both runs use the same image, data, queries, executor size and count, instance types and Availability Zone. The shuffle implementation is the only difference.

The Celeborn cluster now runs Celeborn **1.0.0-SNAPSHOT**, built from apache/celeborn `main` at commit [`6b153a5`](https://github.com/apache/celeborn/commit/6b153a508147f211dc578be97052317b5b61317d) (2026-11-20). It's deployed with the Helm chart from that same commit, which adds KEDA-based worker autoscaling and a drain hook for safe scale-in ([CELEBORN-2466](https://issues.apache.org/jira/browse/CELEBORN-2466)). Neither is in v0.7.0, the latest release; the JIRA fix version is 1.0.0. The server and both Spark client images are built from the same commit.

## Results

With Celeborn 1.0.0-SNAPSHOT, the TPC-DS 3TB run was about **1.86× faster** than Spark's built-in shuffle to EBS gp3 (sum of query times about 4,250 s → 2,280 s, −46%), consistently across two pairs of runs. The full write-up, with setup, per-query breakdown, issues found and caveats, is in **[RESULTS.md](RESULTS.md)**.

| | No RSS (shuffle to gp3 EBS) | Celeborn 1.0.0-SNAPSHOT |
|---|---|---|
| Pair A (2026-11-20/21): job time / sum of query times | 75m 17s / 4,309 s | 41m 35s / 2,283 s (1.89×) |
| Pair B (2026-11-22): job time / sum of query times | 73m 28s / 4,197 s | 41m 26s / 2,275 s (1.84×) |

### Previous run: Celeborn 0.7.0 (2026-11-20)

This run used a different setup, so don't compare it directly with new results: Celeborn 0.7.0 with 3 fixed masters and 3 fixed workers on `i4i.8xlarge`, and 40 static executors on `r6id.8xlarge` nodes with local NVMe.

| | No RSS (local NVMe) | Celeborn 0.7.0 |
|---|---|---|
| Job wall-clock time | 23m 54s | 23m 29s |
| Sum of query times (103 queries) | 1,252 s | 1,310 s (+4.6%) |
| 17 long queries (≥ 20 s) | 661 s | 672 s (+1.7%) |
| 86 short queries (< 20 s) | 592 s | 638 s (+7.8%) |
| Executors lost / fetch failures | 0 / 0 | 0 / 0 |

Celeborn was more than 5% faster on 11 queries and more than 5% slower on 52. The other 40 were within 5%. To see the per-query numbers, run `compare.py` on the S3 results `norss-20261120-060213` and `celeborn-20261120-062919` (see [RESULTS.md](RESULTS.md#data)).

What the numbers say:
- The shuffle-heavy queries (q4, q14a/b, q23a/b, q24a/b, q64, q67, q76) were within about ±4% in both modes.
- Most of the gap is on short queries. Celeborn adds fixed work to every stage: it registers the shuffle, asks the master for slots and commits files on the workers. A query that runs for 2 to 5 seconds can't absorb that cost.
- That setup favoured the baseline. Every executor had fast local NVMe, the executor count was fixed, and nothing ran on Spot. Celeborn is built for the opposite case: executors without local disks, dynamic allocation that releases executors, Spot interruptions, and shuffle data that survives a lost node.

q84 fails in both modes. Spark 4 enables ANSI mode by default, and the query text concatenates strings with `+`. The failure is in the query, not the shuffle, so `compare.py` leaves q84 out.

## Architecture

```
                                EKS cluster loadtest-mcp (us-west-2)
 ┌─────────────────────────────────────────┐   ┌───────────────────────────────────────────────┐
 │ NodePool spark-bench (us-west-2a only)  │   │ NodePool celeborn (us-west-2a/2b/2c)          │
 │ r5/r6i/r7i/r8i.8xlarge, on-demand       │   │ i7i.xlarge, on-demand                         │
 │ (32 vCPU, 256 GiB, EBS only, no NVMe)   │   │ (4 vCPU, 32 GiB, 937 GB NVMe RAID0)           │
 │                                         │   │                                               │
 │ EMR driver (2 cores, 8g)                │──▶│ celeborn-master-{0,1} (HA, Ratis)             │
 │ ≤19 executors (4 cores, 6g + 2g ovh)    │──▶│ celeborn-worker-us-west-2a-N  (1 → 4, KEDA)   │
 │ norss: shuffle to the gp3 root volume   │   │ celeborn-worker-us-west-2b-N  (1 → 4, KEDA)   │
 └─────────────────────────────────────────┘   │ shuffle dir /mnt/disk1 (emptyDir on NVMe)     │
            │ read 3 TB TPC-DS parquet         └───────────────────────────────────────────────┘
            ▼                                       ▲ KEDA ScaledObject per zone, triggers on
 s3://emr-on-eks-nvme-<account>-us-west-2/          │ disk and off-heap usage > 0.70, read from
       BLOG_TPCDS-TEST-3T-partitioned               │ Prometheus (worker PodMonitor)
```

The Spark executors and the 2a workers share an Availability Zone. Shuffle to and from the 2b workers crosses AZs, which adds latency and inter-AZ data transfer charges.

## Files

| File | Purpose |
|---|---|
| `karpenter.yaml` | `EC2NodeClass` `nvme-raid0` with `instanceStorePolicy: RAID0`, plus the `celeborn` and `spark-bench` NodePools. Both pools are on-demand only and tainted. Subnets are selected by the `karpenter.sh/discovery-3az` tag, which covers the private subnets in 2a, 2b and 2c. |
| `celeborn-values.yaml` | Values for the **official** Apache Celeborn Helm chart (`charts/celeborn` at `main` `6b153a5`). This chart is separate from the one in this repo's `charts/` folder. |
| `pod-templates/driver.yaml`, `executor.yaml` | Pin the Spark driver and executors to the `spark-bench` nodes in us-west-2a and tolerate the node taint. |
| `run-tpcds.sh` | Submits one EMR on EKS job run, either `norss` or `celeborn`. |
| `run-both.sh` | Runs `norss` then `celeborn` one after the other and waits for each to finish. |
| `compare.py` | Downloads the spark-sql-perf result JSON for two runs and prints a query-by-query comparison. It can also write the comparison to a CSV. |

## Prerequisites

- An EKS cluster with Karpenter v1 and an EMR on EKS virtual cluster. The scripts default to `loadtest-mcp` and the virtual cluster `emr-c1315601-20260804-loadtest-mcp-1`, whose namespace is `emr-c1315601-20260804-ns1`.
- [KEDA](https://keda.sh) in the cluster, for worker autoscaling. This setup uses KEDA 2.21.1.
- Prometheus scraping the Celeborn worker PodMonitor. This setup uses kube-prometheus-stack at `prometheus-kube-prometheus-prometheus.prometheus.svc.cluster.local:9090`, which picks up PodMonitors in every namespace.
- A job execution role that can read the TPC-DS data and write to the results bucket, and whose trust policy allows the virtual cluster's namespace. The scripts default to `emr-on-loadtest-mcp-execution-role`.
- 3 TB TPC-DS data in partitioned parquet, all 24 tables. The scripts default to `s3://emr-on-eks-nvme-<account>-us-west-2/BLOG_TPCDS-TEST-3T-partitioned`, which is about 993 GB.
- `kubectl`, `helm` (v3.8 or later) and AWS CLI v2. Your kube context and AWS credentials must point at the target account and cluster.
- The images, all built from Celeborn `main` `6b153a5`. You only need to rebuild them if you change versions (see [Building the images](#building-the-images)):
  - Server: `public.ecr.aws/myang-poc/celeborn-rss:clb1.0.0-SNAPSHOT-6b153a5_spark4.1_jdk17`
  - EMR 8.1.0 client, which includes the Celeborn client jar and the benchmark jar: `public.ecr.aws/myang-poc/celeborn-rss:emr8.1.0_clb1.0.0-SNAPSHOT-6b153a5`
  - Optional open source Spark 4.1.4 client: `public.ecr.aws/myang-poc/celeborn-rss:spark4.1.4_clb1.0.0-SNAPSHOT-6b153a5`

The Celeborn client in the Spark image must come from the same version as the server. The older `*_clb0.7.0` tags still exist in the registry, but don't mix them with the 1.0.0-SNAPSHOT server.

If you use a different cluster, bucket, role or virtual cluster, update the variables at the top of `run-tpcds.sh` and the names in `karpenter.yaml` (node role, discovery tags, AZs).

## Step by step

All commands run from this directory (`benchmark/emr8.1-celeborn/`).

### 1. Point at the right cluster

```bash
export AWS_REGION=us-west-2
aws sts get-caller-identity
kubectl config use-context arn:aws:eks:us-west-2:<account>:cluster/loadtest-mcp
```

### 2. Create the dedicated node pools

```bash
kubectl apply --dry-run=server -f karpenter.yaml   # validate first
kubectl apply -f karpenter.yaml
kubectl get ec2nodeclass nvme-raid0 -o jsonpath='{range .status.subnets[*]}{.zone}{"\n"}{end}'   # expect 2a, 2b, 2c
```

The pools start with no nodes. Karpenter launches nodes when pods are scheduled, and removes empty nodes after the `consolidateAfter` period in each pool.

### 3. Install KEDA

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --version 2.21.1 -n keda --create-namespace --wait
kubectl get apiservice v1beta1.external.metrics.k8s.io   # AVAILABLE should be True
```

Don't pipe `helm install` or `helm upgrade` into `head`. Once the output fills, helm is killed mid-run and the release is left in `pending-install` or `failed`.

### 4. Install Celeborn with the Helm chart from `main`

```bash
rm -rf /tmp/celeborn-main
git clone https://github.com/apache/celeborn.git /tmp/celeborn-main
git -C /tmp/celeborn-main checkout 6b153a508147f211dc578be97052317b5b61317d
kubectl create namespace celeborn
helm install celeborn /tmp/celeborn-main/charts/celeborn -n celeborn -f celeborn-values.yaml
kubectl wait -n celeborn --for=condition=Ready pod --all --timeout=900s
```

`celeborn-values.yaml` deploys:
- 2 masters, with HA turned on by the chart.
- One worker StatefulSet per zone (`celeborn-worker-us-west-2a`, `celeborn-worker-us-west-2b`). `worker.replicas: 2` is split evenly, so the cluster starts with 1 worker per zone.
- A KEDA `ScaledObject` per zone. Each zone scales from 1 to 4 workers (`maxReplicaCount: 4`), so 2 to 8 in total. It scales out when the fullest worker in the zone passes 0.70 disk usage or 0.70 off-heap memory usage. It scales in by at most 1 worker every 15 minutes, after a 30-minute stabilization window.
- A drain hook on every worker (`worker.drain.alwaysDecommission: true`). A worker is decommissioned before it's removed and waits for its shuffles to expire, for up to `terminationGracePeriodSeconds: 21900`.

Check the result:

```bash
kubectl get pods -n celeborn -o wide
kubectl get scaledobject,hpa -n celeborn            # READY=True, TARGETS show two values each
LEADER=$(kubectl exec -n celeborn celeborn-master-0 -- sh -c 'curl -s http://$(hostname -i):9098/api/v1/masters' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["leader"]["address"].split(".")[0])')
echo "leader: $LEADER"
kubectl exec -n celeborn "$LEADER" -- sh -c 'curl -s http://$(hostname -i):9098/api/v1/workers' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print({k: len(v) for k, v in d.items() if isinstance(v, list)})'
kubectl exec -n celeborn celeborn-worker-us-west-2a-0 -- cat /opt/celeborn/RELEASE   # expect 1.0.0-SNAPSHOT (git revision 6b153a5)
```

The leader must be non-empty and `workers` must match the number of worker pods.

Spark reaches the masters at `celeborn-master-{0,1}.celeborn-master-svc.celeborn.svc.cluster.local:9097`. If you change the release name, namespace or master count, update `CELEBORN_MASTERS` in `run-tpcds.sh`.

KEDA and Helm both set the worker StatefulSets' `replicas`. After KEDA has scaled a zone out, a plain `helm upgrade` resets it to the value in `celeborn-values.yaml`. Pass the current counts with `--set` when you upgrade.

### 5. Upload the pod templates

```bash
BUCKET=emr-on-loadtest-mcp-$(aws sts get-caller-identity --query Account --output text)-$AWS_REGION
aws s3 cp pod-templates/ s3://$BUCKET/celeborn-bench/pod-templates/ --recursive
```

### 6. Smoke test before the full runs

Run a few queries through Celeborn with a small executor count. This catches configuration and client/server version errors before you spend an hour on full runs. q64 is a good test because it hit the EMR serializer problem described under [Gotchas](#gotchas):

```bash
EXECUTORS=6 QUERIES="q3-v2.4,q64-v2.4" ./run-tpcds.sh celeborn
```

When the job completes, confirm the queries succeeded. `compare.py` prints `FAIL/NA` for a failed query:

```bash
python3 compare.py s3://$BUCKET/celeborn-bench/results/<smoke-run-id> s3://$BUCKET/celeborn-bench/results/<smoke-run-id>
```

You can also confirm that the master allocated shuffle slots for the job:

```bash
kubectl logs -n celeborn "$LEADER" | grep "offered slots"
```

### 7. Run the benchmark

```bash
./run-both.sh | tee run-both.log
```

This runs all 104 TPC-DS v2.4 queries once in each mode, `norss` first, then `celeborn`. Never run the two modes at the same time, because they would compete for nodes, S3 bandwidth and network.

To run one mode by itself:

```bash
./run-tpcds.sh norss
./run-tpcds.sh celeborn
```

These environment variables override the defaults: `QUERIES` (a comma-separated list), `EXECUTORS` (default 19), `IMAGE` (default the EMR client image above) and `VC_NAME`.

While the Celeborn run is going, you can watch the workers scale:

```bash
kubectl get hpa -n celeborn -w
```

A scale-out needs a new `i7i.xlarge` node, which takes a few minutes, and the new worker starts with no shuffle data. Autoscaling answers sustained load, not short bursts, so the Celeborn timings include the time it takes to scale out.

### 8. Validate the runs

A run that lost executors partway through measures recovery time, not shuffle performance. Check both drivers before you compare anything:

```bash
VC=$(aws emr-containers list-virtual-clusters --states RUNNING \
  --query "virtualClusters[?name=='emr-c1315601-20260804-loadtest-mcp-1'].id | [0]" --output text)
for id in <norss-job-id> <celeborn-job-id>; do
  aws s3 cp s3://$BUCKET/celeborn-bench/logs/$VC/jobs/$id/containers/spark-$id/spark-$id-driver/stderr.gz - --quiet \
    | gzip -dc > driver-$id.log
  echo "$id lost=$(grep -oE 'Lost executor [0-9]+' driver-$id.log | sort -u | wc -l) \
OOMKilled=$(grep -c OOMKilled driver-$id.log) FetchFailed=$(grep -c FetchFailed driver-$id.log)"
done
```

All three counters must be 0. If a run shows `OOMKilled`, raise `spark.executor.memoryOverhead` and run both modes again.

### 9. Compare

```bash
python3 compare.py s3://$BUCKET/celeborn-bench/results/norss-<ts> \
                   s3://$BUCKET/celeborn-bench/results/celeborn-<ts> \
                   results-celeborn-<ts>.csv
```

The script prints per-query times, the total, the overall speedup, the number of wins and losses, and the queries with the largest gains and losses.

### 10. Clean up

The Celeborn nodes keep running until you uninstall Celeborn: at least 2 `i7i.xlarge` nodes, and more while the workers are scaled out. The `spark-bench` nodes only run while a job runs and scale to zero afterwards.

Uninstall Celeborn before KEDA. Uninstalling the KEDA chart also deletes its CRDs. If the KEDA operator is gone while `ScaledObject`s still exist, their finalizers can leave the CRD deletion stuck.

```bash
helm uninstall celeborn -n celeborn --wait
kubectl delete namespace celeborn
helm uninstall keda -n keda --wait          # optional, if nothing else uses KEDA
kubectl delete -f karpenter.yaml            # removes both NodePools and the EC2NodeClass
# optional: results and logs
aws s3 rm s3://$BUCKET/celeborn-bench/ --recursive
```

## Spark configuration

These settings apply to both modes:

| Setting | Value |
|---|---|
| Release label | `emr-spark-8.1.0-latest` |
| Image | `public.ecr.aws/myang-poc/celeborn-rss:emr8.1.0_clb1.0.0-SNAPSHOT-6b153a5` |
| Driver | 2 cores, 8g heap, 1g overhead. Celeborn mode needs the larger heap: with 3g heap the driver ran out of memory at q81. |
| Executors | Dynamic allocation, up to 19 (`spark.executor.instances` and `spark.dynamicAllocation.maxExecutors` both set to `$EXECUTORS`), `spark.dynamicAllocation.executorIdleTimeout=30s`, each with 4 cores, 6g heap and 2g overhead |
| Other | `KryoSerializer`, `spark.shuffle.service.enabled=false`, `spark.network.timeout=2000s`, `spark.executor.heartbeatInterval=300s` |
| Benchmark | `com.amazonaws.eks.tpcds.BenchmarkSQL`: parquet, scale factor 3000, 1 iteration, no CBO, 104 queries |

These settings are added for `celeborn` mode only:

```properties
spark.shuffle.manager=org.apache.spark.shuffle.celeborn.SparkShuffleManager
spark.celeborn.master.endpoints=<2 master addresses, port 9097>
spark.sql.adaptive.localShuffleReader.enabled=false
spark.celeborn.client.spark.push.unsafeRow.fastWrite.enabled=false   # required on EMR, see Gotchas
spark.celeborn.client.push.replicate.enabled=false
spark.celeborn.client.push.excludeWorkerOnFailure.enabled=true
spark.celeborn.client.fetch.excludeWorkerOnFailure.enabled=true
spark.celeborn.client.commitFiles.ignoreExcludedWorker=true
```

## Gotchas

These problems came up while setting up the benchmark. Each one either broke a run or would have skewed the comparison.

1. **EMR's serializer is incompatible with Celeborn's UnsafeRow fast-write path.** With `celeborn.client.spark.push.unsafeRow.fastWrite.enabled=true` (the default), q64 fails with `IllegalStateException: Unexpected data corruption detected, expected to read 32 bytes but got 8`. The exception is thrown in `OptimizedUnsafeRowSerializers$FixedSizeUnsafeRowShuffleDeserializationStream`. EMR uses its own UnsafeRow serializer, and Celeborn's documentation says to set this option to `false` whenever UnsafeRow's memory layout has been changed. Always set it to `false` on EMR.
2. **Executor memory overhead.** In the first 0.7.0 runs, with 14g heap and 2g overhead, both modes had executors killed for exceeding their memory limit (`OOMKilled`, exit code 137): 22 in the baseline and 35 with Celeborn. That pair of runs showed Celeborn 23% slower, entirely from recovery time. Check every run for `OOMKilled` (step 8), and raise the overhead if you see any.
3. **The official chart's default JVM options don't work on JDK 17.** Flags such as `-XX:+PrintGCTimeStamps` and `-XX:+PrintGCDateStamps` make JDK 17 exit with `Unrecognized VM option`. `celeborn-values.yaml` uses `-Xlog:gc*:file=gc-<role>.out:time,uptime` instead.
4. **Celeborn volumes.** The chart adds a `chown` init container for `hostPath` volumes. That container inherits the pod's non-root user and can't change ownership of root-owned directories. This setup uses `emptyDir` instead. On RAID0 nodes `emptyDir` lives on the NVMe array, it's world-writable, and the chart skips the `chown` step for it.
5. **The CloudWatch Observability add-on injects ADOT Java agents.** Its auto-monitor adds Application Signals instrumentation to every workload, including the Celeborn StatefulSets. Since Celeborn only runs in one of the two modes, that would skew the comparison. `celeborn-values.yaml` sets `instrumentation.opentelemetry.io/inject-*: "false"` on the Celeborn pods.
6. **Kyverno mutates pods in `emr-*` namespaces.** The policy `emr-job-pods-same-az` adds zone affinity to EMR job pods unless the pod already sets a zone `nodeSelector`. The pod templates set `topology.kubernetes.io/zone: us-west-2a`, so the policy leaves the Spark pods alone.
7. **Instance capacity.** `m6id.8xlarge` hit `InsufficientInstanceCapacity` in us-west-2a. If the `spark-bench` pool allows several instance types, check that both modes ran on the same type, or the comparison measures hardware rather than shuffle.
8. **Incomplete dataset copy.** `s3://emr-on-loadtest-mcp-…/BLOG_TPCDS-TEST-3T-partitioned` holds only 18 of the 24 tables (191 GB). Use the complete copy in `emr-on-eks-nvme-…`, which holds all 24 tables (993 GB).
9. **The query filter can't be empty.** The EMR API rejects an empty string in `entryPointArguments`, so `run-tpcds.sh` passes the full list of 104 queries explicitly.
10. **Graceful shutdown needs fixed worker ports.** With `celeborn.worker.graceful.shutdown.enabled: true`, a worker on random ports fails at startup with `If enable graceful shutdown, the worker should use non-zero port`. `celeborn-values.yaml` pins rpc/fetch/push/replicate to 9091/9092/9093/9094.
11. **Two masters with `emptyDir` Ratis storage lose their leader when one master moves.** When Karpenter replaced the node under `celeborn-master-0`, the pod came back with an empty Raft log. A 2-node group needs both members for a quorum, so no leader could be elected, and Spark failed with `MasterNotLeaderException ... leader is not present`. To recover, delete both master pods together so they form a fresh group: `kubectl delete pod -n celeborn celeborn-master-0 celeborn-master-1`. To prevent it, run 3 masters or put `/mnt/celeborn_ratis` on a PersistentVolume.
12. **Pod sizing must fit `i7i.xlarge`.** Allocatable is about 3.9 vCPU and 29.8 GiB, and each node also runs a master and the daemonsets. Karpenter refused to replace nodes while worker + master + daemonset requests came to 4110m CPU. The worker requests 2500m CPU and 24Gi. Its memory limit (30Gi) is higher than what's left on a node that also runs a master, so a worker that fills its off-heap memory can be evicted.
13. **Karpenter subnet discovery.** The 2c private subnet only carries the `karpenter.sh/discovery-3az` tag. With the NodeClass selecting `karpenter.sh/discovery`, 2c workers stayed Pending with "no instance type met the scheduling requirements or had a required offering".
14. **The worker drain is slow by design.** With `alwaysDecommission: true`, every worker removal (scale-in, rollout, node drain) waits for its shuffles to expire, for up to `celeborn.worker.decommission.forceExitTimeout` (6h by default). A rollout during a run can take a long time. Node loss (Karpenter consolidation or replacement, Spot interruption) still destroys the `emptyDir` data whatever the hook does.

## Building the images

Run these from the repository root. Each Dockerfile builds Celeborn from source with `-Pspark-4.1 -Pjdk-17`. The client Dockerfiles also build the benchmark jar from the `spark-4.0` branch of `aws-samples/emr-on-eks-benchmark`, which targets Scala 2.13. Both build stages run on the build machine's own architecture. Only the final image is per-architecture.

`CELEBORN_GIT_REF` selects what to build: a release tag (the default is `v${CELEBORN_VERSION}`, which is `v0.7.0`), a branch, or a full commit SHA. Build the server and the clients from the same ref.

```bash
R=public.ecr.aws/myang-poc/celeborn-rss
REF=6b153a508147f211dc578be97052317b5b61317d   # apache/celeborn main, 1.0.0-SNAPSHOT
TAG=clb1.0.0-SNAPSHOT-6b153a5
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws

docker buildx build --platform linux/amd64,linux/arm64 --build-arg CELEBORN_GIT_REF=$REF \
  -t $R:${TAG}_spark4.1_jdk17 -f docker/celeborn-server/Dockerfile . --push
docker buildx build --platform linux/amd64,linux/arm64 --build-arg CELEBORN_GIT_REF=$REF \
  -t $R:emr8.1.0_${TAG} -f docker/celeborn-emr-client/Dockerfile . --push
# optional: open source Spark 4.1.4 client
docker buildx build --platform linux/amd64,linux/arm64 --build-arg CELEBORN_GIT_REF=$REF \
  -t $R:spark4.1.4_${TAG} -f docker/celeborn-oss-client/Dockerfile . --push
```

Check what an image contains with `docker run --rm $R:${TAG}_spark4.1_jdk17 cat /opt/celeborn/RELEASE`.

## Suggested next tests

- **Scale-out under load.** Watch `kubectl get hpa -n celeborn -w` during the Celeborn run, and record when workers are added and how long the new nodes take.
- **Dynamic allocation that releases executors.** Set `spark.dynamicAllocation.shuffleTracking.enabled=false`, and add `spark.shuffle.sort.io.plugin.class=org.apache.spark.shuffle.celeborn.CelebornShuffleDataIO` in Celeborn mode. The baseline would then need `shuffleTracking.enabled=true`, which keeps executors alive while they hold shuffle data.
- **Spot executors and node loss.** Run executors on Spot, or terminate an executor node in the middle of a run. This measures how much recomputation Celeborn saves.
- **Workers in one AZ.** Run with only the 2a zone to remove the cross-AZ shuffle traffic to the 2b workers, and compare.
- **Repeat runs.** Run each mode 3 times and report the median, so you can see how much results vary between runs.
