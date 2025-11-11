#!/usr/bin/env bash
set -euo pipefail

git clone https://github.com/dashabalashova/boltz2-mk8s.git
cd boltz2-mk8s

# 1. docker build

docker build -t boltz-runner -f docker/Dockerfile .

# 2. MK8S cluster

# 2.1 create registry, service account, MK8S cluster and node group

# 2.1 export IDs

export PROJECT_ID=
export REGION_ID=
export NB_REGISTRY_ID=
export CLUSTER_ID=
export MOUNT_TAG=

# 2.3 command line interface (CLI) configuration

nebius config set parent-id $PROJECT_ID

nebius iam get-access-token | \
  docker login cr.$REGION_ID.nebius.cloud \
    --username iam \
    --password-stdin

export NB_REGISTRY_PATH=$(echo $NB_REGISTRY_ID | cut -d- -f2)

docker tag boltz-runner cr.$REGION_ID.nebius.cloud/$NB_REGISTRY_PATH/boltz-runner:v1.0.0
docker push cr.$REGION_ID.nebius.cloud/$NB_REGISTRY_PATH/boltz-runner:v1.0.0

# 3. Container Storage Interface PVC & data

nebius mk8s cluster get-credentials --id $CLUSTER_ID --external

# 3.1 install CSI driver

helm pull oci://cr.eu-north1.nebius.cloud/mk8s/helm/csi-mounted-fs-path --version 0.1.3

helm upgrade csi-mounted-fs-path ./csi-mounted-fs-path-0.1.3.tgz --install \
  --set dataDir=/mnt/$MOUNT_TAG/csi-mounted-fs-path-data/

rm csi-mounted-fs-path-0.1.3.tgz

# 3.2 mounting shared filesystems to pods

kubectl apply -f scripts/video/csi-pvc-and-pod.yaml

# 3.3 upload data

kubectl cp ./data/. my-csi-app:/data

kubectl exec -it my-csi-app -- ls /data

# 4. image and cache

# 4.1 pull image and cache

export BOLTZ_IMAGE=cr.$REGION_ID.nebius.cloud/$NB_REGISTRY_PATH/boltz-runner:v1.0.0
envsubst '$BOLTZ_IMAGE' < scripts/video/boltz-pre-pull.yaml | kubectl apply -f -

kubectl apply -f scripts/video/boltz-cache-populate-job.yaml

# 4.2 wait

kubectl exec -it my-csi-app -- ls -lah /data/.boltz
kubectl logs jobs/boltz-cache-populate

if kubectl rollout status daemonset/boltz-pre-pull --timeout=20m; then
  echo "✅ COMPLETED"
  kubectl delete daemonset/boltz-pre-pull
else
  echo "❌ FAILED"
  exit 1
fi

if kubectl wait --for=condition=complete job/boltz-cache-populate --timeout=20m; then
  echo "✅ COMPLETED"
  kubectl delete job boltz-cache-populate --wait=false || true
  kubectl delete pods -l job-name=boltz-cache-populate || true
else
  echo "❌ FAILED"
  exit 1
fi

# 5. run boltz and download results

envsubst '$BOLTZ_IMAGE' < scripts/video/boltz-multi-job.yaml | kubectl apply -f -

kubectl get pods
kubectl logs jobs/boltz-runner
kubectl exec -it my-csi-app -- ls -lah /data/results

echo "Waiting for boltz-runner job to complete..."
kubectl wait --for=condition=complete job/boltz-runner --timeout=-1s
completed=$(kubectl get pods -l job-name=boltz-runner --no-headers | grep 'Completed' | wc -l)
echo "✅ COMPLETED: $completed/16 pods"

kubectl cp my-csi-app:/data/results ./results -c my-csi-app