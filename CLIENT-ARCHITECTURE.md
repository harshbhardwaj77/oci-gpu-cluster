# GPU Infrastructure — Architecture & Cost Overview

*Prepared for client review — Scale-to-Zero GPU Kubernetes on Oracle Cloud*

---

## 1. The Problem

Running GPU servers 24/7 is extremely expensive. A single NVIDIA A10 GPU instance costs **~$1,440/month** if left running continuously. For AI workloads that only need GPUs when users are actively making requests, this is a massive waste.

**Our solution:** A Kubernetes cluster that keeps GPU servers turned off when nobody is using them, and automatically boots them on-demand when a request arrives.

---

## 2. Infrastructure Overview

The cluster runs on **Oracle Cloud Infrastructure (OKE)** and consists of two separate node pools:

```
┌─────────────────────────────────────────────────────────────────┐
│                    OKE Kubernetes Cluster                       │
│                                                                 │
│   ┌─────────────────────────┐   ┌─────────────────────────┐    │
│   │   🖥️ CPU Node Pool       │   │   🎮 GPU Node Pool       │    │
│   │   (Always Running)      │   │   (Scale-to-Zero)       │    │
│   │                         │   │                         │    │
│   │   Shape: E4.Flex        │   │   Shape: VM.GPU.A10.1   │    │
│   │   1 OCPU, 8 GB RAM     │   │   1× NVIDIA A10 (24GB)  │    │
│   │   Nodes: 1 (fixed)     │   │   Nodes: 0-2 (dynamic)  │    │
│   │                         │   │                         │    │
│   │   Runs:                 │   │   Runs:                 │    │
│   │   • KEDA Interceptor    │   │   • AI Model (Llama)    │    │
│   │   • Cluster Autoscaler  │   │   • GPU Dashboard       │    │
│   │   • GPU Operator Agent  │   │                         │    │
│   │   💰 ~$27/month         │   │   ⚡ Only runs when      │    │
│   │                         │   │   requests arrive       │    │
│   └─────────────────────────┘   └─────────────────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### What lives on each node?

**CPU Node (always on, very cheap):**
This tiny server acts as the "receptionist" for the cluster. It receives all incoming web requests, decides if a GPU is needed, and manages the scaling process. It runs three lightweight services:

| Service | Role |
|---|---|
| **KEDA HTTP Interceptor** | Catches incoming HTTP requests and holds them while the GPU boots up |
| **Cluster Autoscaler** | Watches for pending workloads and tells Oracle to create/destroy GPU servers |
| **NVIDIA GPU Operator** | Automatically installs GPU drivers on any new GPU server that joins |

**GPU Node (on-demand, turns off when idle):**
This powerful server contains the NVIDIA A10 GPU with 24 GB of video memory. It only exists when there are active requests. When nobody is using the AI for 5 minutes, the server is automatically shut down and removed.

---

## 3. How a Request Flows Through the System

Here is exactly what happens when a user sends a request to the AI endpoint:

```
                        ① User sends request
                        gpu.yourdomain.com
                               │
                               ▼
                    ┌─────────────────────┐
                    │    Load Balancer    │  OCI Network Load Balancer
                    │    (Public IP)      │  Routes traffic into cluster
                    └─────────┬───────────┘
                              │
                              ▼
               ┌──────────────────────────┐
           ②   │   KEDA HTTP Interceptor  │  Receives request
               │   (CPU Node)             │  Checks: is a GPU pod running?
               └─────────┬────────────────┘
                         │
              ┌──────────┴──────────┐
              │                     │
         Pod exists?           Pod exists?
           YES ✅                NO ❌
              │                     │
              │              ③ KEDA holds the request
              │                 Tells Kubernetes:
              │                 "Scale pods 0 → 1"
              │                     │
              │              ④ Cluster Autoscaler sees
              │                 a pending pod needs a GPU
              │                 Tells OCI: "Create a
              │                 VM.GPU.A10.1 server"
              │                     │
              │              ⑤ OCI provisions new server
              │                 (~3-5 minutes)
              │                     │
              │              ⑥ GPU Operator auto-installs
              │                 NVIDIA drivers on new server
              │                     │
              │              ⑦ AI pod starts on GPU server
              │                 Model loads into GPU memory
              │                     │
              ▼                     ▼
         ┌──────────────────────────────┐
     ⑧   │      GPU Pod (Running)       │
         │      Processes the request   │
         │      Returns the response    │
         └──────────────────────────────┘
                         │
                         ▼
                  ⑨ Response sent to user


         After 5 minutes of no requests:
         ┌─────────────────────────────────────────┐
     ⑩   │  KEDA scales pod 0                      │
         │  Autoscaler removes GPU server           │
         │  GPU cost drops to $0                    │
         └─────────────────────────────────────────┘
```

### Timing

| Scenario | Response Time |
|---|---|
| **Cold start** (GPU node is off) | ~5-10 minutes (one-time wait for first user) |
| **Warm** (GPU node already running) | Instant (milliseconds) |
| **Scale down** (no activity) | 5 minutes idle → GPU shuts off |

> **Note:** The cold start wait only happens for the very first request after a period of inactivity. Once the GPU is running, all subsequent requests are served instantly until 5 minutes of inactivity passes.

---

## 4. Key Technologies

| Technology | What It Does | Why We Use It |
|---|---|---|
| **OKE** (Oracle Kubernetes Engine) | Managed Kubernetes cluster | Oracle manages the control plane for free |
| **KEDA** (Kubernetes Event-Driven Autoscaler) | Scales pods from 0 to N based on HTTP traffic | The only scaler that can **hold HTTP requests** while pods boot — prevents 502 errors |
| **Cluster Autoscaler** | Scales actual GPU servers from 0 to N | Provisions/removes real GPU hardware based on pod demand |
| **NVIDIA GPU Operator** | Installs GPU drivers automatically | When a fresh GPU server boots, drivers are installed without manual intervention |
| **vLLM** | High-performance LLM inference engine | Serves Llama models via an OpenAI-compatible API with optimized GPU utilization |

### Why KEDA instead of a standard load balancer?

A standard NGINX Ingress or load balancer would immediately return a **502 Bad Gateway** error if the GPU pod doesn't exist when a request arrives. KEDA's HTTP Add-on is special because it:

1.  **Buffers the request** — holds the HTTP connection open
2.  **Triggers the scale-up** — tells Kubernetes to create a GPU pod
3.  **Waits patiently** — keeps the user's connection alive while the GPU boots
4.  **Forwards the request** — once the pod is ready, delivers the original request seamlessly

The user simply sees a loading spinner for a few minutes, then gets their response — no errors, no retries needed.

---

## 5. Monthly Cost Estimate

### Always-On Costs (Fixed)

| Component | Always Running? | Cost |
|---|---|---|
| CPU node (1× 1-OCPU E4.Flex) | ✅ 24/7 | ~$27/mo |
| GPU node (VM.GPU.A10.1) | ❌ On demand | ~$2.00/hr |
| OKE Cluster (Basic tier) | ✅ 24/7 | **Free** |
| OCI Load Balancer | ✅ 24/7 | **Free** |
| **Subtotal (fixed)** | | **~$27/month** |

> **CPU Node cost breakdown:** OCPU: $0.025/hr × 1 × 720 hrs = $18 + Memory: $0.0015/hr × 8 GB × 720 hrs = $8.64 = **$26.64/month**

### On-Demand Costs (Variable — GPU)

| Component | Spec | Hourly Cost | Usage Example |
|---|---|---|---|
| GPU Node | VM.GPU.A10.1 (1× A10, 24GB) | ~$2.00/hr | Scales to zero when idle |

> **Source:** [Oracle Cloud Compute Pricing](https://www.oracle.com/cloud/compute/pricing/)

### Usage Scenarios

| Scenario | GPU Hours/Month | GPU Cost | Total Monthly |
|---|---|---|---|
| **Light** (2 hrs/day) | ~60 hrs | ~$120 | **~$147/month** |
| **Moderate** (8 hrs/day, weekdays) | ~176 hrs | ~$352 | **~$379/month** |
| **Heavy** (12 hrs/day, every day) | ~360 hrs | ~$720 | **~$747/month** |
| **Always On** (24/7, no scaling) | 720 hrs | ~$1,440 | **~$1,467/month** |

---

## 6. 💰 Savings — Why Scale-to-Zero Changes Everything

This is the core value proposition of our architecture. Instead of paying for a GPU server that sits idle 80-95% of the time, **you only pay for the minutes the GPU is actually processing requests.**

### The Traditional Approach vs Our Approach

```
  ┌─────────────────────────────────────────────────────────────────┐
  │                                                                 │
  │   ❌ TRADITIONAL: GPU server running 24/7                       │
  │   ═══════════════════════════════════════════                    │
  │   $1,440/month GPU + $27 CPU = $1,467/month                    │
  │   GPU is IDLE 80-95% of the time                                │
  │   You pay the same whether 0 or 1000 users are online           │
  │                                                                 │
  │   ✅ OUR SOLUTION: GPU scales to zero automatically             │
  │   ═══════════════════════════════════════════                    │
  │   $27/month fixed + GPU only when needed                        │
  │   GPU cost = $0 during nights, weekends, idle periods           │
  │   You pay ONLY for actual AI processing time                    │
  │                                                                 │
  └─────────────────────────────────────────────────────────────────┘
```

### Monthly Cost Comparison

```
  Monthly Cost ($)
  │
  $1,467 ┤ ████████████████████████████████████████  ← Always-On (no scaling)
         │
    $747 ┤ ████████████████████░░░░░░░░░░░░░░░░░░░░  ← Heavy Use (12hr/day)
         │                                              YOU SAVE $720/mo (49%)
    $379 ┤ ██████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  ← Moderate (8hr weekdays)
         │                                              YOU SAVE $1,088/mo (74%)
    $147 ┤ ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  ← Light Use (2hr/day)
         │                                              YOU SAVE $1,320/mo (90%)
     $27 ┤ █░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  ← Idle (no users at all)
         │                                              YOU SAVE $1,440/mo (98%)
         └──────────────────────────────────────────
```

### Annual Savings Projection

| Scenario | Monthly Cost | Annual Cost | Annual Savings vs Always-On | % Saved |
|---|---|---|---|---|
| **Always-On** (no scaling) | $1,467 | **$17,604** | — | — |
| **Heavy** (12hr/day, every day) | $747 | **$8,964** | **$8,640** saved | 49% |
| **Moderate** (8hr/day, weekdays) | $379 | **$4,548** | **$13,056** saved | 74% |
| **Light** (2hr/day) | $147 | **$1,764** | **$15,840** saved | 90% |
| **Weekends off** (8hr, Mon-Fri only) | $347 | **$4,164** | **$13,440** saved | 76% |

### Real-World Usage Examples

**Example 1: Internal Business Tool**
> Your team of 15 people uses the AI chatbot during business hours (9 AM – 5 PM, Sunday–Thursday).
> The GPU runs ~8 hours/day, 22 days/month = **176 GPU hours**.
>
> - Traditional (always-on): **$17,604/year**
> - With scale-to-zero: **$4,548/year**
> - **You save: $13,056/year** ✅

**Example 2: Customer-Facing API with Occasional Traffic**
> Your app receives AI requests sporadically — maybe 2-3 hours of real GPU usage per day on average.
>
> - Traditional (always-on): **$17,604/year**
> - With scale-to-zero: **$1,764/year**
> - **You save: $15,840/year** ✅

**Example 3: Development & Testing**
> Your developers test the AI model a few times per week, totaling ~10 hours/month of GPU usage.
>
> - Traditional (always-on): **$17,604/year**
> - With scale-to-zero: **$564/year** ($27 fixed + $20 GPU)
> - **You save: $17,040/year** ✅

### What Happens During Off-Hours?

```
  ┌──────────────────────────────────────────────────────────┐
  │  24-Hour Cost Timeline (Business Hours Usage)            │
  │                                                          │
  │  12AM ░░░░░░░░ 6AM ░░ 8AM ████████████ 5PM ░░░░░░ 12AM │
  │       sleeping        │  GPU running  │  GPU off         │
  │       GPU cost: $0    │  GPU: $2/hr   │  GPU cost: $0    │
  │                       │  = $18 today  │                  │
  │                       │               │                  │
  │  Without scaling: $48/day ($2 × 24hr)                    │
  │  With scaling:    $18/day ($2 × 9hr)                     │
  │  Daily savings:   $30/day                                │
  └──────────────────────────────────────────────────────────┘
```

### The Bottom Line

> **If the GPU is not being used 24/7, our scale-to-zero architecture saves between $8,640 and $17,040 per year** — depending on actual usage patterns. The infrastructure cost to enable this (the $27/month CPU node running KEDA) pays for itself within the **first 14 hours** of GPU time saved.

---

## 6. GPU Hardware: NVIDIA A10

| Spec | Value |
|---|---|
| GPU | NVIDIA A10 Tensor Core |
| VRAM | 24 GB GDDR6 |
| Architecture | Ampere |
| Best for | AI inference, Llama 3 8B, image generation |
| OCI Shape | `VM.GPU.A10.1` |

### AI Model Compatibility

| Model | VRAM Required | Fits on A10? |
|---|---|---|
| Llama 3.1 8B (16-bit) | ~16 GB | ✅ Yes |
| Llama 3.1 8B (4-bit quantized) | ~6 GB | ✅ Yes — fastest option |
| Llama 2 13B (8-bit quantized) | ~14 GB | ✅ Yes |
| Llama 3.1 70B | ~140 GB | ❌ No — needs 8× A100 |

---

## 7. Security

| Aspect | Implementation |
|---|---|
| Worker Nodes | Private subnet (no public IP) |
| API Endpoint | Public (for management via kubectl) |
| Cluster Type | OKE Basic (Oracle-managed control plane) |
| Secrets | Oracle-managed encryption |
| GPU Drivers | Auto-installed via GPU Operator (no SSH needed) |
| Dashboard | Disabled (kubectl only — reduces attack surface) |

---

## 8. Summary

| Feature | Status |
|---|---|
| GPU scales to zero when idle | ✅ |
| Automatic GPU provisioning on request | ✅ |
| No 502 errors during cold start | ✅ (KEDA holds requests) |
| Automatic GPU driver installation | ✅ (GPU Operator) |
| Ready for Llama 3 8B inference | ✅ |
| Monthly cost (light usage) | ~$147 |
| Monthly savings vs always-on | Up to 90% |
