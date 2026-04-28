#!/bin/bash
set -e

echo "=== Setting up K3s server on Alpine (v1.27) ==="

apk add iptables ip6tables conntrack-tools curl bash

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.27.12+k3s1 sh -s - server \
  --bind-address ${SERVER_IP} \
  --advertise-address ${SERVER_IP} \
  --node-ip ${SERVER_IP} \
  --flannel-iface ${NETWORK_INTERFACE} \
  --write-kubeconfig-mode 644 \
  --tls-san ${SERVER_IP}
# NOTE: --disable=traefik is REMOVED to allow Ingress

echo "Waiting for K3s API to be ready (120 attempts)..."
for i in {1..120}; do
  if kubectl get nodes &>/dev/null; then
    echo "API ready after $i attempts"
    break
  fi
  sleep 2
done

sed -i "s/127.0.0.1/${SERVER_IP}/g" /etc/rancher/k3s/k3s.yaml

mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube
chmod 600 /home/vagrant/.kube/config

echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> /home/vagrant/.bashrc
echo "alias k='kubectl'" >> /home/vagrant/.bashrc

echo "K3s server setup complete"
