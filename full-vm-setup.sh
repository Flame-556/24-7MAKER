#!/bin/bash

# Complete Ubuntu Desktop VM Setup with Chrome
# Run as ROOT on your Ubuntu VPS

echo "=========================================="
echo "  UBUNTU DESKTOP VM - AUTO SETUP"
echo "=========================================="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
VM_NAME="UbuntuDesktop"
VM_MEMORY="4096"
VM_CORES="2"
VM_DISK_SIZE="40"
DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
ISO_PATH="/var/lib/libvirt/images/ubuntu-desktop.iso"
NOVNC_PORT="6080"

# Functions
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root!"
    exit 1
fi

log_info "Starting setup..."

# ============================================
# STEP 1: Install virtualization tools
# ============================================
log_info "[1/6] Installing virtualization tools..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq 2>/dev/null
apt-get install -y -qq \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-daemon \
    virt-manager \
    bridge-utils \
    vnc4server \
    novnc \
    websockify \
    openssl \
    wget \
    curl \
    git \
    python3 \
    xdg-utils \
    2>/dev/null

# Enable and start libvirtd
systemctl enable libvirtd 2>/dev/null || true
systemctl start libvirtd 2>/dev/null || true

# Wait for libvirtd to be ready
sleep 2

log_success "Virtualization tools installed"

# ============================================
# STEP 2: Download Ubuntu Desktop ISO
# ============================================
log_info "[2/6] Downloading Ubuntu Desktop 22.04 LTS..."

mkdir -p /var/lib/libvirt/images

# Try different mirrors
if [ ! -f "$ISO_PATH" ] || [ $(stat -c%s "$ISO_PATH" 2>/dev/null || echo 0) -lt 1000000000 ]; then
    rm -f "$ISO_PATH"

    # Try mirrors in order
    MIRRORS=(
        "https://cdimage.ubuntu.com/releases/22.04.4/release/ubuntu-22.04.4-desktop-amd64.iso"
        "https://releases.ubuntu.com/22.04.4/ubuntu-22.04.4-desktop-amd64.iso"
        "https://mirror.us-tx.kamatera.com/ubuntu-releases/22.04.4/ubuntu-22.04.4-desktop-amd64.iso"
        "http://archive.ubuntu.com/ubuntu-releases/22.04.4/ubuntu-22.04.4-desktop-amd64.iso"
    )

    for URL in "${MIRRORS[@]}"; do
        log_info "Trying: $URL"
        if wget -q --show-progress -O "$ISO_PATH" "$URL" 2>&1; then
            if [ -s "$ISO_PATH" ] && [ $(stat -c%s "$ISO_PATH" 2>/dev/null || echo 0) -gt 3000000000 ]; then
                log_success "Downloaded Ubuntu ISO ($(ls -lh "$ISO_PATH" | awk '{print $5}'))"
                break
            fi
        fi
        rm -f "$ISO_PATH"
    done
fi

if [ ! -f "$ISO_PATH" ] || [ ! -s "$ISO_PATH" ]; then
    log_error "Failed to download Ubuntu ISO!"
    exit 1
fi

# ============================================
# STEP 3: Create virtual disk
# ============================================
log_info "[3/6] Creating virtual disk (${VM_DISK_SIZE}GB)..."

if [ ! -f "$DISK_PATH" ]; then
    qemu-img create -f qcow2 "$DISK_PATH" "${VM_DISK_SIZE}G" > /dev/null 2>&1
fi

if [ -f "$DISK_PATH" ]; then
    log_success "Disk created: $(ls -lh "$DISK_PATH" | awk '{print $5}')"
else
    log_error "Failed to create disk!"
    exit 1
fi

# ============================================
# STEP 4: Create and start VM
# ============================================
log_info "[4/6] Creating Ubuntu Desktop VM..."

# Remove existing VM if exists
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
    --noautoconsole 2>&1 | head -5

sleep 3

# Check if VM is running
if virsh list | grep -q "$VM_NAME"; then
    log_success "VM is running!"
else
    log_error "VM failed to start!"
    virsh list --all
    exit 1
fi

# ============================================
# STEP 5: Setup noVNC for web access
# ============================================
log_info "[5/6] Setting up noVNC web access..."

# Install noVNC
if [ ! -d "/opt/novnc" ]; then
    git clone https://github.com/novnc/noVNC.git /opt/novnc 2>/dev/null || {
        mkdir -p /opt/novnc
        cd /opt/novnc
        curl -sL https://github.com/novnc/noVNC/archive/refs/heads/master.tar.gz | tar xz --strip-components=1
    }
fi

# Kill any existing websockify
pkill -f websockify 2>/dev/null || true
sleep 1

# Get VNC port
VNC_PORT=$(virsh dumpxml "$VM_NAME" 2>/dev/null | grep -oP "(?<=port=')[0-9]+" | head -1)
[ -z "$VNC_PORT" ] && VNC_PORT="5900"

# Start noVNC
/usr/bin/websockify --daemon --idle-timeout=60 --web=/opt/novnc ${NOVNC_PORT}:127.0.0.1:${VNC_PORT} > /dev/null 2>&1 &
sleep 2

# Create systemd service
cat > /etc/systemd/system/novnc.service <<EOF
[Unit]
Description=noVNC Web VNC
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/novnc
ExecStart=/usr/bin/websockify --daemon --idle-timeout=60 --web=/opt/novnc ${NOVNC_PORT}:127.0.0.1:${VNC_PORT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable novnc 2>/dev/null || true
systemctl start novnc 2>/dev/null || true

log_success "noVNC started on port $NOVNC_PORT"

# ============================================
# STEP 6: Get IPs and show info
# ============================================
log_info "[6/6] Getting connection information..."

# Get IPs
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
BRIDGE_IP="192.168.122.1"

# Get VNC port
VNC_PORT=$(virsh dumpxml "$VM_NAME" 2>/dev/null | grep -oP "(?<=port=')[0-9]+" | head -1)
[ -z "$VNC_PORT" ] && VNC_PORT="5900"

# Get VM status
VM_STATUS=$(virsh list | grep "$VM_NAME" | awk '{print $3}')

# ============================================
# OUTPUT RESULTS
# ============================================
echo ""
echo "=========================================="
echo "     SETUP COMPLETE!"
echo "=========================================="
echo ""
echo -e "${GREEN}VM STATUS:${NC} $VM_STATUS"
echo -e "${GREEN}VM NAME:${NC} $VM_NAME"
echo -e "${GREEN}MEMORY:${NC} ${VM_MEMORY}MB"
echo -e "${GREEN}CPU CORES:${NC} $VM_CORES"
echo ""
echo "----------------------------------------"
echo -e "${CYAN}ACCESS VIA WEB BROWSER:${NC}"
echo ""
echo "  Option 1 (Direct):"
echo "    http://${LOCAL_IP}:${NOVNC_PORT}/vnc.html"
echo ""
echo "  Option 2 (Via Bridge IP):"
echo "    http://${BRIDGE_IP}:${NOVNC_PORT}/vnc.html"
echo ""
echo "  Option 3 (SSH Tunnel - from your PC):"
echo "    ssh -L ${NOVNC_PORT}:localhost:${NOVNC_PORT} root@${LOCAL_IP}"
echo "    Then open: http://localhost:${NOVNC_PORT}/vnc.html"
echo ""
echo "----------------------------------------"
echo -e "${CYAN}ACCESS VIA VNC CLIENT:${NC}"
echo "    Host: ${LOCAL_IP}"
echo "    Port: ${VNC_PORT}"
echo ""
echo "----------------------------------------"
echo -e "${CYAN}AFTER UBUNTU INSTALL:${NC}"
echo ""
echo "  To install Chrome, open Terminal and run:"
echo ""
echo "    wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
echo "    sudo dpkg -i google-chrome-stable_current_amd64.deb"
echo "    sudo apt-get install -f -y"
echo ""
echo "=========================================="

# Save info to file
cat > /root/VM_Access_Info.txt <<EOF
UBUNTU DESKTOP VM ACCESS INFO
Generated: $(date)
==============================

VM STATUS: $VM_STATUS
VM NAME: $VM_NAME
MEMORY: ${VM_MEMORY}MB
CPU CORES: $VM_CORES

WEB ACCESS:
  http://${LOCAL_IP}:${NOVNC_PORT}/vnc.html
  http://${BRIDGE_IP}:${NOVNC_PORT}/vnc.html

VNC CLIENT:
  Host: ${LOCAL_IP}
  Port: $VNC_PORT

CHROME INSTALLATION (after Ubuntu loads):
  wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  sudo dpkg -i google-chrome-stable_current_amd64.deb
  sudo apt-get install -f -y

COMMANDS:
  virsh list              - List VMs
  virsh start $VM_NAME    - Start VM
  virsh shutdown $VM_NAME - Stop VM
  virsh console $VM_NAME  - Serial console
EOF

log_success "Access info saved to: /root/VM_Access_Info.txt"
echo ""
log_info "Open in your browser: http://${LOCAL_IP}:${NOVNC_PORT}/vnc.html"
echo ""
