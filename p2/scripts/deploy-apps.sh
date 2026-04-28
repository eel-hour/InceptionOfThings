#!/bin/bash
set -e

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== Waiting for K3s API (120 attempts) ==="
for i in {1..120}; do
  if kubectl get nodes &>/dev/null; then
    echo "API ready after $i attempts"
    break
  fi
  sleep 2
done

echo "=== Deploying three applications ==="
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app1
  template:
    metadata:
      labels:
        app: app1
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: app1
spec:
  selector:
    app: app1
  ports:
    - port: 80
      targetPort: 80
EOF

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app2
spec:
  replicas: 3
  selector:
    matchLabels:
      app: app2
  template:
    metadata:
      labels:
        app: app2
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: app2
spec:
  selector:
    app: app2
  ports:
    - port: 80
      targetPort: 80
EOF

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app3
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app3
  template:
    metadata:
      labels:
        app: app3
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: app3
spec:
  selector:
    app: app3
  ports:
    - port: 80
      targetPort: 80
EOF

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: main-ingress
spec:
  rules:
  - host: app1.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app1
            port:
              number: 80
  - host: app2.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app2
            port:
              number: 80
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app3
            port:
              number: 80
EOF

echo "=== Waiting for Traefik Ingress Controller (60 attempts) ==="
for i in {1..60}; do
  if kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | grep -q True; then
    echo "Traefik ready after $i attempts"
    break
  fi
  sleep 2
done

echo "=== All pods ==="
kubectl get pods
echo "=== Ingress ==="
kubectl get ingress
