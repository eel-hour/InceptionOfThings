#!/bin/bash
set -e

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../confs/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: $CONFIG_FILE not found"
    exit 1
fi

if [ -z "$GITHUB_REPO" ]; then
    echo "ERROR: GITHUB_REPO not set in confs/config.env"
    exit 1
fi

CLUSTER_NAME="${CLUSTER_NAME:-mycluster}"
API_PORT="${API_PORT:-6443}"
APP_PORT="${APP_PORT:-8888}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
DEV_NAMESPACE="${DEV_NAMESPACE:-dev}"
ARGOCD_NODEPORT="${ARGOCD_NODEPORT:-30443}"
LOCAL_APP_PORT="${LOCAL_APP_PORT:-9999}"
LOCAL_ARGOCD_PORT="${LOCAL_ARGOCD_PORT:-8080}"

# Docker group handling
if [ -z "$DOCKER_GROUP_ACTIVATED" ]; then
    if ! groups | grep -q docker; then
        echo "Adding user to docker group..."
        sudo usermod -aG docker "$USER"
        echo "Re‑executing script with docker group..."
        exec sg docker -c "export DOCKER_GROUP_ACTIVATED=1; $0"
    else
        export DOCKER_GROUP_ACTIVATED=1
    fi
fi

run() {
    if [ "$EUID" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        "$@"
    fi
}

# Install Docker if missing
if ! command -v docker &> /dev/null; then
    echo "=== Installing Docker ==="
    run apt update
    run apt install -y ca-certificates curl
    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | run tee /etc/apt/sources.list.d/docker.list > /dev/null
    run apt update
    run apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
    echo "=== Docker already installed, skipping ==="
fi

# Install K3d
echo "=== Installing K3d ==="
if ! command -v k3d &> /dev/null; then
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

# Install kubectl if missing
if ! command -v kubectl &> /dev/null; then
    echo "=== Installing kubectl ==="
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    run install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
fi

# Clean up existing cluster
if k3d cluster list 2>/dev/null | grep -q "^$CLUSTER_NAME"; then
    echo "Deleting existing cluster '$CLUSTER_NAME'..."
    k3d cluster delete "$CLUSTER_NAME"
fi

echo "Creating k3d cluster '$CLUSTER_NAME'..."
k3d cluster create "$CLUSTER_NAME" --api-port "$API_PORT" -p "$APP_PORT:$APP_PORT@loadbalancer" --wait

export KUBECONFIG="$(k3d kubeconfig write "$CLUSTER_NAME")"
echo "export KUBECONFIG=$(k3d kubeconfig write "$CLUSTER_NAME")" >> ~/.bashrc

echo "K3d cluster ready:"
kubectl get nodes

# Install Argo CD using server‑side apply (no CRD annotation error)
echo "=== Installing Argo CD (server‑side) ==="
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side -n "$ARGOCD_NAMESPACE" -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for Argo CD core pods..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-application-controller -n "$ARGOCD_NAMESPACE" --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n "$ARGOCD_NAMESPACE" --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-repo-server -n "$ARGOCD_NAMESPACE" --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-dex-server -n "$ARGOCD_NAMESPACE" --timeout=300s

# Expose Argo CD server via NodePort (optional, for direct access but may not work on host)
kubectl patch svc argocd-server -n "$ARGOCD_NAMESPACE" -p '{"spec": {"type": "NodePort", "ports": [{"port": 443, "nodePort": '"$ARGOCD_NODEPORT"'}]}}'

ARGOCD_PASS=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "Argo CD admin password: $ARGOCD_PASS"

# Deploy application from GitHub
echo "=== Deploying application from $GITHUB_REPO ==="
kubectl create namespace "$DEV_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Install Argo CD CLI if missing (with retry)
if ! command -v argocd &> /dev/null; then
    echo "=== Installing Argo CD CLI ==="
    for i in {1..3}; do
        if curl --retry 3 --fail -L -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64; then
            sudo mv /tmp/argocd /usr/local/bin/argocd
            sudo chmod +x /usr/local/bin/argocd
            break
        else
            echo "Download failed (attempt $i). Retrying in 5 seconds..."
            sleep 5
        fi
    done
fi

# Start port-forward for Argo CD UI (keep it in background)
echo "=== Starting Argo CD UI port‑forward (http://localhost:$LOCAL_ARGOCD_PORT) ==="
kubectl port-forward -n "$ARGOCD_NAMESPACE" svc/argocd-server "$LOCAL_ARGOCD_PORT":443 > /tmp/argocd-pf.log 2>&1 &
ARGOCD_PF_PID=$!

sleep 5
# Login using the port‑forward
argocd login localhost:"$LOCAL_ARGOCD_PORT" --insecure --username admin --password "$ARGOCD_PASS"

# Create Argo CD application
argocd app create myapp \
  --repo "$GITHUB_REPO" \
  --path . \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace "$DEV_NAMESPACE" \
  --sync-policy automated \
  --auto-prune \
  --self-heal

echo "=== Syncing application ==="
argocd app sync myapp

# Wait for the app to be healthy
sleep 10
kubectl wait --for=condition=ready pod -l app=playground -n "$DEV_NAMESPACE" --timeout=120s

# Start port-forward for the application (keep it in background)
echo "=== Starting application port‑forward (http://localhost:$LOCAL_APP_PORT) ==="
kubectl port-forward -n "$DEV_NAMESPACE" svc/playground-svc "$LOCAL_APP_PORT":8888 > /tmp/app-pf.log 2>&1 &
APP_PF_PID=$!

VM_IP=$(hostname -I | awk '{print $1}')
echo "=========================================="
echo "Setup complete!"
echo "Argo CD UI: http://localhost:$LOCAL_ARGOCD_PORT (user: admin, password: $ARGOCD_PASS)"
echo "Application URL: http://localhost:$LOCAL_APP_PORT"
echo "=========================================="
echo "To test the initial version, run: curl http://localhost:$LOCAL_APP_PORT"
echo "To change version, edit deployment.yaml in your GitHub repo, commit & push, then after sync (or manual sync) run curl again."
echo "Port‑forward processes are running in background. To stop them later: kill $ARGOCD_PF_PID $APP_PF_PID"
