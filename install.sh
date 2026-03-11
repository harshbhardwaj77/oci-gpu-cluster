#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# OCI GPU Cluster — One-Shot Install Script
# ═══════════════════════════════════════════════════════════════
#
# Run this AFTER you have:
#   1. Created the OKE cluster via OCI Console
#   2. Created a CPU node pool (1 node, VM.Standard.E4.Flex)
#   3. Created a GPU node pool (0 nodes, VM.GPU.A10.1)
#   4. Configured kubectl (kubeconfig)
#
# Usage:
#   chmod +x install.sh
#   ./install.sh
#
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$SCRIPT_DIR/k8s"
APP_DIR="$SCRIPT_DIR/gpu-app"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

print_header() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() { echo -e "  ${GREEN}✓${NC} $1"; }
print_info() { echo -e "  ${BLUE}ℹ${NC} $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
print_err()  { echo -e "  ${RED}✗${NC} $1"; }

# ─── Preflight Checks ────────────────────────────────────

print_header "Preflight Checks"

# Check kubectl
if ! command -v kubectl &>/dev/null; then
    print_err "kubectl not found. Install: https://kubernetes.io/docs/tasks/tools/"
    exit 1
fi
print_step "kubectl found"

# Check helm
if ! command -v helm &>/dev/null; then
    print_err "helm not found. Install: https://helm.sh/docs/intro/install/"
    exit 1
fi
print_step "helm found"

# Test cluster connection
if ! kubectl cluster-info &>/dev/null; then
    print_err "Cannot connect to Kubernetes cluster. Configure kubeconfig first:"
    echo "    oci ce cluster create-kubeconfig --cluster-id <CLUSTER_OCID> --file \$HOME/.kube/config --region <REGION> --token-version 2.0.0"
    exit 1
fi
print_step "Connected to cluster"

# Check nodes
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if [ "$NODE_COUNT" -eq 0 ]; then
    print_err "No nodes found. Ensure your CPU node pool has at least 1 node."
    exit 1
fi
print_step "Found $NODE_COUNT node(s)"
kubectl get nodes -o wide

# ─── Collect Configuration ────────────────────────────────

print_header "Configuration"

# GPU node pool OCID
echo -e "  ${BOLD}Enter your GPU node pool OCID${NC}"
echo -e "  (OCI Console → Cluster → Node Pools → gpu pool → Copy OCID)"
read -rp "  GPU Pool OCID: " GPU_POOL_OCID

# CPU node pool OCID
echo ""
echo -e "  ${BOLD}Enter your CPU node pool OCID${NC}"
read -rp "  CPU Pool OCID: " CPU_POOL_OCID

# Domain (optional)
echo ""
echo -e "  ${BOLD}Enter domain for GPU app (or press Enter to skip)${NC}"
echo -e "  Example: gpu-app.example.com"
read -rp "  Domain: " GPU_DOMAIN
GPU_DOMAIN=${GPU_DOMAIN:-"gpu-app.local"}

# Docker registry (for the GPU app image)
echo ""
echo -e "  ${BOLD}Enter your container registry prefix${NC}"
echo -e "  Example: iad.ocir.io/mytenancy/gpu-cluster"
echo -e "  The GPU dashboard image will be pushed as: <prefix>/gpu-dashboard:latest"
read -rp "  Registry: " REGISTRY_PREFIX
REGISTRY_PREFIX=${REGISTRY_PREFIX:-"local"}

GPU_APP_IMAGE="${REGISTRY_PREFIX}/gpu-dashboard:latest"

echo ""
print_info "GPU Pool OCID: $GPU_POOL_OCID"
print_info "CPU Pool OCID: $CPU_POOL_OCID"
print_info "Domain:        $GPU_DOMAIN"
print_info "App Image:     $GPU_APP_IMAGE"
echo ""
read -rp "  Proceed? (y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

# ─── Step 1: NVIDIA GPU Operator ─────────────────────────

print_header "Step 1/5 — NVIDIA GPU Operator"

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update nvidia

if helm status gpu-operator -n gpu-operator &>/dev/null; then
    print_info "GPU Operator already installed, upgrading..."
    helm upgrade gpu-operator nvidia/gpu-operator \
        --namespace gpu-operator \
        --set driver.enabled=true \
        --set toolkit.enabled=true \
        --set devicePlugin.enabled=true \
        --set dcgmExporter.enabled=true \
        --set migManager.enabled=false \
        --wait --timeout 5m
else
    helm install gpu-operator nvidia/gpu-operator \
        --namespace gpu-operator --create-namespace \
        --set driver.enabled=true \
        --set toolkit.enabled=true \
        --set devicePlugin.enabled=true \
        --set dcgmExporter.enabled=true \
        --set migManager.enabled=false \
        --wait --timeout 5m
fi
print_step "GPU Operator installed"

# ─── Step 2: Cluster Autoscaler ──────────────────────────

print_header "Step 2/5 — Cluster Autoscaler"

# Substitute OCIDs into the manifest and apply
sed \
    -e "s|<GPU_NODE_POOL_OCID>|$GPU_POOL_OCID|g" \
    -e "s|<CPU_NODE_POOL_OCID>|$CPU_POOL_OCID|g" \
    "$K8S_DIR/cluster-autoscaler.yaml" | kubectl apply -f -

print_step "Cluster Autoscaler deployed"
print_info "GPU pool will scale 0 → 3 nodes on demand"

# Wait for autoscaler pod
kubectl rollout status deployment/cluster-autoscaler -n kube-system --timeout=120s 2>/dev/null || true
print_step "Cluster Autoscaler pod is running"

# ─── Step 3: KEDA + HTTP Add-on ─────────────────────────

print_header "Step 3/5 — KEDA (Event-Driven Autoscaling)"

helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo update kedacore

# Install KEDA
if helm status keda -n keda &>/dev/null; then
    print_info "KEDA already installed, upgrading..."
    helm upgrade keda kedacore/keda --namespace keda --wait --timeout 3m
else
    helm install keda kedacore/keda \
        --namespace keda --create-namespace \
        --wait --timeout 3m
fi
print_step "KEDA installed"

# Install KEDA HTTP Add-on
if helm status keda-http-addon -n keda &>/dev/null; then
    print_info "KEDA HTTP Add-on already installed, upgrading..."
    helm upgrade keda-http-addon kedacore/keda-add-ons-http --namespace keda --wait --timeout 3m
else
    helm install keda-http-addon kedacore/keda-add-ons-http \
        --namespace keda \
        --wait --timeout 3m
fi
print_step "KEDA HTTP Add-on installed"

# ─── Step 4: Build & Push GPU Dashboard App ─────────────

print_header "Step 4/5 — GPU Dashboard App"

if [[ "$REGISTRY_PREFIX" == "local" ]]; then
    print_warn "No registry specified — skipping Docker build."
    print_warn "You need to build and push the image manually:"
    echo ""
    echo "    cd $APP_DIR"
    echo "    docker build -t $GPU_APP_IMAGE ."
    echo "    docker push $GPU_APP_IMAGE"
    echo ""
    print_info "After pushing, re-run install.sh or apply the manifest manually."
else
    if command -v docker &>/dev/null; then
        print_info "Building GPU Dashboard image..."
        docker build -t "$GPU_APP_IMAGE" "$APP_DIR"
        print_step "Image built: $GPU_APP_IMAGE"

        print_info "Pushing to registry..."
        docker push "$GPU_APP_IMAGE"
        print_step "Image pushed: $GPU_APP_IMAGE"
    else
        print_warn "Docker not found. Build and push the image manually:"
        echo "    cd $APP_DIR && docker build -t $GPU_APP_IMAGE . && docker push $GPU_APP_IMAGE"
    fi
fi

# ─── Step 5: Deploy GPU Dashboard ───────────────────────

print_header "Step 5/5 — Deploy GPU Dashboard"

# Substitute placeholders and apply
sed \
    -e "s|GPU_APP_IMAGE_PLACEHOLDER|$GPU_APP_IMAGE|g" \
    -e "s|GPU_DOMAIN_PLACEHOLDER|$GPU_DOMAIN|g" \
    "$K8S_DIR/gpu-dashboard.yaml" | kubectl apply -f -

print_step "GPU Dashboard deployed (0 replicas — KEDA will manage)"

# Also deploy the simple nvidia-smi test job
kubectl apply -f "$K8S_DIR/gpu-test.yaml" 2>/dev/null || true
print_step "GPU test job created (will trigger first GPU node)"

# ─── Summary ─────────────────────────────────────────────

print_header "Installation Complete! 🎉"

echo -e "  ${BOLD}What was installed:${NC}"
echo -e "  ├── NVIDIA GPU Operator    (auto-installs GPU drivers on new nodes)"
echo -e "  ├── Cluster Autoscaler     (scales GPU pool 0 → 3)"
echo -e "  ├── KEDA + HTTP Add-on     (scales pods on HTTP requests)"
echo -e "  └── GPU Dashboard App      (web UI showing GPU status)"
echo ""

echo -e "  ${BOLD}How it works:${NC}"
echo -e "  1. Request hits ${CYAN}$GPU_DOMAIN${NC} → KEDA Interceptor (on CPU node)"
echo -e "  2. KEDA scales gpu-dashboard 0 → 1"
echo -e "  3. Cluster Autoscaler provisions GPU node (~5-8 min)"
echo -e "  4. GPU Operator installs drivers"
echo -e "  5. Dashboard pod starts → serves response"
echo -e "  6. After 5 min idle → scales back to 0"
echo ""

echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "  ${CYAN}kubectl get nodes${NC}                                  # Check nodes"
echo -e "  ${CYAN}kubectl get pods -n gpu-demo -w${NC}                    # Watch GPU app"
echo -e "  ${CYAN}kubectl get pods -n kube-system -l app=cluster-autoscaler${NC}"
echo -e "  ${CYAN}kubectl logs -n kube-system -l app=cluster-autoscaler --tail=50${NC}"
echo -e "  ${CYAN}kubectl get httpscaledobject -n gpu-demo${NC}           # KEDA status"
echo ""

# Get KEDA interceptor IP
INTERCEPTOR_IP=$(kubectl get svc -n keda keda-add-ons-http-interceptor-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

if [[ "$INTERCEPTOR_IP" != "pending" && -n "$INTERCEPTOR_IP" ]]; then
    echo -e "  ${BOLD}DNS Setup:${NC}"
    echo -e "  Point ${CYAN}$GPU_DOMAIN${NC} → ${GREEN}$INTERCEPTOR_IP${NC}"
    echo ""
    echo -e "  ${BOLD}Test it:${NC}"
    echo -e "  ${CYAN}curl http://$INTERCEPTOR_IP/ -H 'Host: $GPU_DOMAIN'${NC}"
else
    echo -e "  ${BOLD}DNS Setup:${NC}"
    echo -e "  Run this to get the KEDA interceptor IP:"
    echo -e "  ${CYAN}kubectl get svc -n keda keda-add-ons-http-interceptor-proxy${NC}"
    echo -e "  Then point ${CYAN}$GPU_DOMAIN${NC} → that EXTERNAL-IP"
fi
echo ""
