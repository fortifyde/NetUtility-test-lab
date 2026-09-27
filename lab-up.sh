#!/bin/sh
# lab-up.sh - Build NetUtility, provision all VMs, deploy to Kali
# One command to bring the full test lab online.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$SCRIPT_DIR"
NETUTIL_DIR="../NetUtility"

# ── Colors (terminal only) ──────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[1;31m'
    GRN='\033[1;32m'
    YEL='\033[1;33m'
    CYN='\033[1;36m'
    RST='\033[0m'
else
    RED=''; GRN=''; YEL=''; CYN=''; RST=''
fi

log()   { printf "${GRN}[+]${RST} %s\n" "$*"; }
warn()  { printf "${YEL}[!]${RST} %s\n" "$*" >&2; }
err()   { printf "${RED}[-]${RST} %s\n" "$*" >&2; }
info()  { printf "${CYN}[*]${RST} %s\n" "$*"; }


# ── Resolve SSH key ──────────────────────────────────────────────────────
_resolve_ssh_key() {
    _key=""
    if [ -f terraform.tfvars ]; then
        _key=$(grep -E '^ssh_private_key_path' terraform.tfvars | sed 's/.*"\(.*\)".*/\1/' | sed 's|^~/|'"$HOME"'/|' || true)
    fi
    if [ -z "$_key" ] && [ -f .lab-ssh-key ]; then
        _key=".lab-ssh-key"
    fi
    if [ -z "$_key" ]; then
        _key="$HOME/.ssh/id_rsa"
    fi
    if [ ! -f "$_key" ]; then
        _key=""   # key not found — will try without -i (ssh-agent might work)
    fi
    echo "$_key"
}
# ── Usage ────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: lab-up.sh [OPTIONS]

Build NetUtility, provision all VMs, deploy latest binary + scripts to Kali.

OPTIONS:
    --start          Boot existing stopped VMs and wait for Kali (no Terraform/build)
    --skip-build     Skip NetUtility build (use existing binaries)
    --skip-ovs       Skip OVS setup (bridge already exists + ports configured)
    --deploy-only    Fast iteration: build + SCP to running Kali, no Terraform
    --help           Show this help message

EXAMPLES:
    lab-up.sh                          # Full provisioning workflow
    lab-up.sh --start                  # Boot stopped VMs, wait for Kali
    lab-up.sh --skip-build             # Reuse existing binaries
    lab-up.sh --skip-ovs               # Skip OVS setup (already configured)
    lab-up.sh --deploy-only            # Quick code push to running Kali
    lab-up.sh --skip-build --deploy-only  # Fastest iteration

EOF
    exit 0
}

# ── Parse arguments ──────────────────────────────────────────────────────
SKIP_BUILD=0
SKIP_OVS=0
DEPLOY_ONLY=0
START_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --start)        START_ONLY=1 ;;
        --skip-build)   SKIP_BUILD=1 ;;
        --skip-ovs)     SKIP_OVS=1 ;;
        --deploy-only)  DEPLOY_ONLY=1 ;;
        --help|-h)      usage ;;
        *) err "Unknown option: $1"; usage ;;
    esac
    shift
done

cd "$LAB_DIR"

# ── Start existing VMs (no build, no Terraform) ──────────────────────────
if [ $START_ONLY -eq 1 ]; then
    log "Starting existing VMs..."
    for domain in "netutil-lab-kali" "netutil-lab-debian" "netutil-lab-ubuntu" "netutil-lab-dmz" "netutil-lab-cisco-ios" "netutil-lab-cisco-nexus" "netutil-lab-windows"; do
        if virsh -c qemu:///system dominfo "$domain" >/dev/null 2>&1; then
            if virsh -c qemu:///system domstate "$domain" | grep -q "shut off"; then
                log "Starting $domain..."
                virsh -c qemu:///system start "$domain" 2>/dev/null || true
            else
                info "$domain is already running"
            fi
        else
            warn "$domain does not exist — run full lab-up.sh first"
        fi
    done
    # Re-apply OVS VLAN tags in case ports were recreated
    if [ -x "$SCRIPT_DIR/scripts/setup-ovs.sh" ]; then
        log "Running OVS post-deploy setup..."
        sudo "$SCRIPT_DIR/scripts/setup-ovs.sh" --post-deploy
        log "OVS post-deploy complete"
    fi
    # Fall through to wait-for-Kali section below
fi

# ── Build NetUtility (unless skipped or --start) ──────────────────────────
if [ $START_ONLY -eq 0 ] && [ $SKIP_BUILD -eq 0 ]; then
    log "Building NetUtility binaries..."
    if [ ! -d "$NETUTIL_DIR" ]; then
        err "NetUtility directory not found at: $NETUTIL_DIR"
        err "Update NETUTIL_DIR or ensure NetUtility is at ../NetUtility/"
        exit 1
    fi
    if [ ! -f "$NETUTIL_DIR/Makefile" ]; then
        err "No Makefile found in NetUtility directory"
        exit 1
    fi
    make -C "$NETUTIL_DIR" build
    log "Build complete"
else
    info "Skipping build (using existing binaries)"
fi

# ── Deploy-only mode (fast iteration) ────────────────────────────────────
if [ $START_ONLY -eq 0 ] && [ $DEPLOY_ONLY -eq 1 ]; then
    log "Deploy-only mode: pushing to running Kali VM"
    
    # Resolve Kali IP from Terraform state
    if [ ! -d .terraform ]; then
        err "Terraform not initialized. Cannot resolve Kali IP."
        err "Run 'terraform init' first, or use full lab-up.sh"
        exit 1
    fi
    
    KALI_IP=$(terraform output -raw kali_mgmt_ip 2>/dev/null || true)
    case "$KALI_IP" in *[!0-9.]*) KALI_IP="" ;; esac
    if [ -z "$KALI_IP" ]; then
        KALI_IP=$(virsh -c qemu:///system domifaddr netutil-lab-kali 2>/dev/null \
                  | awk '/ipv4/ { split($4, a, "/"); print a[1] }') || true
    fi
    if [ -z "$KALI_IP" ] || [ "$KALI_IP" = "null" ]; then
        err "Failed to resolve Kali IP — neither Terraform state nor virsh returned an address"
        err "Ensure the lab is running"
        exit 1
    fi
    
    # Resolve SSH key
    SSH_KEY=$(_resolve_ssh_key)
    if [ -z "$SSH_KEY" ]; then
        err "No SSH key found. Set ssh_private_key_path in terraform.tfvars"
        err "or place a key at ~/.ssh/id_rsa"
        exit 1
    fi
    
    log "Deploying to kali@$KALI_IP using key: $SSH_KEY"
    
    # Ensure remote directory exists
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "kali@$KALI_IP" "mkdir -p /opt/netutil/bin /opt/netutil/scripts"
    
    # Copy files
    log "Copying netutil binary..."
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "$NETUTIL_DIR/netutil" "kali@$KALI_IP:/opt/netutil/netutil"

    log "Copying bin/ directory..."
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -r \
        "$NETUTIL_DIR/bin" "kali@$KALI_IP:/opt/netutil/"
    
    log "Copying scripts/ directory..."
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -r \
        "$NETUTIL_DIR/scripts" "kali@$KALI_IP:/opt/netutil/"
    
    log "Deploy complete to /opt/netutil/ on kali@$KALI_IP"
    exit 0
fi

# ── Full provisioning (not --start) ──────────────────────────────────────
if [ $START_ONLY -eq 0 ]; then

# ── Prerequisites check (full run) ───────────────────────────────────────
log "Checking prerequisites..."

check_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Required command not found: $1"
        MISSING_CMD=1
    fi
}

warn_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        warn "Recommended command not found: $1 ($2)"
    fi
}

MISSING_CMD=0
check_cmd terraform
check_cmd virsh
check_cmd ovs-vsctl
# genisoimage or mkisofs required for cloud-init ISO generation
if command -v genisoimage >/dev/null 2>&1; then
    :
elif command -v mkisofs >/dev/null 2>&1; then
    :
else
    err "Required command not found: genisoimage (or mkisofs)"
    err "Install with: sudo dnf install genisoimage  OR  sudo apt install genisoimage"
    MISSING_CMD=1
fi
# snmpget required for demo-prep.sh pre-flight checks
warn_cmd snmpget "install net-snmp-utils for SNMP pre-flight checks"
# virt-viewer optional for Windows VM console access
warn_cmd virt-viewer "install virt-viewer for graphical VM console"

if [ "$MISSING_CMD" -ne 0 ]; then
    err "Install missing prerequisites and re-run"
    exit 1
fi

if [ ! -d "$NETUTIL_DIR" ]; then
    err "NetUtility directory not found at: $NETUTIL_DIR"
    exit 1
fi

# Check OVMF firmware when Windows is enabled
if grep -q 'enable_windows[[:space:]]*=[[:space:]]*true' terraform.tfvars 2>/dev/null; then
    OVMF_FOUND=false
    for _path in \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/qemu/OVMF_CODE.fd; do
        if [ -f "$_path" ]; then
            OVMF_FOUND=true
            info "OVMF firmware found: $_path"
            break
        fi
    done
    if [ "$OVMF_FOUND" = "false" ]; then
        err "Windows VM enabled but no OVMF firmware found"
        err "Install with: sudo dnf install edk2-ovmf  OR  sudo apt install ovmf"
        exit 1
    fi
fi

log "Prerequisites OK"

# ── Check images exist ───────────────────────────────────────────────────
log "Checking for required images..."

REQUIRED_IMAGES="
    kali-linux-last-amd64.qcow2
    debian-12-generic-amd64.qcow2
    jammy-server-cloudimg-amd64.img
"

MISSING=""
for img in $REQUIRED_IMAGES; do
    if [ ! -f "images/$img" ]; then
        MISSING="$MISSING $img"
    fi
done

if [ -n "$MISSING" ]; then
    err "Missing required images:$MISSING"
    err "Run 'scripts/download-images.sh --all' to download"
    exit 1
fi

log "Images OK"

# ── OVS pre-deploy (create bridge) ───────────────────────────────────────
if [ $SKIP_OVS -eq 0 ]; then
    log "Running OVS pre-deploy setup..."
    sudo "$SCRIPT_DIR/scripts/setup-ovs.sh"
    log "OVS pre-deploy complete"
else
    info "Skipping OVS setup (--skip-ovs)"
fi

# ── Terraform ────────────────────────────────────────────────────────────
log "Provisioning VMs with Terraform..."

if [ ! -d .terraform ]; then
    log "Initializing Terraform..."
    terraform init
fi

terraform apply -auto-approve

log "VMs provisioned"

# ── OVS post-deploy (configure VLAN ports) ───────────────────────────────
if [ $SKIP_OVS -eq 0 ]; then
    log "Running OVS post-deploy setup..."
    sudo "$SCRIPT_DIR/scripts/setup-ovs.sh" --post-deploy
    log "OVS post-deploy complete"
fi

# ── Verify deploy succeeded ──────────────────────────────────────────────
# If cloud-init was still running during the Terraform deploy_netutil step,
# the binary may not have landed. Retry once.
KALI_IP_VERIFY=$(terraform output -raw kali_mgmt_ip 2>/dev/null || true)
case "$KALI_IP_VERIFY" in *[!0-9.]*) KALI_IP_VERIFY="" ;; esac
if [ -z "$KALI_IP_VERIFY" ]; then
    KALI_IP_VERIFY=$(virsh -c qemu:///system domifaddr netutil-lab-kali 2>/dev/null \
                     | awk '/ipv4/ { split($4, a, "/"); print a[1] }') || true
fi
SSH_KEY_VERIFY=$(_resolve_ssh_key)
[ -z "$SSH_KEY_VERIFY" ] && SSH_KEY_VERIFY="$HOME/.ssh/id_rsa"
_SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
[ -n "$SSH_KEY_VERIFY" ] && [ -f "$SSH_KEY_VERIFY" ] && _SSH_OPTS="$_SSH_OPTS -i $SSH_KEY_VERIFY"
if [ -n "$KALI_IP_VERIFY" ] && ssh $_SSH_OPTS "kali@$KALI_IP_VERIFY" "echo >/dev/null" 2>/dev/null; then
    if ! ssh $_SSH_OPTS "kali@$KALI_IP_VERIFY" "test -x /opt/netutil/netutil" 2>/dev/null; then
        warn "NetUtility binary not found on Kali — re-running deploy..."
        if ! terraform apply -auto-approve -replace=null_resource.deploy_netutil; then
            err "Deploy retry failed — use --deploy-only after Kali is fully booted"
        fi
    fi
fi

fi
# end full provisioning block

# ── Resolve Kali IP ─────────────────────────────────────────────────────
# Terraform output is preferred but can be empty or stale after a partial
# re-provision.  Fall back to querying libvirt directly via virsh.
_resolve_kali_ip() {
    _tf_ip=$(terraform output -raw kali_mgmt_ip 2>/dev/null || true)
    # A valid IP contains only digits and dots
    case "$_tf_ip" in
        *[!0-9.]*) ;;          # not an IP — fall through
        "")           ;;        # empty — fall through
        *)  echo "$_tf_ip"; return ;;
    esac

    # Fallback: ask libvirt for the VM's address on the management network
    _addr=$(virsh -c qemu:///system domifaddr netutil-lab-kali 2>/dev/null \
            | awk '/ipv4/ { split($4, a, "/"); print a[1] }')
    if [ -n "$_addr" ]; then
        echo "$_addr"
        return
    fi

    # Nothing available yet
    echo ""
}

log "Waiting for Kali VM to become reachable (up to 5 min)..."

KALI_IP=$(_resolve_kali_ip)
TIMEOUT=300
ELAPSED=0
INTERVAL=10
SSH_KEY=$(_resolve_ssh_key)
_SSH_WAIT_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
[ -n "$SSH_KEY" ] && _SSH_WAIT_OPTS="$_SSH_WAIT_OPTS -i $SSH_KEY"

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Re-resolve IP on each attempt — VM may still be booting / getting DHCP
    [ -z "$KALI_IP" ] && KALI_IP=$(_resolve_kali_ip)
    if [ -n "$KALI_IP" ] && ssh $_SSH_WAIT_OPTS "kali@$KALI_IP" "echo >/dev/null" 2>/dev/null; then
        log "Kali VM is reachable at $KALI_IP"
        break
    fi
    info "Waiting... ($ELAPSED/$TIMEOUT seconds)"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    warn "Kali VM did not become reachable within timeout"
    warn "SSH manually with: ssh kali@$KALI_IP"
else
    # Display VM IPs
    log "Lab is online!"
    echo ""
    info "VM Management IPs:"
    echo "  Kali:      $KALI_IP"
    
    TARGETS=$(terraform output -raw all_targets 2>/dev/null || true)
    if [ -n "$TARGETS" ] && [ "$TARGETS" != "null" ]; then
        echo "  Targets:   $TARGETS"
    fi
    echo ""
    info "Connect to Kali:"
    echo "  ssh kali@$KALI_IP"
    echo ""
    info "Run NetUtility:"
    echo "  ssh kali@$KALI_IP"
    echo "  netutil"
fi

log "Done!"