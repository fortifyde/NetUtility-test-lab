#!/bin/sh
# demo-prep.sh — Pre-flight validation for NetUtility demo lab.
# Run once after lab-up.sh. Checks all VMs and services, prints presenter IP sheet.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"

if [ -t 1 ]; then
    GRN='\033[1;32m'; RED='\033[1;31m'; YEL='\033[1;33m'; CYN='\033[1;36m'; RST='\033[0m'
else
    GRN=''; RED=''; YEL=''; RST=''; CYN=''
fi

PASS=0; FAIL=0

ok()   { printf "${GRN}[PASS]${RST} %s\n" "$*"; PASS=$((PASS+1)); }
fail() { printf "${RED}[FAIL]${RST} %s\n" "$*"; FAIL=$((FAIL+1)); }
info() { printf "${CYN}[INFO]${RST} %s\n" "$*"; }
warn() { printf "${YEL}[WARN]${RST} %s\n" "$*"; }

cd "$LAB_DIR"

info "Reading Terraform outputs..."
if ! terraform output -raw kali_mgmt_ip >/dev/null 2>&1; then
    printf "${RED}ERROR:${RST} Cannot read Terraform outputs. Is the lab running?\n"
    exit 1
fi

KALI_IP=$(terraform output -raw kali_mgmt_ip)
DEBIAN_IP=$(terraform output -raw debian_mgmt_ip 2>/dev/null || true)
UBUNTU_IP=$(terraform output -raw ubuntu_mgmt_ip 2>/dev/null || true)
DMZ_IP=$(terraform output -raw dmz_mgmt_ip 2>/dev/null || true)
CISCO_IOS_IP=$(terraform output -raw cisco_ios_ip 2>/dev/null || echo "10.10.10.40")
CISCO_NEXUS_IP=$(terraform output -raw cisco_nexus_ip 2>/dev/null || echo "10.10.10.41")
# Terraform doesn't wait for the Windows DHCP lease; fall back to virsh domifaddr
WINDOWS_IP=$(terraform output -raw windows_mgmt_ip 2>/dev/null || true)
if [ -z "$WINDOWS_IP" ] || echo "$WINDOWS_IP" | grep -q "^DHCP"; then
    _lab=$(grep -E '^lab_name' terraform.tfvars 2>/dev/null | sed 's/.*"\(.*\)".*/\1/' || echo "netutil-lab")
    WINDOWS_IP=$(virsh -c qemu:///system domifaddr "${_lab}-windows" 2>/dev/null \
        | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1 || true)
fi

# Resolve SSH key from terraform.tfvars or default
SSH_KEY="$HOME/.ssh/id_rsa"
if [ -f terraform.tfvars ]; then
    _k=$(grep -E '^ssh_private_key_path' terraform.tfvars 2>/dev/null \
         | sed 's/.*"\(.*\)".*/\1/' | sed "s|^~|$HOME|" || true)
    [ -n "$_k" ] && SSH_KEY="$_k"
fi
# Use auto-generated key if no user key configured
if [ "$SSH_KEY" = "$HOME/.ssh/id_rsa" ] && [ ! -f "$SSH_KEY" ] && [ -f .lab-ssh-key ]; then
    SSH_KEY=".lab-ssh-key"
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
[ -f "$SSH_KEY" ] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

echo ""
echo "=== NetUtility Demo Lab Pre-flight Check ==="
echo ""

# ── 1. SSH connectivity (all VMs reachable via management network) ────────
info "Checking SSH connectivity..."

_ssh_ok() {
    _label="$1"; _user="$2"; _host="$3"
    if [ -z "$_host" ] || echo "$_host" | grep -q "^DHCP"; then
        fail "$_label — management IP not yet available (try again in a moment)"
        return
    fi
    if ssh $SSH_OPTS "${_user}@${_host}" "echo ok" >/dev/null 2>&1; then
        ok "$_label (${_user}@${_host})"
    else
        fail "$_label — SSH unreachable (${_user}@${_host})"
    fi
}

_ssh_ok "Kali scanner"  kali   "$KALI_IP"
_ssh_ok "debian-target" debian "$DEBIAN_IP"
_ssh_ok "ubuntu-target" ubuntu "$UBUNTU_IP"
_ssh_ok "dmz-web"       debian "$DMZ_IP"

# Windows: ping management IP, only if enabled
if grep -q 'enable_windows[[:space:]]*=[[:space:]]*true' terraform.tfvars 2>/dev/null; then
    if [ -z "$WINDOWS_IP" ] || echo "$WINDOWS_IP" | grep -q "^DHCP"; then
        fail "windows-target — management IP not yet available (try again in a moment)"
    elif ping -c 1 -W 3 "$WINDOWS_IP" >/dev/null 2>&1; then
        ok "windows-target reachable (ping $WINDOWS_IP)"
    else
        fail "windows-target unreachable (ping $WINDOWS_IP)"
    fi
fi

# ── 2. Traffic generation ────────────────────────────────────────────────
info "Checking netlab-traffic.service..."

_traffic_ok() {
    _host="$1"; _user="$2"; _label="$3"
    if [ -z "$_host" ] || echo "$_host" | grep -q "^DHCP"; then
        fail "netlab-traffic.service — management IP not available for $_label"
        return
    fi
    if ssh $SSH_OPTS "${_user}@${_host}" \
            "systemctl is-active netlab-traffic.service 2>/dev/null" \
            2>/dev/null | grep -q "^active"; then
        ok "netlab-traffic.service active on $_label ($_host)"
    else
        fail "netlab-traffic.service not active on $_label ($_host)"
    fi
}

_traffic_ok "$DEBIAN_IP" debian "debian-target"
_traffic_ok "$UBUNTU_IP" ubuntu "ubuntu-target"
_traffic_ok "$DMZ_IP"    debian "dmz-web"

# ── 3. Device simulators (checked via Kali → VLAN IP) ───────────────────
info "Checking device simulators (via Kali)..."

_sim_ok() {
    _label="$1"; _sim_ip="$2"
    _sim_try() {
        ssh $SSH_OPTS "kali@$KALI_IP" \
            "ssh \
                 -o StrictHostKeyChecking=no \
                 -o ConnectTimeout=8 \
                 -o BatchMode=yes \
                 admin@${_sim_ip} 'show version' 2>/dev/null" 2>/dev/null || true
    }
    _result=$(_sim_try)
    # Retry up to 3 times — device-sim may be mid-restart (RestartSec=5)
    _retry=0
    while [ -z "$_result" ] && [ "$_retry" -lt 3 ]; do
        _retry=$((_retry + 1))
        sleep 6
        _result=$(_sim_try)
    done
    if [ -n "$_result" ]; then
        ok "$_label responds to 'show version' (${_sim_ip})"
    else
        fail "$_label did not respond after 3 retries — check device-sim.service on ${_sim_ip}"
    fi
}

_sim_ok "cisco-ios-sim"   "$CISCO_IOS_IP"
_sim_ok "cisco-nexus-sim" "$CISCO_NEXUS_IP"

# ── 4. SNMP (management IPs — snmpd listens on all interfaces) ──────────
info "Checking SNMP on targets..."

if ! command -v snmpget >/dev/null 2>&1; then
    warn "snmpget not found — install net-snmp-utils for SNMP checks"
    warn "  Fedora: sudo dnf install net-snmp-utils"
    warn "  Debian/Ubuntu: sudo apt install snmp"
fi

_snmp_ok() {
    _host="$1"; _label="$2"
    if [ -z "$_host" ] || echo "$_host" | grep -q "^DHCP"; then
        fail "SNMP — management IP not available for $_label"
        return
    fi
    if ! command -v snmpget >/dev/null 2>&1; then
        warn "SNMP check skipped for $_label (snmpget not available)"
        return
    fi
    if snmpget -v2c -c public -t 2 -r 1 "$_host" \
            1.3.6.1.2.1.1.1.0 >/dev/null 2>&1; then
        ok "SNMP responding on $_label ($_host)"
    else
        fail "SNMP not responding on $_label ($_host)"
    fi
}

_snmp_ok "$DEBIAN_IP" "debian-target"
_snmp_ok "$UBUNTU_IP" "ubuntu-target"

# ── 5. Windows (WinRM probe, only if enabled) ────────────────────────────
if grep -q 'enable_windows[[:space:]]*=[[:space:]]*true' terraform.tfvars 2>/dev/null; then
    if [ -n "$WINDOWS_IP" ] && ! echo "$WINDOWS_IP" | grep -q "^DHCP"; then
        info "Checking Windows target ($WINDOWS_IP)..."
        # WinRM HTTP listener on port 5985 — probe with curl (no auth needed to detect the endpoint)
        if ssh $SSH_OPTS "kali@$KALI_IP" \
                "code=\$(curl -s -o /dev/null -w '%{http_code}' -m 5 --connect-timeout 5 http://${WINDOWS_IP}:5985/wsman) && [ \"\$code\" -ge 200 ] && [ \"\$code\" -lt 500 ]" \
                2>/dev/null; then
            ok "Windows WinRM endpoint reachable on ${WINDOWS_IP}:5985"
        else
            warn "Windows WinRM not reachable on ${WINDOWS_IP}:5985 — may still be installing"
            warn "Windows unattended install takes 20-30 minutes"
        fi
    fi
fi
# ── Summary ──────────────────────────────────────────────────────────────
echo ""
printf "=== Results: ${GRN}%d passed${RST}, ${RED}%d failed${RST} ===\n" "$PASS" "$FAIL"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo "=== Lab Ready for Demo ==="
    echo ""
    printf "  Kali Scanner:     ssh kali@%s\n" "$KALI_IP"
    echo   "  VLAN 10 targets:  10.10.10.10 (debian), 10.10.10.20 (ubuntu)"
    echo   "  VLAN 20 targets:  10.10.20.10 (debian), 10.10.20.20 (ubuntu)"
    echo   "  VLAN 30 targets:  10.10.30.10 (dmz-web)"
    printf  "  Cisco IOS sim:    %s (any credentials)\n" "$CISCO_IOS_IP"
    printf  "  Cisco Nexus sim:  %s (any credentials)\n" "$CISCO_NEXUS_IP"
    echo   ""
    echo   "  Run on Kali:      netutil"
    echo   "  Collect results:  ./scripts/collect-outputs.sh --auto"
else
    echo "Fix the above failures before starting the demo."
    exit 1
fi
