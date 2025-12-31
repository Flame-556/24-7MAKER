#!/bin/bash

# Post-install: XRDP + Chrome for Ubuntu Desktop VM

echo "Installing XRDP (Remote Desktop)..."

# Install XRDP
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y xrdp
systemctl enable xrdp
adduser xrdp ssl-cert 2>/dev/null || true

echo "Installing Chrome..."

# Install Chrome
wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
dpkg -i google-chrome-stable_current_amd64.deb 2>/dev/null || true
apt-get install -f -y -qq

echo ""
echo "=========================================="
echo "     RDP IS READY!"
echo "=========================================="
echo ""
echo "1. Open Remote Desktop (mstsc.exe) on Windows"
echo ""
echo "2. Connect to: YOUR_VPS_IP:3389"
echo ""
echo "3. Login with your Ubuntu username/password"
echo ""
echo "=========================================="
