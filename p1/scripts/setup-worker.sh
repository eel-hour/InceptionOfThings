#!/bin/bash
set -e

echo "=== Setting up K3s Worker on Alpine ==="
echo "Server IP: ${SERVER_IP}"

# Install required packages
sudo apk add iptables ip6tables conntrack-tools curl bash

# Wait for token file
for i in {1..30}; do
  if [ -f ${TOKEN_FILE} ]; then
    echo "Token found!"
    break
  fi
  echo "Attempt $i/30: Waiting for token..."
  sleep 2
done

if [ ! -f ${TOKEN_FILE} ]; then
  echo "ERROR: Node token not found"
  exit 1
fi

K3S_TOKEN=$(cat ${TOKEN_FILE})

# Install K3s agent - REMOVED --node-ip and fixed flags
curl -sfL https://get.k3s.io | sh -s - agent \
  --server https://${SERVER_IP}:6443 \
  --token ${K3S_TOKEN} \
  --flannel-iface eth1

rm -f ${TOKEN_FILE}

echo "=== Worker setup complete ==="
