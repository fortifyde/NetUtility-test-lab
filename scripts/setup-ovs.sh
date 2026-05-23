#!/bin/sh
# setup-ovs.sh - Configure Open vSwitch bridge and VLAN-tagged ports for NetUtility lab
# Requires root. Idempotent. POSIX-compliant.

set -e

BRIDGE="ovs-br0"
SCRIPT_NAME="$(basename "$0")"

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

# ── Help ────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: setup-ovs.sh [OPTIONS]

Configure OVS bridge (ovs-br0) for NetUtility lab.

Run modes:
  (default)  Pre-deploy: create bridge only. Run BEFORE terraform apply.
  --post-deploy  Post-deploy: configure VLAN-tagged ports. Run AFTER terraform apply.

Options:
  --force        Remove existing bridge and recreate from scratch
  --post-deploy  Configure VLAN tagging on VM ports (run after terraform apply)
  --status       Show current OVS configuration and exit
  --help         Show this help message

VLAN Layout:
  VLAN 10 (Corporate): 10.10.10.0/24
  VLAN 20 (Servers):   10.10.20.0/24
  VLAN 30 (DMZ):       10.10.30.0/24

Port Configuration (--post-deploy):
  kali-scanner:    trunk (VM does own 802.1q tagging)
  debian-target:   trunk (VM does own 802.1q tagging)
  ubuntu-target:   trunk (VM does own 802.1q tagging)
  dmz-web:         tag=30 (access port, VLAN 30 only)
  windows-target:  tag=10 (access port, Windows can't do 802.1q)
  cisco-ios-sim:   trunk (VM does own 802.1q tagging, MAC 52:54:00:10:01:01)
  cisco-nexus-sim: trunk (VM does own 802.1q tagging, MAC 52:54:00:0f:01:01)

Note: VMs tag their own traffic via cloud-init 802.1q subinterfaces.
The --post-deploy step adds OVS-side enforcement for defense-in-depth.
EOF
}

# ── Root check ──────────────────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "This script requires root. Run with sudo or as root."
        exit 1
    fi
}

# ── Distibution detection ───────────────────────────────────────────────
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# ── Install OVS if not present ──────────────────────────────────────────
install_ovs() {
    if command -v ovs-vsctl >/dev/null 2>&1; then
        log "Open vSwitch utilities already installed"
        return 0
    fi

    warn "Open vSwitch not found. Attempting installation..."
    pkg_mgr="$(detect_pkg_manager)"

    case "$pkg_mgr" in
        apt)
            apt-get update -qq
            apt-get install -y -qq openvswitch-switch
            ;;
        dnf)
            dnf install -y openvswitch
            ;;
        pacman)
            pacman -Sy --noconfirm openvswitch
            ;;
        *)
            err "Unsupported package manager. Install openvswitch manually."
            err "  apt:  apt-get install openvswitch-switch"
            err "  dnf:  dnf install openvswitch"
            err "  pacman: pacman -S openvswitch"
            exit 1
            ;;
    esac

    if ! command -v ovs-vsctl >/dev/null 2>&1; then
        err "OVS installation failed. Install manually and re-run."
        exit 1
    fi
    log "Open vSwitch installed successfully"
}

# ── Load kernel modules ─────────────────────────────────────────────────
load_modules() {
    for mod in openvswitch vhost_net; do
        if ! lsmod | grep -q "^${mod}"; then
            if modprobe "$mod" 2>/dev/null; then
                log "Loaded kernel module: $mod"
            else
                warn "Could not load kernel module: $mod (may already be built-in)"
            fi
        fi
    done
}

# ── Start OVS services ──────────────────────────────────────────────────
start_services() {
    _started=false

    # Try systemd with all known service name variants
    if command -v systemctl >/dev/null 2>&1; then
        # Arch: ovsdb-server + ovs-vswitchd (separate units)
        # Debian/Ubuntu: openvswitch-switch (single unit)
        # RHEL/Fedora: openvswitch (single unit)
        for _svc in ovsdb-server openvswitch-switch openvswitch; do
            if systemctl cat "${_svc}.service" >/dev/null 2>&1; then
                systemctl enable "${_svc}.service" 2>/dev/null || true
                if systemctl start "${_svc}.service" 2>/dev/null; then
                    log "Started systemd service: ${_svc}"
                    _started=true
                fi
            fi
        done

        # On distros with separate ovs-vswitchd unit (Arch), start it too
        if systemctl cat ovs-vswitchd.service >/dev/null 2>&1; then
            systemctl enable ovs-vswitchd.service 2>/dev/null || true
            systemctl start ovs-vswitchd.service 2>/dev/null && \
                log "Started systemd service: ovs-vswitchd"
        fi
    fi

    # If systemd didn't work, try ovs-ctl directly
    if [ "$_started" = "false" ] && command -v ovs-ctl >/dev/null 2>&1; then
        log "Trying ovs-ctl to start daemons..."
        ovs-ctl start 2>/dev/null || true
    fi

    # Wait for the database socket to become available
    _socket="/run/openvswitch/db.sock"
    _retries=0
    log "Waiting for OVS database socket..."
    while [ ! -S "$_socket" ]; do
        _retries=$((_retries + 1))
        if [ "$_retries" -gt 15 ]; then
            err "OVS database socket not found at $_socket after 15 seconds"
            err "The OVS daemons may have failed to start. Check:"
            err "  systemctl status ovsdb-server"
            err "  systemctl status ovs-vswitchd"
            err "  journalctl -u ovsdb-server --since '1 min ago'"
            exit 1
        fi
        sleep 1
    done
    log "OVS database socket is ready"

    # Give vswitchd a moment to connect to the database
    sleep 1
}

# ── Bridge management ───────────────────────────────────────────────────
bridge_exists() {
    ovs-vsctl br-exists "$BRIDGE" 2>/dev/null
}

create_bridge() {
    if bridge_exists; then
        log "Bridge $BRIDGE already exists"
        return 0
    fi
    log "Creating OVS bridge: $BRIDGE"
    ovs-vsctl add-br "$BRIDGE"
    log "Bridge $BRIDGE created"
}

remove_bridge() {
    if ! bridge_exists; then
        info "Bridge $BRIDGE does not exist, nothing to remove"
        return 0
    fi
    warn "Removing existing bridge: $BRIDGE and all ports"
    ovs-vsctl del-br "$BRIDGE"
    log "Bridge removed"
}

# ── Port configuration ──────────────────────────────────────────────────
# Check if a port already exists with the expected configuration.
# Returns 0 if port exists and is correctly configured.
port_configured() {
    _port="$1"
    _expected="$2"

    if ! ovs-vsctl br-exists "$BRIDGE" 2>/dev/null; then
        return 1
    fi

    # Check port exists on bridge
    if ! ovs-vsctl list-ports "$BRIDGE" 2>/dev/null | grep -q "^${_port}$"; then
        return 1
    fi

    # Check the interface options match
    _current="$(ovs-vsctl get interface "$_port" options 2>/dev/null || echo "{}")"
    if [ "$_current" = "$_expected" ]; then
        return 0
    fi
    return 1
}

# Add or update a port by MAC address.
# Looks up the OVS port name from the MAC, then configures VLAN tagging.
# Skips silently if no port has the given MAC (VM not started yet).
configure_port_by_mac() {
    _mac="$1"
    _tag="$2"
    _trunks="$3"

    # Find which port on the bridge has this MAC
    _port=""
    for _p in $(ovs-vsctl list-ports "$BRIDGE" 2>/dev/null); do
        _p_mac="$(ovs-vsctl get interface "$_p" external_ids:attached-mac 2>/dev/null | tr -d '\"')"
        if [ "$_p_mac" = "$_mac" ]; then
            _port="$_p"
            break
        fi
    done

    if [ -z "$_port" ]; then
        warn "No OVS port found with MAC $_mac (VM may not be running)"
        return 0
    fi

    # Clear existing VLAN config
    ovs-vsctl set port "$_port" tag=0 trunks=[] 2>/dev/null || true

    # Apply new config
    if [ -n "$_tag" ]; then
        ovs-vsctl set port "$_port" tag="$_tag"
        log "Port $_port ($_mac): native VLAN $_tag"
    fi
    if [ -n "$_trunks" ]; then
        # Convert comma-separated to space-separated for OVS
        _trunk_list="$(echo "$_trunks" | sed 's/,/ /g')"
        ovs-vsctl set port "$_port" trunks="$_trunk_list"
        log "Port $_port ($_mac): trunk VLANs $_trunks"
    fi
}

configure_all_ports() {
    log "Configuring VLAN-tagged ports by MAC address..."

    # Kali scanner: VM does its own 802.1q tagging, no OVS config needed
    # configure_port_by_mac "52:54:00:0a:01:01" "" "10,20,30"

    # Debian target: VM does its own 802.1q tagging, no OVS config needed
    # configure_port_by_mac "52:54:00:0b:01:01" "" "10,20"

    # Ubuntu target: VM does its own 802.1q tagging, no OVS config needed
    # configure_port_by_mac "52:54:00:0c:01:01" "" "10,20"

    # DMZ web server: access port on VLAN 30 only
    configure_port_by_mac "52:54:00:0d:01:01" "30" ""

    # Windows target: access port on VLAN 10 (Windows doesn't do 802.1q tagging)
    configure_port_by_mac "52:54:00:0e:01:01" "10" ""

    # Cisco IOS sim: VM does its own 802.1q tagging, no OVS config needed
    # configure_port_by_mac "52:54:00:10:01:01" "" ""

    # Cisco Nexus sim: VM does its own 802.1q tagging, no OVS config needed
    # configure_port_by_mac "52:54:00:0f:01:01" "" ""

    log "All ports configured"
}

# ── LLDP configuration ──────────────────────────────────────────────────
enable_lldp() {
    log "Enabling LLDP on all OVS ports..."

    if ! bridge_exists; then
        err "Bridge $BRIDGE does not exist"
        return 1
    fi

    for _port in $(ovs-vsctl list-ports "$BRIDGE" 2>/dev/null); do
        _lldp_status="$(ovs-vsctl get interface "$_port" lldp:enable 2>/dev/null || echo "false")"
        if [ "$_lldp_status" != "true" ]; then
            ovs-vsctl set interface "$_port" lldp:enable=true 2>/dev/null || {
                warn "Could not enable LLDP on $_port (OVS version may not support it)"
                continue
            }
            log "LLDP enabled on $_port"
        else
            log "LLDP already enabled on $_port"
        fi
    done
}

# ── Status display ──────────────────────────────────────────────────────
show_status() {
    printf "\n=== Open vSwitch Status ===\n\n"

    if ! command -v ovs-vsctl >/dev/null 2>&1; then
        err "ovs-vsctl not found. OVS may not be installed."
        exit 1
    fi

    if ! bridge_exists; then
        warn "Bridge $BRIDGE does not exist"
        printf "\nAvailable bridges:\n"
        ovs-vsctl list-br 2>/dev/null || printf "  (none)\n"
        exit 0
    fi

    printf "Bridge: %s\n" "$BRIDGE"
    printf "Ports:\n"
    ovs-vsctl list-ports "$BRIDGE" 2>/dev/null | while read -r _port; do
        _tag="$(ovs-vsctl get port "$_port" tag 2>/dev/null || echo "[]")"
        _trunks="$(ovs-vsctl get port "$_port" trunks 2>/dev/null || echo "[]")"
        _lldp="$(ovs-vsctl get interface "$_port" lldp:enable 2>/dev/null || echo "N/A")"
        printf "  %-20s tag=%-8s trunks=%-16s lldp=%s\n" "$_port" "$_tag" "$_trunks" "$_lldp"
    done

    printf "\nOVS Version: %s\n" "$(ovs-vsctl --version 2>/dev/null | head -1)"
    printf "\n"
    exit 0
}

# ── Main ────────────────────────────────────────────────────────────────
main() {
    _force=0
    _status=0
    _post_deploy=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --force)       _force=1 ;;
            --post-deploy) _post_deploy=1 ;;
            --status)      _status=1 ;;
            --help|-h)     usage ;;
            *)
                err "Unknown option: $1"
                usage
                ;;
        esac
        shift
    done

    check_root

    if [ "$_status" -eq 1 ]; then
        show_status
    fi

    install_ovs
    load_modules
    start_services

    if [ "$_force" -eq 1 ]; then
        remove_bridge
    fi

    create_bridge

    if [ "$_post_deploy" -eq 1 ]; then
        configure_all_ports
        enable_lldp
        printf "\n"
        log "OVS post-deploy setup complete. Bridge: $BRIDGE"
    else
        printf "\n"
        log "OVS bridge created: $BRIDGE"
        info "Run '$0 --post-deploy' after terraform apply to configure VLAN tagging"
        info "Run '$0 --status' to verify configuration"
    fi
}

main "$@"