# OCI Console Walkthrough — Setting Up GPU Kubernetes Cluster

Step-by-step guide using the **OCI Console UI** to create an OKE cluster with GPU nodes that scale to zero.

---

## Step 1: Navigate to OKE

1. Log into [cloud.oracle.com](https://cloud.oracle.com)
2. Click **☰ Menu** → **Developer Services** → **Kubernetes Clusters (OKE)**
3. Select your **Compartment** from the left sidebar

## Step 2: Create the Cluster

1. Click **"Create cluster"**
2. Choose **"Custom create"** → Click **"Next"**
3. Fill in:

| Field | Value |
|---|---|
| Name | `llama-gpu-cluster` |
| Compartment | Your compartment |
| Kubernetes version | `v1.30.1` (or latest) |

4. Click **"Next"**

## Step 3: Network Setup

| Field | Value |
|---|---|
| VCN | Select existing or create new |
| K8s API endpoint subnet | Public subnet |
| Service LB subnet | Public subnet |

Click **"Next"**

## Step 4: Create CPU Node Pool

This tiny node runs the autoscaler and KEDA. It's always on (~$25/mo).

| Field | Value |
|---|---|
| Node pool name | `cpu-system-pool` |
| Node type | Managed |
| Shape | `VM.Standard.E4.Flex` |
| OCPUs | `1` |
| Memory | `8 GB` |
| Number of nodes | `1` |
| Image | Oracle Linux 8 |

Add label: `workload-type` = `system`

Click **"Next"** → **"Create cluster"** → Wait ~5-10 min

## Step 5: Add GPU Node Pool

Once cluster is **Active**:

1. Click cluster name → **"Node pools"** tab → **"Add node pool"**

| Field | Value |
|---|---|
| Node pool name | `gpu-inference-pool` |
| Shape | `VM.GPU.A10.1` |
| **Number of nodes** | **`0`** |
| Image | Oracle Linux **GPU** image |

Add labels:
- `nvidia.com/gpu.present` = `true`
- `workload-type` = `gpu-inference`

Click **"Add"**

> **Can't see GPU shapes?** Request quota at: **☰ → Governance → Limits** → search `gpu`

## Step 6: Configure kubectl

1. Click **"Access Cluster"** on your cluster page
2. Copy and run the kubeconfig command:

```bash
oci ce cluster create-kubeconfig \
  --cluster-id <CLUSTER_OCID> \
  --file $HOME/.kube/config \
  --region <REGION> \
  --token-version 2.0.0
```

3. Verify: `kubectl get nodes` — should show 1 CPU node

## Step 7: Run install.sh

```bash
chmod +x install.sh
./install.sh
```

This installs GPU Operator, Cluster Autoscaler, KEDA, and deploys the dashboard.

## Step 8: Set Up DNS

After install.sh completes, it will show you the KEDA interceptor IP. Create a DNS record:

```
gpu-app.example.com  →  <INTERCEPTOR_IP>
```

## How Requests Flow

```
Your app → gpu-app.example.com → KEDA Interceptor (CPU node)
                                      │
                            No GPU pod? Buffer request
                            Scale deployment 0 → 1
                            Cluster Autoscaler → GPU node (~5-8 min)
                            GPU Operator → install drivers
                            Pod ready → forward request → response
                                      │
                            5 min idle → scale back to 0
```

**First request after idle: ~5-10 min** (GPU node provisioning).
**Subsequent requests: instant** while pod is running.
