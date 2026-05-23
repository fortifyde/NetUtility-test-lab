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

# ── Usage ────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: lab-up.sh [OPTIONS]

Build NetUtility, provision all VMs, deploy latest binary + scripts to Kali.

OPTIONS:
    --skip-build     Skip NetUtility build (use existing binaries)
    --skip-ovs       Skip OVS setup (bridge already exists + ports configured)
    --deploy-only    Fast iteration: build + SCP to running Kali, no Terraform
    --help           Show this help message

EXAMPLES:
    lab-up.sh                          # Full provisioning workflow
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

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build)   SKIP_BUILD=1 ;;
        --skip-ovs)     SKIP_OVS=1 ;;
        --deploy-only)  DEPLOY_ONLY=1 ;;
        --help|-h)      usage ;;
        *) err "Unknown option: $1"; usage ;;
    esac
    shift
done

cd "$LAB_DIR"

# ── Build NetUtility (unless skipped) ────────────────────────────────────
if [ $SKIP_BUILD -eq 0 ]; then
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
if [ $DEPLOY_ONLY -eq 1 ]; then
    log "Deploy-only mode: pushing to running Kali VM"
    
    # Resolve Kali IP from Terraform state
    if [ ! -d .terraform ]; then
        err "Terraform not initialized. Cannot resolve Kali IP."
        err "Run 'terraform init' first, or use full lab-up.sh"
        exit 1
    fi
    
    KALI_IP=$(terraform output -raw kali_mgmt_ip 2>/dev/null || true)
    if [ -z "$KALI_IP" ] || [ "$KALI_IP" = "null" ]; then
        err "Failed to resolve Kali IP from Terraform state"
        err "Ensure the lab is running and Terraform state is available"
        exit 1
    fi
    
    # Resolve SSH key path from terraform.tfvars (with fallback)
    SSH_KEY=""
    if [ -f terraform.tfvars ]; then
        SSH_KEY=$(grep -E '^ssh_private_key_path' terraform.tfvars | sed 's/.*"\(.*\)".*/\1/' | sed 's/^~\//'"$HOME"'/' || true)
    fi
    if [ -z "$SSH_KEY" ]; then
        SSH_KEY="$HOME/.ssh/id_rsa"
    fi
    if [ ! -f "$SSH_KEY" ]; then
        err "SSH key not found: $SSH_KEY"
        err "Update ssh_private_key_path in terraform.tfvars"
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
    
    log "Copying netutil-config.json..."
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "$NETUTIL_DIR/netutil-config.json" "kali@$KALI_IP:/opt/netutil/netutil-config.json"
    
    log "Copying bin/ directory..."
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -r \
        "$NETUTIL_DIR/bin" "kali@$KALI_IP:/opt/netutil/"
    
    log "Copying scripts/ directory..."
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -r \
        "$NETUTIL_DIR/scripts" "kali@$KALI_IP:/opt/netutil/"
    
    log "Deploy complete to /opt/netutil/ on kali@$KALI_IP"
    exit 0
fi

# ── Prerequisites check (full run) ───────────────────────────────────────
log "Checking prerequisites..."

check_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Required command not found: $1"
        exit 1
    fi
}

check_cmd terraform
check_cmd virsh
check_cmd ovs-vsctl

if [ ! -d "$NETUTIL_DIR" ]; then
    err "NetUtility directory not found at: $NETUTIL_DIR"
    exit 1
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

# ── Wait for Kali SSH ────────────────────────────────────────────────────
log "Waiting for Kali VM to become reachable (up to 5 min)..."

KALI_IP=$(terraform output -raw kali_mgmt_ip)
TIMEOUT=300
ELAPSED=0
INTERVAL=10

while [ $ELAPSED -lt $TIMEOUT ]; do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        "kali@$KALI_IP" "echo >/dev/null" 2>/dev/null; then
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
    info "Run NetUtility tests:"
    echo "  ssh kali@$KALI_IP 'cd /opt/netutil && sudo ./netutil scan --config netutil-config.json'"
fi

log "Done!"