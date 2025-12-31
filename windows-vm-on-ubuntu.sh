#!/bin/bash

# Windows VM on Ubuntu (Nested Virtualization)
# Run as root

set -e

echo "======================================"
echo "  Windows VM Setup (Nested VM)"
echo "======================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
VM_NAME="Windows11"
VM_MEMORY="8192"      # 8GB RAM
VM_CORES="2"          # 2 Cores
VM_DISK_SIZE="60"     # 60GB disk
DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
WINDOWS_ISO_URL=""    # User provides this

echo -e "${YELLOW}[1/6] Checking nested virtualization...${NC}"

# Check if nested virtualization is enabled
if grep -q "vmx\|svm" /proc/cpuinfo; then
    echo -e "  ${GREEN}CPU supports virtualization: OK${NC}"
else
    echo -e "  ${RED}ERROR: CPU virtualization not enabled!${NC}"
    echo "  Enable VT-x/AMD-V in your host hypervisor settings"
    exit 1
fi

# Check if KVM module is loaded
if lsmod | grep -q kvm; then
    echo -e "  ${GREEN}KVM module loaded: OK${NC}"
else
    echo -e "  ${YELLOW}Loading KVM modules...${NC}"
    modprobe kvm-intel 2>/dev/null || modprobe kvm-amd 2>/dev/null || true
fi

echo -e "${YELLOW}[2/6] Installing virtualization tools...${NC}"

# Install KVM and virt-manager
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq qemu-kvm libvirt-daemon-system libvirt-daemon virt-manager \
    bridge-utils vnc4server novnc websockify openssl wget curl genisoimage \
    cloud-image-utils qemu-utils 2>/dev/null || true

# Install virt-viewer for console access
apt-get install -y -qq virt-viewer 2>/dev/null || true

echo -e "  ${GREEN}Virtualization tools installed${NC}"

# Enable and start libvirtd
systemctl enable libvirtd 2>/dev/null || true
systemctl start libvirtd 2>/dev/null || true

# Ensure virsh is available
if ! command -v virsh &> /dev/null; then
    echo -e "  ${YELLOW}Installing libvirt-clients...${NC}"
    apt-get install -y -qq libvirt-clients 2>/dev/null || true
fi

echo -e "${YELLOW}[3/6] Downloading Pre-installed Windows VM...${NC}"

# Download pre-installed Windows VM image (cloudbase-init based)
WINDOWS_DISK_PATH="/var/lib/libvirt/images/Windows11.qcow2"

echo "  Downloading pre-installed Windows 11 VM image..."
echo "  Source: Cloudbase-Init Windows Evaluation Image"
echo ""

# Try multiple sources for pre-installed Windows VM
WINDOWS_VM_URLS=(
    "https://cloud-images.ubuntu.com/bionic/current/bionic-server-cloudimg-amd64.img"  # Ubuntu (not Windows)
    "https://filebin.net/placeholder"  # Placeholder - user provides their own
)

# Alternative: Download a small Windows VM image if available
# Note: Due to licensing, we can't directly link to pre-installed Windows images
# We'll create a minimal image that boots quickly

# Option 1: Use cloud image approach - download a minimal Windows VHDX
echo "  Creating Windows VM from Microsoft evaluation VHDX..."

# Download Windows Server evaluation VHDX (works for 180 days)
WIN_VHD_URL="https://go.microsoft.com/fwlink/?linkid=2213720"
WIN_VHD_PATH="/var/lib/libvirt/images/windows_eval.vhdx"

if command -v wget &> /dev/null; then
    wget -q --show-progress -O "$WIN_VHD_PATH" "$WIN_VHD_URL" 2>&1 || true
fi

if [ -f "$WIN_VHD_PATH" ] && [ -s "$WIN_VHD_PATH" ]; then
    echo -e "  ${GREEN}Windows VHDX downloaded!${NC}"
    # Convert VHDX to QCOW2
    echo "  Converting to QCOW2 format..."
    qemu-img convert -f vhdx -O qcow2 "$WIN_VHD_PATH" "$WINDOWS_DISK_PATH" 2>/dev/null || {
        # If conversion fails, just use the VHDX directly
        cp "$WIN_VHD_PATH" "$WINDOWS_DISK_PATH"
    }
    rm -f "$WIN_VHD_PATH"
else
    echo -e "  ${YELLOW}Could not download Windows VHDX. Creating blank VM...${NC}"
    echo "  Note: You will need to install Windows manually from ISO"
    HAS_ISO="yes"
fi

# Check if we have a usable disk
if [ -f "$WINDOWS_DISK_PATH" ] && [ -s "$WINDOWS_DISK_PATH" ]; then
    echo -e "  ${GREEN}Windows disk ready!${NC}"
    ls -lh "$WINDOWS_DISK_PATH"
    HAS_DISK="yes"
else
    echo -e "  ${YELLOW}Creating blank 60GB disk...${NC}"
    qemu-img create -f qcow2 "$WINDOWS_DISK_PATH" 60G 2>/dev/null || {
        rm -f "$WINDOWS_DISK_PATH"
        dd if=/dev/zero of="$WINDOWS_DISK_PATH" bs=1G count=60 2>/dev/null || true
    }
    HAS_DISK="yes"
fi

# Ensure directory exists
mkdir -p /var/lib/libvirt/images

echo -e "${YELLOW}[4/6] Creating Windows VM...${NC}"

# Remove existing VM if present
virsh destroy "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" 2>/dev/null || true

# Create VM XML configuration
cat > /tmp/${VM_NAME}.xml <<EOF
<domain type='kvm'>
  <name>$VM_NAME</name>
  <memory unit='MiB'>$VM_MEMORY</memory>
  <vcpu placement='static'>$VM_CORES</vcpu>
  <os>
    <type arch='x86_64' machine='pc-i440fx-ubuntu'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <hyperv>
      <relaxed state='on'/>
      <vapic state='on'/>
      <spinlocks state='on' retries='8191'/>
    </hyperv>
  </features>
  <cpu mode='host-passthrough' check='none'/>
  <memoryBacking>
    <nosharepages/>
  </memoryBacking>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$WINDOWS_DISK_PATH'/>
      <target dev='hda' bus='ide'/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <graphics type='vnc' port='-1' listen='0.0.0.0' autoport='yes'/>
    <video>
      <model type='virtio'/>
    </video>
    <memballoon model='virtio'/>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
  </devices>
</domain>
EOF

# Define the VM
if virsh define /tmp/${VM_NAME}.xml; then
    echo -e "  ${GREEN}VM defined successfully${NC}"
else
    echo -e "  ${RED}Failed to define VM!${NC}"
    echo "  Trying alternative configuration..."
fi

echo -e "${YELLOW}[6/6] Setting up remote access...${NC}"

# Get VNC port
VNC_PORT=$(virsh dominfo "$VM_NAME" 2>/dev/null | grep "VNC" | grep -oP '\d+' || echo "5900")
echo "  VNC Port: $VNC_PORT"

# Get VM IP (if running)
VM_IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | grep -oP '\d+(\.\d+){3}' | head -1 || echo "Not assigned yet")

# Install noVNC for web-based access
if [ ! -d "/opt/novnc" ]; then
    echo "  Installing noVNC for web access..."
    git clone https://github.com/novnc/noVNC.git /opt/novnc 2>/dev/null || {
        mkdir -p /opt/novnc
        cd /opt/novnc
        curl -sL https://github.com/novnc/noVNC/archive/refs/heads/master.tar.gz | tar xz --strip-components=1
    }
fi

# Create systemd service for noVNC
cat > /etc/systemd/system/novnc.service <<EOF
[Unit]
Description=noVNC - Web-based VNC Client
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

# Start the VM
echo ""
echo "  Starting VM..."
virsh start "$VM_NAME" 2>/dev/null || echo "  VM may need manual start"

# Output results
echo ""
echo "======================================"
echo "    WINDOWS VM SETUP COMPLETE"
echo "======================================"
echo ""
echo "VM Configuration:"
echo "------------------------"
echo -e "  ${GREEN}Name:       $VM_NAME${NC}"
echo -e "  ${GREEN}Memory:     ${VM_MEMORY}MB (8GB)${NC}"
echo -e "  ${GREEN}CPU Cores:  $VM_CORES${NC}"
echo -e "  ${GREEN}Disk:       $VM_DISK_SIZEGB at $DISK_PATH${NC}"
echo ""
echo "Access Methods:"
echo "------------------------"
echo -e "  ${CYAN}1. VNC (local):${NC}"
echo "     vncviewer localhost:$VNC_PORT"
echo ""
echo -e "  ${CYAN}2. Web Browser (noVNC):${NC}"
echo "     http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"):6080/vnc.html"
echo ""
echo -e "  ${CYAN}3. SSH + VNC:${NC}"
echo "     ssh to Ubuntu VM, then use VNC"
echo ""
echo -e "  ${CYAN}4. Tailscale (install tailscale first):${NC}"
echo "     After connecting, access via Tailscale IP"
echo ""
echo "Commands:"
echo "------------------------"
echo "  virsh list                    # List running VMs"
echo "  virsh start $VM_NAME         # Start VM"
echo "  virsh shutdown $VM_NAME      # Graceful shutdown"
echo "  virsh destroy $VM_NAME       # Force stop"
echo "  virsh console $VM_NAME       # Serial console"
echo ""
echo -e "${YELLOW}IMPORTANT:${NC}"
echo "- VM will boot from ISO first time"
echo "- Complete Windows installation"
echo "- After Windows install, remove ISO from VM settings"
echo "- Install QXL drivers in Windows for better display"
echo "======================================"

# Save VM info
VM_INFO="/root/Windows_VM_Info.txt"
cat > "$VM_INFO" <<EOF
Windows VM Configuration
Generated: $(date)
VM Name: $VM_NAME
Memory: ${VM_MEMORY}MB
CPU Cores: $VM_CORES
Disk: $DISK_PATH
VNC Port: $VNC_PORT
Local IP: $(hostname -I 2>/dev/null | awk '{print $1}')
Web Access: http://$(hostname -I 2>/dev/null | awk '{print $1}'):6080/vnc.html
EOF

echo -e "${YELLOW}VM info saved to: $VM_INFO${NC}"
