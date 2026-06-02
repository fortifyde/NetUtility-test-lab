#!/bin/sh
# lab-down.sh - Tear down all VMs and optionally clean up OVS bridge
# One command to shut down the full test lab.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
Usage: lab-down.sh [OPTIONS]

Shut down or tear down all VMs.

OPTIONS:
    --stop           Graceful shutdown (keep VMs intact, fast restart with lab-up --start)
    --keep-bridge    Keep the OVS bridge (don't delete ovs-br0)
    --help           Show this help message

EXAMPLES:
    lab-down.sh                # Full teardown: destroy VMs + remove bridge
    lab-down.sh --stop         # Graceful shutdown, VMs preserved for quick restart
    lab-down.sh --keep-bridge  # Destroy VMs but keep bridge
    lab-down.sh --stop --keep-bridge  # Shutdown only, keep bridge

EOF
    exit 0
}

# ── Parse arguments ──────────────────────────────────────────────────────
MODE="destroy"
KEEP_BRIDGE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --stop)         MODE="stop" ;;
        --keep-bridge)  KEEP_BRIDGE=1 ;;
        --help|-h)      usage ;;
        *) err "Unknown option: $1"; usage ;;
    esac
    shift
done

cd "$SCRIPT_DIR"

# ── Prerequisites check ───────────────────────────────────────────────────
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

log "Prerequisites OK"

# ── Stop or Destroy VMs ───────────────────────────────────────────────────
if [ "$MODE" = "stop" ]; then
    log "Gracefully shutting down all VMs..."
    for domain in "netutil-lab-kali" "netutil-lab-debian" "netutil-lab-ubuntu" "netutil-lab-dmz" "netutil-lab-cisco-ios" "netutil-lab-cisco-nexus" "netutil-lab-windows"; do
        if virsh -c qemu:///system dominfo "$domain" >/dev/null 2>&1; then
            if virsh -c qemu:///system domstate "$domain" | grep -q "running"; then
                log "Shutting down $domain..."
                virsh -c qemu:///system shutdown "$domain" 2>/dev/null || true
            else
                info "$domain is already stopped"
            fi
        else
            info "$domain does not exist"
        fi
    done
    # Wait for shutdowns to complete
    info "Waiting for VMs to shut down..."
    for domain in "netutil-lab-kali" "netutil-lab-debian" "netutil-lab-ubuntu" "netutil-lab-dmz" "netutil-lab-cisco-ios" "netutil-lab-cisco-nexus" "netutil-lab-windows"; do
        if virsh -c qemu:///system dominfo "$domain" >/dev/null 2>&1; then
            virsh -c qemu:///system domstate "$domain" | grep -q "shut off" || \
                virsh -c qemu:///system domwait "$domain" --state "shut off" --timeout 60 2>/dev/null || true
        fi
    done
    log "All VMs shut down"
else
    log "Destroying all VMs..."
    terraform destroy -auto-approve
    log "VMs destroyed"
fi

# ── Remove OVS bridge (destroy mode only) ─────────────────────────────────
if [ "$MODE" = "destroy" ] && [ $KEEP_BRIDGE -eq 0 ]; then
    log "Removing OVS bridge..."
    
    if ovs-vsctl br-exists ovs-br0 2>/dev/null; then
        sudo ovs-vsctl del-br ovs-br0
        log "OVS bridge removed"
    else
        info "OVS bridge ovs-br0 does not exist (already removed)"
    fi
elif [ "$MODE" = "destroy" ]; then
    info "Keeping OVS bridge (--keep-bridge)"
fi

# ── Clean up stale libvirt resources (destroy mode only) ──────────────────
if [ "$MODE" = "destroy" ]; then
    log "Cleaning up any stale libvirt resources..."

    # Networks
    for net in "netutil-lab-mgmt" "netutil-lab-ovs"; do
        if virsh -c qemu:///system net-info "$net" >/dev/null 2>&1; then
            info "Destroying network: $net"
            virsh -c qemu:///system net-destroy "$net" 2>/dev/null || true
            virsh -c qemu:///system net-undefine "$net" 2>/dev/null || true
        fi
    done

    # Storage pool
    for pool in "netutil-lab-volumes" "netutil-lab-pool"; do
        if virsh -c qemu:///system pool-info "$pool" >/dev/null 2>&1; then
            info "Destroying storage pool: $pool"
            virsh -c qemu:///system pool-destroy "$pool" 2>/dev/null || true
            virsh -c qemu:///system pool-undefine "$pool" 2>/dev/null || true
        fi
    done

    # Domains (VMs)
    for domain in "netutil-lab-debian" "netutil-lab-dmz" "netutil-lab-kali" "netutil-lab-ubuntu" "netutil-lab-windows" "netutil-lab-cisco-ios" "netutil-lab-cisco-nexus"; do
        if virsh -c qemu:///system dominfo "$domain" >/dev/null 2>&1; then
            info "Undefining domain: $domain"
            # Try regular undefine first, then with --nvram for UEFI VMs
            virsh -c qemu:///system undefine "$domain" 2>/dev/null || \
            virsh -c qemu:///system undefine --nvram "$domain" 2>/dev/null || true
        fi
    done

    # Cloud-init ISOs (generated by Terraform)
    if [ -d "$SCRIPT_DIR/images" ]; then
        info "Removing cloud-init ISOs..."
        rm -f "$SCRIPT_DIR/images/netutil-lab-"*-init.iso 2>/dev/null || true
    fi

    log "Libvirt resources cleaned"
fi

# ── Done ─────────────────────────────────────────────────────────────────
log "Lab shutdown complete!"