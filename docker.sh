#!/bin/bash

set -e

echo "=== Updating system ==="
sudo apt update -y
sudo apt upgrade -y

echo "=== Removing old docker versions (if any) ==="
sudo apt remove -y docker docker-engine docker.io containerd runc || true

echo "=== Installing dependencies ==="
sudo apt install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

echo "=== Adding Docker GPG key ==="
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "=== Adding Docker repository ==="
echo \
  "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "=== Updating package list ==="
sudo apt update -y

echo "=== Installing Docker Engine ==="
sudo apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo "=== Enabling Docker service ==="
sudo systemctl enable docker
sudo systemctl start docker

echo "=== Adding current user to docker group ==="
sudo usermod -aG docker $USER

echo "=== Installation complete! ==="
echo "Reboot your system or run: newgrp docker"
echo "Now you can run: docker compose up -d"
