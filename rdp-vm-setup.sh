#!/bin/bash

# Ubuntu Desktop VM with RDP (Remote Desktop)
# Run as ROOT on your Ubuntu VPS

echo "=========================================="
echo "  UBUNTU VM WITH RDP - AUTO SETUP"
echo "=========================================="
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root!"
    exit 1
fi

# Configuration
VM_NAME="UbuntuRDP"
VM_MEMORY="4096"
VM_CORES="2"
VM_DISK_SIZE="40"
DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
ISO_PATH="/var/lib/libvirt/images/ubuntu-desktop.iso"

echo "[1/5] Installing virtualization tools..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq qemu-kvm libvirt-daemon-system virt-manager bridge-utils 2>/dev/null
systemctl enable libvirtd 2>/dev/null
systemctl start libvirtd 2>/dev/null
sleep 2
echo "OK"

echo "[2/5] Downloading Ubuntu Desktop ISO..."
mkdir -p /var/lib/libvirt/images
rm -f "$ISO_PATH"

# Try multiple mirrors
MIRRORS=(
    "https://cdimage.ubuntu.com/releases/22.04.4/release/ubuntu-22.04.4-desktop-amd64.iso"
    "https://releases.ubuntu.com/22.04.4/ubuntu-22.04.4-desktop-amd64.iso"
)

for URL in "${MIRRORS[@]}"; do
    echo "  Trying: $URL"
    if wget -q --show-progress -O "$ISO_PATH" "$URL" 2>&1; then
        if [ -s "$ISO_PATH" ] && [ $(stat -c%s "$ISO_PATH" 2>/dev/null || echo 0) -gt 3000000000 ]; then
            echo "  Downloaded!"
            break
        fi
    fi
    rm -f "$ISO_PATH"
done

if [ ! -f "$ISO_PATH" ] || [ ! -s "$ISO_PATH" ]; then
    echo "ERROR: Failed to download ISO!"
    exit 1
fi
echo "OK - $(ls -lh "$ISO_PATH" | awk '{print $5}')"

echo "[3/5] Creating VM..."
virsh destroy "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" 2>/dev/null || true

if [ ! -f "$DISK_PATH" ]; then
    qemu-img create -f qcow2 "$DISK_PATH" "${VM_DISK_SIZE}G" > /dev/null 2>&1
fi

virt-install \
    --name "$VM_NAME" \
    --memory "$VM_MEMORY" \
    --vcpus "$VM_CORES" \
    --disk path="$DISK_PATH",size="$VM_DISK_SIZE" \
    --cdrom "$ISO_PATH" \
    --network bridge=virbr0 \
    --graphics vnc,listen=0.0.0.0 \
    --os-variant ubuntu22.04 \
    --noautoconsole 2>&1 | head -3

sleep 3

if virsh list | grep -q "$VM_NAME"; then
    echo "OK - VM is running"
else
    echo "ERROR: VM failed to start!"
    exit 1
fi

echo "[4/5] Setting up RDP port forward..."

# Get VM's IP
VM_IP=""
for i in {1..30}; do
    VM_IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | grep -oP '\d+(\.\d+){3}' | head -1)
    [ -n "$VM_IP" ] && break
    sleep 2
done

if [ -z "$VM_IP" ]; then
    echo "  VM IP not found yet, will auto-connect later"
    VM_IP="(get from virsh domifaddr $VM_NAME)"
fi

# Setup iptables for RDP port forward (3389 -> VM:3389)
# This allows direct RDP connection from outside
iptables -t nat -C PREROUTING -p tcp --dport 3389 -j DNAT --to-destination 192.168.122.2:3389 2>/dev/null || \
iptables -t nat -A PREROUTING -p tcp --dport 3389 -j DNAT --to-destination 192.168.122.2:3389 2>/dev/null

iptables -C FORWARD -d 192.168.122.0/24 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -d 192.168.122.0/24 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

iptables -C FORWARD -s 192.168.122.0/24 -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -s 192.168.122.0/24 -j ACCEPT 2>/dev/null

echo "OK"

echo "[5/5] Setup complete!"
echo ""

# Get VPS IP
VPS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo "=========================================="
echo "     RDP ACCESS READY!"
echo "=========================================="
echo ""
echo "1. Open Remote Desktop (mstsc.exe) on your PC"
echo ""
echo "2. Connect to:"
echo "   $VPS_IP:3389"
echo ""
echo "3. Login with Ubuntu credentials"
echo "   (create during Ubuntu installation)"
echo ""
echo "=========================================="
echo ""
echo "IMPORTANT: After Ubuntu installs,"
echo "open Terminal and install XRDP:"
echo ""
echo "  sudo apt update"
echo "  sudo apt install -y xrdp"
echo "  sudo systemctl enable xrdp"
echo "  sudo adduser xrdp ssl-cert"
echo ""
echo "=========================================="

# Save info
cat > /root/RDP_VM_Info.txt <<EOF
RDP VM Setup
============

VPS IP: $VPS_IP
RDP Port: 3389

After Ubuntu install, run these in Ubuntu Terminal:
  sudo apt update
  sudo apt install -y xrdp
  sudo systemctl enable xrdp

Then connect with Remote Desktop to: $VPS_IP:3389
EOF

echo ""
echo "Info saved to: /root/RDP_VM_Info.txt"
