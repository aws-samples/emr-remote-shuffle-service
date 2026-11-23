#!/bin/bash
# Run the baseline (norss) and then the Celeborn run, one after the other, and wait for each.
# usage: ./run-both.sh   (logs job ids, states and result paths to stdout)
cd "$(dirname "$0")"
export AWS_REGION=${AWS_REGION:-us-west-2}
VC_NAME=${VC_NAME:-emr-c1315601-20260804-loadtest-mcp-1}
VC=$(aws emr-containers list-virtual-clusters --region "$AWS_REGION" --states RUNNING \
  --query "virtualClusters[?name=='$VC_NAME'].id | [0]" --output text)
for m in norss celeborn; do
  out=$(./run-tpcds.sh $m); id=$(echo "$out" | head -1 | awk '{print $1}')
  echo "$m submitted id=$id $(echo "$out" | tail -1)"
  while true; do
    s=$(aws emr-containers describe-job-run --region "$AWS_REGION" --virtual-cluster-id "$VC" --id "$id" \
      --query 'jobRun.[state,stateDetails]' --output text 2>/dev/null)
    case "$s" in COMPLETED*|FAILED*|CANCELLED*) echo "$m $id finished: $s at $(date -u +%FT%TZ)"; break;; esac
    sleep 60
  done
  sleep 120   # let executor pods terminate before the next run starts
done
echo ALL_DONE
