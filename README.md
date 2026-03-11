# OCI GPU Kubernetes Cluster — Scale-to-Zero

GPU-accelerated Kubernetes on **Oracle Cloud (OKE)** with GPU nodes that **auto-scale from zero**. Includes a GPU dashboard web app and request-driven scaling via KEDA.

## Architecture

```
                     gpu-app.example.com
                            │
                            ▼
                ┌───────────────────────┐
                │  KEDA HTTP Interceptor │  ← Always on (CPU node)
                │  (buffers requests)    │
                └──────────┬────────────┘
                           │
              Request arrives → KEDA scales 0→1
              Cluster Autoscaler → provisions GPU node
                           │
                           ▼
                ┌───────────────────────┐
                │  GPU Dashboard Pod     │  ← Only runs when needed
                │  NVIDIA A10 (24GB)     │
                │  Shows GPU stats UI    │
                └───────────────────────┘
                           │
              5 min idle → scales to 0
              GPU node deprovisioned
```

## Prerequisites

1. **OCI Account** with GPU quota (`VM.GPU.A10.1`)
2. **OKE Cluster** created via OCI Console (see [WALKTHROUGH.md](WALKTHROUGH.md))
3. **CPU node pool** (1 node, `VM.Standard.E4.Flex`, 1 OCPU, 8 GB)
4. **GPU node pool** (0 nodes, `VM.GPU.A10.1`)
5. `kubectl` and `helm` installed locally (e.g., in OCI Cloud Shell)
## Quick Start

```bash
# 1. Create cluster + node pools via OCI Console (see WALKTHROUGH.md)

# 2. Configure kubectl
oci ce cluster create-kubeconfig \
  --cluster-id <CLUSTER_OCID> \
  --file $HOME/.kube/config \
  --region <REGION> \
  --token-version 2.0.0

# 3. Run the install script (installs everything)
chmod +x install.sh
./install.sh
```

The install script will:
- ✅ Install NVIDIA GPU Operator
- ✅ Deploy Cluster Autoscaler (GPU pool 0→3)
- ✅ Install KEDA + HTTP Add-on
- ✅ Deploy GPU Dashboard app via ConfigMaps (Zero Docker Build)
- ✅ Print DNS setup instructions

## Project Structure

```
oci-gpu-cluster/
├── install.sh                     # One-shot setup (run after cluster creation)
├── WALKTHROUGH.md                 # Step-by-step OCI Console guide
├── gpu-app/                       # GPU Dashboard web app
│   ├── Dockerfile
│   ├── app.py                     # Flask backend (nvidia-smi API)
│   ├── templates/index.html       # Dashboard UI
│   └── static/
│       ├── style.css              # Dark-mode styling
│       └── app.js                 # Live polling frontend
├── k8s/
│   ├── cluster-autoscaler.yaml    # Autoscaler (GPU pool 0→3)
│   ├── gpu-dashboard.yaml         # App deployment + KEDA scaler
│   ├── gpu-test.yaml              # Simple nvidia-smi test job
│   ├── vllm-llama-deployment.yaml # Llama deployment (for later)
│   └── hpa.yaml                   # Optional GPU-utilization HPA
├── terraform/                     # Alternative IaC setup (optional)
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
└── .gitignore
```

## GPU Dashboard

The test app is a web dashboard that shows:
- 🎮 GPU name, driver version, VRAM usage bar
- 📊 GPU utilization %, temperature, power draw
- 🖥️ System CPU/RAM stats
- ☸️ Kubernetes pod/node/namespace info

Auto-refreshes every 5 seconds. Dark mode with NVIDIA green accents.

## Cost

| Component | Always Running? | Cost |
|---|---|---|
| CPU node (1× 1-OCPU Flex) | ✅ 24/7 | ~$25/mo |
| GPU node (VM.GPU.A10.1) | ❌ On demand | ~$1.60/hr |
| OKE Control Plane | ✅ Managed | Free |

With scale-to-zero, GPU costs are only incurred during active usage.
