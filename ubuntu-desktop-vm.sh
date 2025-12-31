#!/bin/bash

# Ubuntu Desktop VM with Chrome
# Run as root on Ubuntu VPS

set -e

echo "======================================"
echo "  Ubuntu Desktop VM with Chrome"
echo "======================================"
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
VM_NAME="UbuntuDesktop"
VM_MEMORY="4096"    # 4GB RAM
VM_CORES="2"
VM_DISK_SIZE="40"
DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
ISO_PATH="/var/lib/libvirt/images/ubuntu-desktop.iso"

echo -e "${YELLOW}[1/6] Installing virtualization tools...${NC}"

# Install KVM and virt-manager
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq qemu-kvm libvirt-daemon-system libvirt-daemon \
    virt-manager bridge-utils vnc4server novnc websockify \
    openssl wget curl genisoimage qemu-utils 2>/dev/null

# Enable libvirtd
systemctl enable libvirtd 2>/dev/null || true
systemctl start libvirtd 2>/dev/null || true

echo -e "  ${GREEN}Virtualization tools ready${NC}"

echo -e "${YELLOW}[2/6] Downloading Ubuntu Desktop ISO...${NC}"

# Download Ubuntu Desktop
if [ ! -f "$ISO_PATH" ] || [ ! -s "$ISO_PATH" ]; then
    echo "  Downloading Ubuntu Desktop 22.04 LTS..."
    wget -q --show-progress -O "$ISO_PATH" \
        "https://releases.ubuntu.com/22.04/ubuntu-22.04.3-desktop-amd64.iso" || {
        echo -e "  ${YELLOW}Direct download failed, trying alternative...${NC}"
        wget -q --show-progress -O "$ISO_PATH" \
            "https://cdimage.ubuntu.com/releases/22.04/release/ubuntu-22.04.3-desktop-amd64.iso"
    }
fi

if [ -f "$ISO_PATH" ] && [ -s "$ISO_PATH" ]; then
    echo -e "  ${GREEN}ISO downloaded: $(ls -lh "$ISO_PATH" | awk '{print $5}')${NC}"
else
    echo -e "  ${RED}Failed to download ISO!${NC}"
    exit 1
fi

echo -e "${YELLOW}[3/6] Creating virtual disk (${VM_DISK_SIZE}GB)...${NC}"

# Create disk
mkdir -p /var/lib/libvirt/images
if [ ! -f "$DISK_PATH" ]; then
    qemu-img create -f qcow2 "$DISK_PATH" "${VM_DISK_SIZE}G"
fi
echo -e "  ${GREEN}Disk ready: $(ls -lh "$DISK_PATH" | awk '{print $5}')${NC}"

echo -e "${YELLOW}[4/6] Creating VM...${NC}"

# Remove existing VM
virsh destroy "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" 2>/dev/null || true

# Create VM
virt-install \
    --name "$VM_NAME" \
    --memory "$VM_MEMORY" \
    --vcpus "$VM_CORES" \
    --disk path="$DISK_PATH",size="$VM_DISK_SIZE" \
    --cdrom "$ISO_PATH" \
    --network bridge=virbr0 \
    --graphics vnc,listen=0.0.0.0 \
    --os-variant ubuntu22.04 \
    --noautoconsole

echo -e "  ${GREEN}VM created!${NC}"

echo -e "${YELLOW}[5/6] Setting up web access (noVNC)...${NC}"

# Get VNC port
VNC_PORT=$(virsh dominfo "$VM_NAME" 2>/dev/null | grep "VNC" | grep -oP '\d+' || echo "5900")

# Install noVNC
if [ ! -d "/opt/novnc" ]; then
    git clone https://github.com/novnc/noVNC.git /opt/novnc 2>/dev/null || {
        mkdir -p /opt/novnc
        cd /opt/novnc
        curl -sL https://github.com/novnc/noVNC/archive/refs/heads/master.tar.gz | tar xz --strip-components=1
    }
fi

# Create noVNC service
cat > /etc/systemd/system/novnc.service <<EOF
[Unit]
Description=noVNC Web VNC
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/novnc
ExecStart=/usr/bin/websockify --daemon --idle-timeout=60 --web=/opt/novnc ${VNC_PORT}:127.0.0.1:${VNC_PORT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable novnc 2>/dev/null || true
systemctl start novnc 2>/dev/null || true

echo -e "  ${GREEN}noVNC started on port ${VNC_PORT}${NC}"

echo -e "${YELLOW}[6/6] Setup complete!${NC}"

# Get IP
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo "======================================"
echo "    UBUNTU DESKTOP VM READY"
echo "======================================"
echo ""
echo -e "${GREEN}VM Configuration:${NC}"
echo "  Name:       $VM_NAME"
echo "  Memory:     ${VM_MEMORY}MB"
echo "  CPU Cores:  $VM_CORES"
echo "  Disk:       ${VM_DISK_SIZE}GB at $DISK_PATH"
echo ""
echo -e "${CYAN}Access via Web Browser:${NC}"
echo "  http://$LOCAL_IP:${VNC_PORT}/vnc.html"
echo ""
echo -e "${CYAN}Access via VNC Client:${NC}"
echo "  vncviewer $LOCAL_IP:${VNC_PORT}"
echo ""
echo "After Ubuntu loads:"
echo "1. Complete Ubuntu installation wizard"
echo "2. Open Terminal"
echo "3. Run: chrome-installer.sh (auto-downloaded)"
echo ""
echo "To install Chrome after Ubuntu boots:"
echo "  wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
echo "  sudo dpkg -i google-chrome-stable_current_amd64.deb"
echo "  sudo apt-get install -f -y"
echo ""
echo "======================================"
