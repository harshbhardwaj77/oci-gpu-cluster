# OCI Console Walkthrough — GPU Kubernetes Cluster (Scale-to-Zero)

Step-by-step guide using the **OCI Console UI** to create an OKE cluster with GPU nodes that scale to zero. This uses the **Quick Create** wizard, which automatically sets up the VCN, subnets, security lists, and internet gateway for you.

---

## Step 1: Navigate to OKE

1. Log into [cloud.oracle.com](https://cloud.oracle.com)
2. Click **☰ Menu** → **Developer Services** → **Kubernetes Clusters (OKE)**
3. Select your **Compartment** from the left sidebar (e.g., `prod`)

## Step 2: Create the Cluster (Quick Create)

1. Click **"Create cluster"**
2. Select **"Quick create"** → Click **"Submit"**

### Cluster Configuration

| Field | Value |
|---|---|
| Name | `llama-gpu-cluster` |
| Compartment | Your compartment (e.g., `prod`) |
| Kubernetes version | `v1.34.2` (or latest available) |
| Kubernetes API endpoint | **Public endpoint** |
| Kubernetes worker nodes | **Private workers** |
| Pod shape | `VM.Standard.E4.Flex` |
| Number of OCPUs per node | `1` |
| Amount of memory (GB) | `8` |
| Number of nodes | `1` |

### Add-ons & Plugins

| Add-on | Recommendation |
|---|---|
| CoreDNS | ✅ Keep enabled (required) |
| KubeProxy | ✅ Keep enabled (required) |
| Kubernetes Dashboard | ❌ Disable (security risk, use `kubectl` instead) |

### Important Prompts

- **"Basic Cluster Confirmation"** dialog: ✅ Check **"Create a Basic cluster"** and click **Continue**. The Basic cluster is free. Enhanced costs ~$74/month and is not needed for this setup.

3. Click **"Create cluster"** → Wait ~5-10 minutes for the cluster to become **Active**

> **What Quick Create does for you automatically:**
> - Creates a VCN with public and private subnets
> - Sets up security lists, route tables, and an internet gateway
> - Creates a NAT gateway for private worker nodes
> - Configures the Kubernetes API endpoint (public access)
> - Creates 1 CPU node pool with the shape you selected

## Step 3: Request GPU Quota (if needed)

Most OCI accounts have GPU limits set to `0` by default. You need to request access before creating a GPU node pool.

1. Click **☰ Menu** → **Governance & Administration** → **Limits, Quotas and Usage**
2. Set **Service** = `Compute`, **Scope** = your Availability Domain
3. Type `GPU` in the filter box
4. Find the row: **"GPUs for GPU.A10 based VM and BM Instances"** (`gpu-a10-count`)
5. Click the `...` on the right → **"Request a service limit increase"**
6. Set the limit to `2` and provide a business reason
7. Submit — Oracle typically responds within a few hours

> **Tip:** Once you receive a reply asking to confirm the shape, respond with:
> "VM.GPU.A10.1 — 2 instances for AI inference workloads on OKE."

## Step 4: Configure kubectl

Once the cluster shows **Active** status:

1. Click your cluster name → Click **"Access Cluster"** button
2. Select **"Cloud Shell Access"** (easiest) or **"Local Access"**
3. Copy and run the kubeconfig command:

```bash
oci ce cluster create-kubeconfig \
  --cluster-id <CLUSTER_OCID> \
  --file $HOME/.kube/config \
  --region <REGION> \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT
```

4. Verify: `kubectl get nodes` — should show 1 CPU node in `Ready` state

## Step 5: Run the Install Script

```bash
git clone https://github.com/harshbhardwaj77/oci-gpu-cluster.git
cd oci-gpu-cluster
chmod +x install.sh
./install.sh
```

The script will ask for:
- **GPU Node Pool OCID** — enter `dummy` if GPU pool isn't created yet
- **CPU Node Pool OCID** — find at: Cluster → Node Pools → `pool1` → Copy OCID
- **Domain** — e.g., `gpu.yourdomain.com` (or press Enter for `gpu-app.local`)

The script installs:
1. ✅ NVIDIA GPU Operator (auto-installs drivers on GPU nodes)
2. ✅ Cluster Autoscaler (scales GPU pool 0 → 3 nodes)
3. ✅ KEDA + HTTP Add-on (request-driven pod scaling + LoadBalancer)
4. ✅ GPU Dashboard app via ConfigMaps (zero Docker build needed)

## Step 6: Add GPU Node Pool (after quota is approved)

Once Oracle approves your GPU quota:

1. Go to your cluster → **"Node pools"** tab → **"Add node pool"**

| Field | Value |
|---|---|
| Node pool name | `gpu-pool` |
| Shape | `VM.GPU.A10.1` |
| **Number of nodes** | **`0`** (critical for scale-to-zero!) |
| Image | Oracle Linux **GPU** image |

2. Click **"Add"** and copy the new pool's **OCID**

3. Update the Cluster Autoscaler with the real GPU pool OCID:

```bash
kubectl edit deployment cluster-autoscaler -n kube-system
# Find the --nodes=0:3:<OLD_OCID> line and replace with the real GPU pool OCID
```

## Step 7: Set Up DNS

Get the public IP of the KEDA load balancer:

```bash
kubectl get svc keda-add-ons-http-interceptor-proxy -n keda
```

Create a DNS **A Record** at your DNS provider (e.g., Cloudflare):

```
gpu.yourdomain.com  →  <EXTERNAL-IP from above>
```

## How It Works

```
User visits gpu.yourdomain.com
         │
         ▼
┌─────────────────────────────┐
│  OCI Load Balancer (Free)   │
│  Points to KEDA Interceptor │
└──────────┬──────────────────┘
           │
           ▼
┌─────────────────────────────┐
│  KEDA HTTP Interceptor      │  ← Always running on CPU node (~$25/mo)
│  Holds request, scales pod  │
└──────────┬──────────────────┘
           │
  No GPU pod? → Scale 0 → 1
  No GPU node? → Cluster Autoscaler → OCI provisions VM.GPU.A10.1
  GPU Operator → installs NVIDIA drivers
  Pod starts → serves request
           │
           ▼
┌─────────────────────────────┐
│  GPU Dashboard Pod          │  ← Only runs when needed
│  NVIDIA A10 (24GB VRAM)     │
│  Shows GPU stats + system   │
└─────────────────────────────┘
           │
  5 min idle → pod scales to 0
  GPU node deprovisioned → cost = $0
```

## Timing

| Event | Duration |
|---|---|
| First request after idle (cold start) | ~5-10 min |
| Subsequent requests while pod is running | Instant |
| Scale-down after idle | 5 min (configurable) |

## Cost Summary

| Component | Always Running? | Cost |
|---|---|---|
| CPU node (1× 1-OCPU E4.Flex) | ✅ 24/7 | ~$25/mo |
| GPU node (VM.GPU.A10.1) | ❌ On demand | ~$1.60/hr |
| OKE Control Plane (Basic) | ✅ Managed | Free |
| OCI Load Balancer | ✅ 24/7 | Free (Always Free tier) |

**With scale-to-zero, GPU costs are only incurred during active usage.**

## Next Steps: Deploying Llama for Production

> **Important:** The current `install.sh` deploys a **GPU Dashboard test app** to verify that the scale-to-zero infrastructure works correctly. It does NOT deploy the actual Llama AI model.

Once the GPU dashboard confirms everything is working (GPU node provisions, pod schedules, dashboard loads), you will need to:

1. **Edit `install.sh`** — Replace Step 4 (GPU Dashboard deployment) with the Llama deployment. A ready-made manifest is already included at `k8s/vllm-llama-deployment.yaml`.

2. **Get a Hugging Face token** — Llama models are gated. Sign up at [huggingface.co](https://huggingface.co), request access to `meta-llama/Llama-3.1-8B-Instruct`, and generate an API token.

3. **Update the secret** — Replace `<YOUR_HUGGING_FACE_TOKEN>` in `k8s/vllm-llama-deployment.yaml` with your real token.

4. **Deploy manually or via updated script:**

```bash
# Option A: Apply the Llama manifest directly
kubectl apply -f k8s/vllm-llama-deployment.yaml

# Option B: Integrate into install.sh by replacing the gpu-dashboard.yaml step
```

5. **Update the KEDA HTTPScaledObject** — Point it to the `vllm-llama` service in the `llm-inference` namespace instead of the `gpu-dashboard` service in `gpu-demo`.

The `vllm-llama-deployment.yaml` manifest includes:
- vLLM OpenAI-compatible API server serving Llama 3.1 8B
- Persistent volume for model weight caching (50GB)
- Init container that waits for NVIDIA drivers to be ready
- Health/readiness probes with extended timeouts for model loading
- Shared memory volume (8GB) required by vLLM

**Llama Model Compatibility with VM.GPU.A10.1 (24GB VRAM):**

| Model | Fits in 24GB? | Notes |
|---|---|---|
| Llama 3.1 8B (fp16) | ✅ Yes | ~16GB VRAM, fast inference |
| Llama 3.1 8B (4-bit quantized) | ✅ Yes | ~6GB VRAM, even faster |
| Llama 2 13B (8-bit quantized) | ✅ Yes | ~14GB VRAM |
| Llama 3.1 70B | ❌ No | Needs ~140GB VRAM (8× A100) |

## Useful Commands

```bash
# Check nodes
kubectl get nodes

# Watch GPU app pods
kubectl get pods -n gpu-demo -w

# Watch Llama pods (once deployed)
kubectl get pods -n llm-inference -w

# Check autoscaler logs
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=50

# Check KEDA status
kubectl get httpscaledobject -n gpu-demo

# Get load balancer IP
kubectl get svc keda-add-ons-http-interceptor-proxy -n keda

# Test Llama API (once deployed)
curl http://<LLAMA_SERVICE_IP>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "meta-llama/Llama-3.1-8B-Instruct", "messages": [{"role": "user", "content": "Hello!"}]}'
```
