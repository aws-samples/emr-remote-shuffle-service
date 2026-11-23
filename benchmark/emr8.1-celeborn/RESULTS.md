# TPC-DS 3TB on EMR on EKS 8.1.0: with and without Apache Celeborn

Test results, 2026-11-20 to 2026-11-22, EKS cluster `loadtest-mcp` (us-west-2).

## Summary

- **Celeborn made the TPC-DS 3TB run about 1.86× faster.** Total query time fell from about 4,250 s to about 2,280 s (−46%), and job wall-clock time from about 74 minutes to 41 minutes.
- **The result held across two separate pairs of runs.** The speedups were 1.89× and 1.84×, and the per-query times were consistent between pairs.
- **All of the gain is on long, shuffle-heavy queries.** The 35 queries that take 20 s or more without Celeborn ran 53% faster. The 68 short queries were 0.5% faster in one pair and 8.1% slower in the other. Celeborn adds a few seconds of fixed cost per stage, which short queries can't absorb.
- **The setup favours Celeborn.** Without Celeborn, executors shuffle to an EBS gp3 root volume shared by 7 executors per node. Celeborn moves that shuffle to the NVMe disks on its own nodes. The earlier Celeborn 0.7.0 test, where executors had local NVMe, showed no gain (+4.6% runtime).
- **Every Celeborn run lost executors to out-of-memory kills, and the baselines lost none.** 4 to 7 executors per run hit their 8 GiB container limit. Spark recovered each time without fetch failures, so the Celeborn times include some recovery.

## Test setup

Both modes in a pair use the same image, data, queries, executor shape and count, nodes and Availability Zone. The shuffle implementation is the only difference.

| | |
|---|---|
| Spark | EMR on EKS 8.1.0 (`emr-spark-8.1.0-latest`, Apache Spark 4.1.1) |
| Spark image | `public.ecr.aws/myang-poc/celeborn-rss:emr8.1.0_clb1.0.0-SNAPSHOT-6b153a5` |
| Celeborn | 1.0.0-SNAPSHOT, built from apache/celeborn `main` at `6b153a5`. The server and the client use the same build. |
| Celeborn cluster | 2 masters (Raft HA) and 2 workers, one worker each in us-west-2a and us-west-2b, on `i7i.xlarge` (4 vCPU, 32 GiB, 937 GB NVMe RAID0). KEDA can scale each zone to 4 workers, but nothing scaled during these runs. |
| Spark nodes | `spark-bench` NodePool, us-west-2a only, EBS-only r-family 8xlarge (`r6i.8xlarge` in these runs, 32 vCPU, 256 GiB), on-demand |
| Shuffle without Celeborn | Executor local dirs on the node's 100 GiB gp3 root volume (3,000 IOPS, 125 MB/s by default), shared by up to 7 executors per node |
| Executors | Dynamic allocation, at most 20 (pair A) or 19 (pair B), each with 4 cores, 6g heap and 2g overhead |
| Driver | 8g heap and 1g overhead. Pair A used 4 cores and pair B 2 cores. |
| Workload | TPC-DS v2.4, scale factor 3000 (3 TB partitioned parquet in S3), 104 queries, 1 iteration. q84 fails in both modes (Spark 4 ANSI mode), so 103 queries are compared. |

The Celeborn-mode settings are listed in [README.md](README.md#spark-configuration).

## Results

### Headline

| | Pair A, no RSS | Pair A, Celeborn | Pair B, no RSS | Pair B, Celeborn |
|---|---|---|---|---|
| Date | 2026-11-20 | 2026-11-21 | 2026-11-22 | 2026-11-22 |
| EMR job ID | `000000038fpumnrs5mg` | `000000038fu6791m804` | `000000038g2nh5b2est` | `000000038g30a4aeik9` |
| Job wall-clock time | 75m 17s | 41m 35s | 73m 28s | 41m 26s |
| Sum of query times | 4,309 s | 2,283 s | 4,197 s | 2,275 s |
| Speedup | | **1.89× (−47.0%)** | | **1.84× (−45.8%)** |
| Executors lost (OOMKilled) | 0 | 7 | 0 | 4 |
| Fetch failures | 0 | 0 | 0 | 0 |

### Long and short queries

The split is by each query's time without Celeborn.

| | Pair A | Pair B |
|---|---|---|
| 35 long queries (≥ 20 s) | 3,786 s → 1,763 s (−53.4%) | 3,719 s → 1,758 s (−52.7%) |
| 68 short queries (< 20 s) | 522 s → 520 s (−0.5%) | 478 s → 517 s (+8.1%) |
| Celeborn >5% faster / >5% slower / within 5% | 46 / 31 / 26 | 25 / 47 / 31 |

The long queries account for 88% of the baseline time and almost all of the saving. The short-query result swings between pairs because each of those queries runs for only a few seconds, so a second or two of noise is a large percentage.

### Largest gains

Times are the mean of pairs A and B.

| Query | No RSS | Celeborn | Speedup (mean) | Pair A | Pair B |
|---|---|---|---|---|---|
| q67 | 493 s | 85 s | 5.81× | 5.71× | 5.93× |
| q24b | 392 s | 137 s | 2.86× | 2.86× | 2.87× |
| q24a | 363 s | 143 s | 2.53× | 2.51× | 2.56× |
| q29 | 230 s | 47 s | 4.92× | 4.93× | 4.92× |
| q78 | 232 s | 76 s | 3.05× | 3.11× | 2.98× |
| q75 | 196 s | 64 s | 3.06× | 2.94× | 3.19× |
| q5 | 140 s | 35 s | 4.03× | 4.20× | 3.86× |
| q97 | 140 s | 40 s | 3.48× | 3.53× | 3.42× |
| q65 | 121 s | 27 s | 4.49× | 4.51× | 4.47× |
| q17 | 71 s | 18 s | 3.92× | 3.68× | 4.16× |
| q64 | 118 s | 71 s | 1.66× | 1.76× | 1.56× |
| q23b | 127 s | 87 s | 1.46× | 1.39× | 1.52× |

These queries shuffle large volumes between stages. Without Celeborn that shuffle is written to and read back from the shared gp3 volume, which is the bottleneck. With Celeborn it goes over the network to the workers' NVMe.

Long queries that barely changed (within ±10%): q14a, q14b, q28, q44, q76, q93. Most of their time goes to scanning and aggregating data rather than shuffling it.

### Where Celeborn is slower

Times are the mean of pairs A and B.

| Query | No RSS | Celeborn | Ratio |
|---|---|---|---|
| ss_max | 1.8 s | 3.7 s | 0.49× |
| q39b | 2.6 s | 4.3 s | 0.61× |
| q15 | 5.9 s | 8.3 s | 0.70× |
| q35 | 8.5 s | 9.9 s | 0.85× |
| q1 | 10.1 s | 11.8 s | 0.86× |

The worst absolute loss in either pair was 7 s (q94 in pair B). For every stage, Celeborn registers the shuffle, asks the master for slots and commits files on the workers. That costs about 1 to 2 s per query whatever its size, so it shows up as a large percentage on queries that run for only a few seconds.

### Consistency between runs

Across the long queries, the median difference in a query's time between pair A and pair B was 5.1% without Celeborn and 3.5% with Celeborn. The total speedup differed by 0.05× (1.89× and 1.84×). One pair per mode is enough to see the effect, but repeat runs are needed before quoting single-query numbers to better than about ±5%.

## Issues found during testing

### Executors run out of memory in Celeborn mode only

All three Celeborn runs with 6g heap + 2g overhead executors had executors killed with exit code 137 at the 8 GiB container limit:

| Run | Executors OOMKilled |
|---|---|
| Pair A, Celeborn | 7 |
| Failed run, 2026-11-22 (below) | at least 1 |
| Pair B, Celeborn | 4 |

No baseline run lost an executor. The Celeborn client keeps push buffers in off-heap memory, and 2g of overhead isn't enough room for them. Because the shuffle data lives on the Celeborn workers, losing an executor never caused a fetch failure; only that executor's in-progress tasks reran. Raising `spark.executor.memoryOverhead` to 3–4g in both modes should remove this.

### Driver out of memory with a 3g driver

A Celeborn run on 2026-11-22 (`000000038g24c21m6t0`) failed at q81, after 80 of 104 queries. Its driver had 3g heap + 1g overhead, a 4 GiB container limit, and peaked at 3.88 GiB before the container was killed. The baseline in that pair peaked at 3.80 GiB with the same limit and only just finished. In Celeborn mode the driver also tracks every shuffle and its slot assignments, so it needs more memory. With 8g heap + 1g overhead, the Celeborn driver peaked at 4.9 GiB (pair B). Don't run Celeborn mode with less than about 6 GiB of driver memory for this workload.

### Nodes replaced in the middle of a run

A baseline run on 2026-11-20 (`000000038fpftvbkqhf`) failed with 14 lost executors and 24 fetch failures. Karpenter drift-replaced every node on the `nvme-raid0` NodeClass, including both Celeborn nodes, within 3 minutes. The NodeClass selected `al2023@latest`, and the most likely trigger is a new EKS AMI (`v20261119`) going live during the run. The fixes, now in `karpenter.yaml` and the pod templates:
- the AMI is pinned (`al2023@v20261119`);
- both NodePools have a `Drifted` disruption budget of 0 nodes;
- the driver and executors carry `karpenter.sh/do-not-disrupt: "true"`.

### Smaller problems

- **Executor requests without a cap.** With dynamic allocation and no `spark.dynamicAllocation.maxExecutors`, Spark kept up to several hundred executor pods Pending because the 96-vCPU NodePool limit only fits about 21. `run-tpcds.sh` now sets `maxExecutors` to `$EXECUTORS`.
- **Two-master Raft group.** When Karpenter replaced the node under one master, that master came back with an empty Raft log, because its storage is an `emptyDir`. Neither master could then become leader, and Spark failed with `MasterNotLeaderException`. Restarting both masters together fixed it. Three masters, or a PersistentVolume for the Raft directory, would prevent it.
- **Expired credentials between runs.** When the AWS session credentials on the machine running `run-both.sh` expired, `run-both.sh` could neither see that the baseline had finished nor submit the Celeborn run. In pair A the two halves ran about 18 hours apart. The timings aren't affected.

## Comparison with the earlier Celeborn 0.7.0 test

| | Celeborn 0.7.0 test (2026-11-20) | This test (pairs A and B) |
|---|---|---|
| Executor nodes | `r6id.8xlarge` with local NVMe | EBS-only r-family 8xlarge |
| Executors | 40 static, 14g heap + 6g overhead | Up to 19–20 dynamic, 6g heap + 2g overhead |
| Celeborn cluster | 3 masters and 3 workers on `i4i.8xlarge` | 2 masters and 2 workers on `i7i.xlarge`, autoscaling |
| Sum of query times, no RSS → Celeborn | 1,252 s → 1,310 s (+4.6%) | about 4,250 s → about 2,280 s (−46%) |

The two tests answer different questions. When every executor has fast local NVMe, Spark's built-in shuffle is already fast, and Celeborn's per-stage overhead makes it slightly slower overall. When executors shuffle to shared network storage, Celeborn removes the bottleneck and the job runs almost twice as fast.

## Caveats

- **Baseline disk:** the baseline uses the default gp3 settings. A gp3 volume with more provisioned throughput or IOPS, or a dedicated shuffle volume, would narrow the gap.
- **Repeats:** each pair is one run per mode, and there are only two valid pairs.
- **Recovery time included:** the Celeborn times include recovery from 4–7 executor OOM kills per run, so with enough memory overhead Celeborn would probably be slightly faster than shown.
- **Cross-AZ traffic:** shuffle to and from the us-west-2b worker crosses Availability Zones, which adds latency and inter-AZ data transfer charges. Those charges aren't included here.
- **Small Celeborn cluster:** 2 × `i7i.xlarge` was enough for this load. The fullest worker peaked at about 10% disk and 1% off-heap usage, so the KEDA autoscaling threshold (70%) was never reached and autoscaling wasn't exercised.
- **Pre-release build:** Celeborn 1.0.0-SNAPSHOT is unreleased, and the Helm chart features used (KEDA autoscaling and worker drain) are only in `main`.

## Recommended next tests

1. **More executor memory overhead:** rerun both modes with `spark.executor.memoryOverhead=4g` to remove the Celeborn executor OOM kills and measure the clean difference.
2. **Shorter executor idle timeout:** both modes now run with `spark.dynamicAllocation.executorIdleTimeout=30s`, which isn't in these results. Rerun the pair to measure its effect.
3. **Repeats:** run each mode at least 3 times and report the median.
4. **Fair NVMe baseline:** repeat on executor nodes with local NVMe (`r6id`), like the 0.7.0 test, with the current Celeborn build.
5. **Spot interruption:** interrupt executor nodes, or use Spot, to measure how much recomputation Celeborn saves when executors are lost.
6. **Single zone:** run with Celeborn workers in us-west-2a only to remove cross-AZ shuffle.

## Data

The per-query numbers aren't committed. The raw spark-sql-perf results are kept in S3 under `s3://$BUCKET/celeborn-bench/results/<run-id>/`, and `compare.py` rebuilds the per-query comparison from them.

| Comparison | Baseline run ID | Celeborn run ID |
|---|---|---|
| Pair A | `norss-20261120-171626` | `celeborn-20261121-130035` |
| Pair B | `norss-20261122-101019` | `celeborn-20261122-112702` |
| Earlier Celeborn 0.7.0 test | `norss-20261120-060213` | `celeborn-20261120-062919` |

```bash
# print the per-query comparison; add a third argument to also write it to a CSV
python3 compare.py s3://$BUCKET/celeborn-bench/results/norss-20261122-101019 \
                   s3://$BUCKET/celeborn-bench/results/celeborn-20261122-112702
```
