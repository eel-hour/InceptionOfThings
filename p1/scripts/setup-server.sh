#!/bin/bash
set -e

echo "=== Setting up K3s Server on Alpine ==="
echo "Server IP: ${SERVER_IP}"

# Install required packages
sudo apk add iptables ip6tables conntrack-tools curl bash

# Install K3s with embedded etcd (--cluster-init) - ALL flags in one line
curl -sfL https://get.k3s.io | sh -s - server \
  --bind-address ${SERVER_IP} \
  --advertise-address ${SERVER_IP} \
  --node-ip ${SERVER_IP} \
  --flannel-iface eth1 \
  --write-kubeconfig-mode 644 \
  --tls-san ${SERVER_IP} \
  --cluster-init

# Wait for K3s to be ready
echo "Waiting for K3s to be ready..."
for i in {1..90}; do
  if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    echo "K3s config file found!"
    break
  fi
  echo "Attempt $i/90: Waiting for k3s.yaml..."
  sleep 2
done

# Fix kubeconfig IP
sudo sed -i "s/127.0.0.1/${SERVER_IP}/g" /etc/rancher/k3s/k3s.yaml

# Setup kubectl for vagrant
mkdir -p /home/vagrant/.kube
sudo cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
sudo chown -R vagrant:vagrant /home/vagrant/.kube
sudo chmod 600 /home/vagrant/.kube/config

# Environment
echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" | sudo tee /etc/profile.d/k3s.sh
echo "alias k='kubectl'" | sudo tee -a /etc/profile.d/k3s.sh

# Save token
sudo cp /var/lib/rancher/k3s/server/node-token ${TOKEN_FILE}
sudo chmod 644 ${TOKEN_FILE}

echo "=== Server setup complete ==="
