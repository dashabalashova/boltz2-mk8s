# 0. Intro

[Boltz-2](https://github.com/jwohlwend/boltz) is an open-source biomolecular foundation model for predicting both complex 3D structures and binding affinities. It enables accurate and fast *in silico* screening for drug discovery, matching the accuracy of physics-based free-energy perturbation (FEP) methods while running up to 1000x faster.

This guide explains how to set up a Managed Service for a [Kubernetes](https://kubernetes.io/) cluster and a shared filesystem in Nebius AI Cloud, and run Boltz-2 inference.

# 1. Prerequisites & environment check

Before we create the Kubernetes cluster and shared filesystem, make sure your local environment and Nebius project are set up. This section verifies the CLI tools we’ll use and shows how to point the Nebius CLI at the correct project.

Run the following checks on your machine:

```
kubectl version --client
jq --version
helm version
nebius version
```

copy project id from here: https://console.nebius.com/

```
PROJECT_ID=project-e00ty4c31bksp3a5ew
nebius config set parent-id $PROJECT_ID
```

# 2. Build & publish the Boltz Docker image

Build the runtime image locally, tag it for the Nebius container registry and push it.

```
sudo docker build -t boltz-runner -f docker/Dockerfile .

export REGION_ID=eu-north1
export NB_REGISTRY_PATH=$(nebius registry create \
  --name boltz-registry \
  --format json | jq -r ".metadata.id" | cut -d- -f 2)
docker tag boltz-runner:latest \
  cr.$REGION_ID.nebius.cloud/$NB_REGISTRY_PATH/boltz-runner:latest
docker push cr.$REGION_ID.nebius.cloud/$NB_REGISTRY_PATH/boltz-runner:latest
```

# 3. Create the Kubernetes cluster and node group

While the image push is happening, create the managed Kubernetes cluster and node group in the Nebius Console and attach a shared filesystem for persistent data and model artifacts.

## 3-1. Cluster

https://console.nebius.com/ -> create resource -> k8s cluster
name: boltz-cluster-3
allow puclic IP allocations: yes
Public endpoint: yes

## 3-2. Node group

eneter created cluster -> create node group
name: boltz-nodegroup-3
Public IPv4 addresses: allocate
Number of nodes: 2
With GPU
NVIDIA® L40S PCIe with AMD Epyc Genoa
Preset: 2-64-384
Node Storage Size: 64

+ Attach shared filesystem -> New shared filesystem -> name: boltz-fs-3, Size: 32 GiB
Mount tag: fs

Service account: +Create -> name: boltz-sa-3 -> editors: +Add -> Finish

Create node group

## 3-3. Get cluster credentials & install the CSI helper

Copy the <CLUSTER_ID> value from the Nebius Web UI (Cluster details) and paste it into the command below so your local kubectl talks to the managed cluster. Then install the small Helm chart that exposes the shared filesystem path to pods.

1. copy the ID from the WUI and paste it here
2. fetch credentials and write a kubeconfig for external access
   explanation:
   --external  -> requests credentials suitable for external kubectl access
   --force     -> overwrite any existing kubeconfig entry for this cluster

```
CLUSTER_ID=<CLUSTER_ID>
nebius mk8s cluster get-credentials --id $CLUSTER_ID --external --force
```

Now fetch and install the CSI helper chart that creates the StorageClass / Node tooling we use to mount the shared filesystem path inside pods:

1. download the chart from the Nebius OCI registry
2. install (or upgrade) the chart; set the dataDir where the FS will be mounted on nodes
3. cleanup the local tgz
 
```
helm pull oci://cr.eu-north1.nebius.cloud/mk8s/helm/csi-mounted-fs-path --version 0.1.3

helm upgrade csi-mounted-fs-path ./csi-mounted-fs-path-0.1.3.tgz \
  --install \
  --set dataDir="/mnt/fs/csi-mounted-fs-path-data/"

rm csi-mounted-fs-path-0.1.3.tgz
```

## 3-4. Create a PVC & verify the mount

Create a PVC that binds to the StorageClass created by the CSI helper. The PVC requests ReadWriteMany so multiple pods on multiple nodes can mount the same filesystem.

```
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: boltz-fs-pvc
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 32Gi
  storageClassName: csi-mounted-fs-path-sc
EOF
```

Check cluster health, pods and PVC state:

```
kubectl get nodes
kubectl get pods
kubectl get pvc
kubectl describe pvc boltz-fs-pvc
```

# 4. Upload input data (proteins and ligands)

Copy your local input files (protein PDBs / mmCIF, ligand SDF/MOL2, CSVs, etc.) into the cluster-shared filesystem so Boltz can access them from any pod.

If you already have the helper script, make it executable and run it:
```
chmod +x scripts-2/upload_data_to_pvc.sh
scripts-2/upload_data_to_pvc.sh
```

# 5. Pre-pull Boltz image to nodes & populate model cache

Pre-pulling the Boltz image onto nodes avoids long cold-pulls at job start. A separate job downloads model weights/caches into the shared filesystem so worker pods can start quickly.

Use the commands below (consistent paths to scripts-2):
```
REGION_ID=eu-north1
NB_REGISTRY_PATH=e00yy1kwngsst2c55j

export BOLTZ_IMAGE="cr.$REGION_ID.nebius.cloud/$NB_REGISTRY_PATH/boltz-runner:latest"
envsubst '${BOLTZ_IMAGE}' < scripts-2/boltz-pre-pulling-job.yaml | kubectl apply -f - & PID1=$!
kubectl apply -f scripts-2/boltz-cache-download-job.yaml & PID2=$!

wait $PID1
kubectl rollout status daemonset/boltz-pre-pulling --timeout=30m \
|| { echo "❌ boltz-pre-pulling failed"; exit 1; }
envsubst '${BOLTZ_IMAGE}' < scripts-2/boltz-pre-pulling-job.yaml | kubectl delete -f -

wait $PID2
kubectl wait --for=condition=complete job/boltz-cache-download --timeout=30m \
|| { echo "❌ boltz-cache-download failed"; exit 1; }
kubectl delete job boltz-cache-download
```

Final sanity check: list pods and their states:
```
kubectl get pods
```

6. Run predictions

Submit the Boltz job (the YAML in scripts-2/boltz-multi-job.yaml should define the Job(s) or a Job template that spawns multiple pods). Replace the image placeholder at apply time with envsubst:
```
envsubst '${BOLTZ_IMAGE}' < scripts-2/boltz-multi-job.yaml | kubectl apply -f -
```

Quick checks to watch progress:
```
kubectl get jobs
kubectl get pods
kubectl logs -f <pod>
```

# 7. Collect results & cleanup

Wait for the Job to finish, download results from the shared filesystem, and then clean up the Kubernetes job.
```
echo "Waiting for boltz-runner job to complete..."
kubectl wait --for=condition=complete job/boltz-runner --timeout=-1s
completed=$(kubectl get pods -l job-name=boltz-runner --no-headers | grep 'Completed' | wc -l)
echo "✅ $completed/16 pods completed."

chmod +x scripts-2/download_results_from_pvc.sh
scripts-2/download_results_from_pvc.sh

kubectl delete job boltz-runner --cascade=foreground
```

# 8. Delete resources

https://console.nebius.com/ -> Kubernetes -> https://console.nebius.com/ -> ... Delete
Storage -> Shared filesystems -> boltz-fs-3 -> Delete
Container Registry ... -> Delete
Administration -> IAM -> Service accounts -> boltz-sa-3 -> Delete