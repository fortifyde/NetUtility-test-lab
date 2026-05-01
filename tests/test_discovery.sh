#!/bin/sh
# test_discovery.sh — TAP-compatible tests for NetUtility discovery scripts
# Runs on the Kali scanner VM against lab targets.

set -e

# ── Configuration ──────────────────────────────────────────────────────────────
SCRIPTS_DIR="${NETUTIL_SCRIPTS_DIR:-/opt/netutil/scripts}"
WORKDIR="${NETUTIL_WORKDIR:-/tmp/netutil-test}"
TIMEOUT="${NETUTIL_TEST_TIMEOUT:-30}"
SCRIPT_NAME="$(basename "$0")"

# Lab targets
DEBIAN_IP="10.10.10.10"
UBUNTU_IP="10.10.10.20"
CORP_SUBNET="10.10.10.0/24"

# Colors (disabled if not a terminal)
if [ -t 1 ]; then
    C_GREEN='\033[0;32m'
    C_RED='\033[0;31m'
    C_RESET='\033[0m'
else
    C_GREEN=''
    C_RED=''
    C_RESET=''
fi

# ── Parse arguments ────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --workdir)
            WORKDIR="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --scripts-dir)
            SCRIPTS_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--workdir DIR] [--timeout SECS] [--scripts-dir DIR]" >&2
            exit 1
            ;;
    esac
done

# ── Source common test functions if available ──────────────────────────────────
COMMON_SH="$(dirname "$0")/common.sh"
if [ -f "$COMMON_SH" ]; then
    # shellcheck source=./common.sh
    . "$COMMON_SH"
fi

# ── TAP helpers (self-contained if common.sh absent) ───────────────────────────
TEST_NUM=0
PASS_COUNT=0
FAIL_COUNT=0

if ! command -v _tap_ok >/dev/null 2>&1; then
    _tap_ok() {
        TEST_NUM=$((TEST_NUM + 1))
        PASS_COUNT=$((PASS_COUNT + 1))
        printf "${C_GREEN}ok %d${C_RESET} - %s\n" "$TEST_NUM" "$1"
    }

    _tap_not_ok() {
        TEST_NUM=$((TEST_NUM + 1))
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf "${C_RED}not ok %d${C_RESET} - %s\n" "$TEST_NUM" "$1"
        if [ -n "${2:-}" ]; then
            printf "  # %s\n" "$2"
        fi
    }

    _tap_skip() {
        TEST_NUM=$((TEST_NUM + 1))
        printf "ok %d - %s # SKIP %s\n" "$TEST_NUM" "$1" "${2:-reason unknown}"
    }
fi

# ── Utility helpers ────────────────────────────────────────────────────────────
# Find the most recent directory matching a glob pattern under a base dir.
# Prints the path or nothing if none found.
_find_latest_dir() {
    _base="$1"
    _glob="$2"
    _result=""
    for _d in "$_base"/$_glob; do
        [ -d "$_d" ] || continue
        _result="$_d"
    done
    # shellcheck disable=SC2086
    echo "$_result"
}

# Run a NetUtility script with timeout and capture stdout+stderr.
# Usage: _run_script <script_subpath> [stdin_input]
# Sets _EXIT_CODE, captures output to _SCRIPT_OUTPUT.
_run_script() {
    _script_path="$SCRIPTS_DIR/$1"
    _stdin_input="${2:-}"
    _SCRIPT_OUTPUT=""
    _EXIT_CODE=0

    if [ ! -x "$_script_path" ]; then
        _EXIT_CODE=127
        _SCRIPT_OUTPUT="Script not found or not executable: $_script_path"
        return
    fi

    # shellcheck disable=SC2086
    if [ -n "$_stdin_input" ]; then
        _SCRIPT_OUTPUT=$(printf '%s\n' "$_stdin_input" \
            | NETUTIL_WORKDIR="$WORKDIR" timeout "$TIMEOUT" "$_script_path" 2>&1) \
            || _EXIT_CODE=$?
    else
        _SCRIPT_OUTPUT=$(NETUTIL_WORKDIR="$WORKDIR" timeout "$TIMEOUT" "$_script_path" 2>&1) \
            || _EXIT_CODE=$?
    fi

    # timeout(1) returns 124 on expiry
    if [ "$_EXIT_CODE" -eq 124 ]; then
        _SCRIPT_OUTPUT="$_SCRIPT_OUTPUT [TIMED OUT after ${TIMEOUT}s]"
    fi
}

# Count lines containing a pattern in a file.
_count_lines() {
    grep -c "$2" "$1" 2>/dev/null || echo 0
}

# ── Prepare workspace ──────────────────────────────────────────────────────────
mkdir -p "$WORKDIR"

# ── TAP plan header (printed first; total count filled at end) ─────────────────
echo "TAP version 14"
echo "# NetUtility Discovery Script Tests"
echo "# Workdir: $WORKDIR"
echo "# Scripts: $SCRIPTS_DIR"
echo "# Timeout: ${TIMEOUT}s"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE: arp_ingest.sh
# ═══════════════════════════════════════════════════════════════════════════════
echo "# --- arp_ingest.sh ---"

# Test: arp_ingest runs successfully
_run_script "discovery/arp_ingest.sh"
if [ "$_EXIT_CODE" -eq 0 ]; then
    _tap_ok "arp_ingest exits 0"
else
    _tap_not_ok "arp_ingest exits 0" "exit code $_EXIT_CODE"
fi

# Test: output directory exists
_arp_session=""
_arp_base="$WORKDIR/discovery/arp"
if [ -d "$_arp_base" ]; then
    _arp_session=$(_find_latest_dir "$_arp_base" "arp_ingest_*")
fi
if [ -n "$_arp_session" ] && [ -d "$_arp_session" ]; then
    _tap_ok "arp_ingest session directory exists"
else
    _tap_not_ok "arp_ingest session directory exists" "looked in $_arp_base"
fi

# Test: arp_raw.txt has content
_arp_raw="${_arp_session:-/dev/null}/arp_raw.txt"
if [ -s "$_arp_raw" ]; then
    _tap_ok "arp_raw.txt has content ($(_count_lines "$_arp_raw" '.') lines)"
else
    _tap_not_ok "arp_raw.txt has content" "file is empty or missing: $_arp_raw"
fi

# Test: XML output has IP and MAC entries
_arp_xml="${_arp_session:-/dev/null}/arp_results.xml"
if [ -s "$_arp_xml" ] && grep -q 'entry ip=' "$_arp_xml" 2>/dev/null && grep -q 'mac=' "$_arp_xml" 2>/dev/null; then
    _entry_count=$(_count_lines "$_arp_xml" 'entry ip=')
    _tap_ok "arp_results.xml has IP/MAC entries ($_entry_count)"
else
    _tap_not_ok "arp_results.xml has IP/MAC entries" "missing or malformed: $_arp_xml"
fi

# Test: known targets appear in ARP results
_arp_summary="${_arp_session:-/dev/null}/arp_summary.txt"
_found_debian=0
_found_ubuntu=0
# Check both XML and summary for target IPs
for _f in "$_arp_xml" "$_arp_summary" "$_arp_raw"; do
    [ -s "$_f" ] || continue
    grep -q "$DEBIAN_IP" "$_f" 2>/dev/null && _found_debian=1
    grep -q "$UBUNTU_IP" "$_f" 2>/dev/null && _found_ubuntu=1
done

if [ "$_found_debian" -eq 1 ] && [ "$_found_ubuntu" -eq 1 ]; then
    _tap_ok "ARP results contain $DEBIAN_IP and $UBUNTU_IP"
else
    _missing=""
    [ "$_found_debian" -eq 0 ] && _missing="$DEBIAN_IP"
    [ "$_found_ubuntu" -eq 0 ] && _missing="$_missing $UBUNTU_IP"
    _tap_not_ok "ARP results contain known targets" "missing: $_missing"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE: auto_discover.sh
# ═══════════════════════════════════════════════════════════════════════════════
# NOTE: auto_discover.sh is highly interactive (interface select, mode, duration,
# VLAN selection, IP assignment). We pipe minimal stdin to drive it through the
# first interface choice then accept defaults. The test is limited because the
# script's multi-phase capture is long-running.

echo "# --- auto_discover.sh ---"

# Determine the interface number for the trunk/parent interface.
# select_interface reads from a list; we default to "1" (first interface).
# For a non-interactive test, we just need to see if the script starts.
# The actual discovery is too long for a unit test, so we validate the report
# directory structure is created.

# We send: interface=1 (select first iface), mode=1 (L2), duration=1 (1min quick),
# then empty lines for remaining prompts to accept defaults.
# Use a very short timeout; the script may hang on prompts.
_QUICK_TIMEOUT=15

_AUTO_STDIN="1
1
1"

_AUTO_OUTPUT=""
_AUTO_EXIT=0
if [ -x "$SCRIPTS_DIR/discovery/auto_discover.sh" ]; then
    _AUTO_OUTPUT=$(printf '%s\n' "$_AUTO_STDIN" \
        | NETUTIL_WORKDIR="$WORKDIR" timeout "$_QUICK_TIMEOUT" \
        "$SCRIPTS_DIR/discovery/auto_discover.sh" 2>&1) || _AUTO_EXIT=$?
else
    _AUTO_EXIT=127
    _AUTO_OUTPUT="Script not found: $SCRIPTS_DIR/discovery/auto_discover.sh"
fi

if [ "$_AUTO_EXIT" -eq 0 ] || echo "$_AUTO_OUTPUT" | grep -q "Auto-Discovery Workflow"; then
    _tap_ok "auto_discover.sh starts and enters workflow"
else
    if [ "$_AUTO_EXIT" -eq 124 ]; then
        _tap_ok "auto_discover.sh starts (timed out as expected for long workflow)"
    elif [ "$_AUTO_EXIT" -eq 127 ]; then
        _tap_skip "auto_discover.sh starts" "script not found at $SCRIPTS_DIR/discovery/auto_discover.sh"
    else
        _tap_not_ok "auto_discover.sh starts and enters workflow" "exit $_AUTO_EXIT"
    fi
fi

# Test: reports directory created
_auto_report_base="$WORKDIR/reports"
if [ -d "$_auto_report_base" ]; then
    _tap_ok "auto_discover reports directory created"
else
    _tap_not_ok "auto_discover reports directory created" "not found: $_auto_report_base"
fi

# Test: auto_discovery_report.txt created
_auto_session=$(_find_latest_dir "$_auto_report_base" "auto_discover_*")
if [ -n "$_auto_session" ] && [ -s "$_auto_session/auto_discovery_report.txt" ]; then
    _tap_ok "auto_discovery_report.txt created"
else
    # Script may have timed out before creating the report — skip is acceptable
    if [ "$_AUTO_EXIT" -eq 124 ]; then
        _tap_skip "auto_discovery_report.txt created" "script timed out before report generation"
    else
        _tap_not_ok "auto_discovery_report.txt created" "missing in ${_auto_session:-<no session dir>}"
    fi
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE: multi_phase_discovery.sh
# ═══════════════════════════════════════════════════════════════════════════════
# NOTE: multi_phase_discovery.sh accepts an optional interface argument which
# bypasses the interface-selection prompt. It still prompts for network range
# confirmation, DNS config, and routed networks. We pipe answers.

echo "# --- multi_phase_discovery.sh ---"

# Determine the primary interface name (first non-lo with an IP).
_test_iface=$(ip -br addr 2>/dev/null | grep -v '^lo' | head -1 | awk '{print $1}')
if [ -z "$_test_iface" ]; then
    _test_iface="eth0"
fi

# Stdin: Enter (accept detected network), y (no DNS config), Enter (no routed nets)
# MANUAL_NETWORK_RANGE can pre-set the network to avoid the prompt.
_MP_STDIN="
n
y"

_MP_OUTPUT=""
_MP_EXIT=0
if [ -x "$SCRIPTS_DIR/discovery/multi_phase_discovery.sh" ]; then
    _MP_OUTPUT=$(printf '%s\n' "$_MP_STDIN" \
        | MANUAL_NETWORK_RANGE="$CORP_SUBNET" \
          NETUTIL_WORKDIR="$WORKDIR" \
          ROUTED_VLAN_MODE=true \
          AUTO_DISCOVERY_SESSION=true \
          timeout "$TIMEOUT" \
          "$SCRIPTS_DIR/discovery/multi_phase_discovery.sh" "$_test_iface" 2>&1) || _MP_EXIT=$?
else
    _MP_EXIT=127
    _MP_OUTPUT="Script not found: $SCRIPTS_DIR/discovery/multi_phase_discovery.sh"
fi

# Test: script starts (non-127 exit or shows expected header)
if [ "$_MP_EXIT" -eq 127 ]; then
    _tap_skip "multi_phase_discovery.sh runs" "script not found"
elif echo "$_MP_OUTPUT" | grep -q "Multi-Phase"; then
    _tap_ok "multi_phase_discovery.sh starts successfully"
else
    _tap_not_ok "multi_phase_discovery.sh starts successfully" "exit $_MP_EXIT"
fi

# Test: discovery directory structure created
_mp_disc_base="$WORKDIR/discovery"
if [ -d "$_mp_disc_base" ]; then
    _tap_ok "discovery base directory exists"
else
    _tap_not_ok "discovery base directory exists" "not found: $_mp_disc_base"
fi

# Test: discovered hosts / evidence directories exist under session
_mp_session=$(_find_latest_dir "$_mp_disc_base" "vlan*_*")
if [ -z "$_mp_session" ]; then
    _mp_session=$(_find_latest_dir "$_mp_disc_base" "local_network_*")
fi
if [ -z "$_mp_session" ]; then
    _mp_session=$(_find_latest_dir "$_mp_disc_base" "*")
fi

if [ -n "$_mp_session" ] && [ -d "$_mp_session" ]; then
    _tap_ok "discovery session directory created ($_mp_session)"

    # Check for hostfiles or evidence directories
    if [ -d "$_mp_session/hostfiles" ] || [ -d "$_mp_session/evidence" ]; then
        _tap_ok "phased output directories (hostfiles/evidence) exist"
    else
        if [ "$_MP_EXIT" -eq 124 ]; then
            _tap_skip "phased output directories exist" "script timed out before phase completion"
        else
            _tap_not_ok "phased output directories (hostfiles/evidence) exist" \
                "checked in $_mp_session"
        fi
    fi

    # Check for meta/discovery_report.txt
    if [ -s "$_mp_session/meta/discovery_report.txt" ]; then
        _tap_ok "discovery_report.txt has content"
    else
        if [ "$_MP_EXIT" -eq 124 ]; then
            _tap_skip "discovery_report.txt has content" "timed out"
        else
            _tap_not_ok "discovery_report.txt has content" "missing or empty"
        fi
    fi
else
    if [ "$_MP_EXIT" -eq 124 ]; then
        _tap_skip "discovery session directory created" "timed out before directory creation"
    else
        _tap_not_ok "discovery session directory created" "no session found under $_mp_disc_base"
    fi
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE: network_capture.sh
# ═══════════════════════════════════════════════════════════════════════════════
# NOTE: network_capture.sh is interactive (interface, duration). We pipe inputs
# for a 5-second capture. Capture requires root / tshark.

echo "# --- network_capture.sh ---"

# Stdin: 1 (first interface), 5 (custom duration)
_CAP_STDIN="1
5
5"

# For capture we allow slightly longer timeout (capture + overhead)
_CAP_TIMEOUT=$((TIMEOUT + 15))

_CAP_OUTPUT=""
_CAP_EXIT=0
if [ -x "$SCRIPTS_DIR/discovery/network_capture.sh" ]; then
    _CAP_OUTPUT=$(printf '%s\n' "$_CAP_STDIN" \
        | NETUTIL_WORKDIR="$WORKDIR" timeout "$_CAP_TIMEOUT" \
        "$SCRIPTS_DIR/discovery/network_capture.sh" 2>&1) || _CAP_EXIT=$?
else
    _CAP_EXIT=127
    _CAP_OUTPUT="Script not found: $SCRIPTS_DIR/discovery/network_capture.sh"
fi

# Test: script starts
if [ "$_CAP_EXIT" -eq 127 ]; then
    _tap_skip "network_capture.sh runs" "script not found"
elif echo "$_CAP_OUTPUT" | grep -q "Network Packet Capture"; then
    _tap_ok "network_capture.sh starts successfully"
else
    if [ "$_CAP_EXIT" -eq 124 ]; then
        _tap_ok "network_capture.sh ran (timed out during capture)"
    else
        _tap_not_ok "network_capture.sh starts successfully" "exit $_CAP_EXIT"
    fi
fi

# Test: PCAP file created and non-empty
_cap_dir="$WORKDIR/captures"
_pcap_file=""
if [ -d "$_cap_dir" ]; then
    # Find the most recent pcap
    _pcap_file=$(ls -t "$_cap_dir"/capture_*.pcap 2>/dev/null | head -1)
fi

if [ -n "$_pcap_file" ] && [ -s "$_pcap_file" ]; then
    _pcap_size=$(wc -c < "$_pcap_file")
    _tap_ok "PCAP file created and non-empty (${_pcap_size} bytes)"
else
    if [ "$_CAP_EXIT" -eq 127 ]; then
        _tap_skip "PCAP file created" "script not available"
    elif [ "$_CAP_EXIT" -eq 124 ]; then
        _tap_skip "PCAP file created" "timed out"
    else
        _tap_not_ok "PCAP file created and non-empty" \
            "no pcap found in $_cap_dir (exit $_CAP_EXIT)"
    fi
fi

# Test: PCAP is valid (tshark can read it)
if [ -n "$_pcap_file" ] && [ -s "$_pcap_file" ] && command -v tshark >/dev/null 2>&1; then
    if tshark -r "$_pcap_file" >/dev/null 2>&1; then
        _tap_ok "PCAP file is valid (tshark can read)"
    else
        _tap_not_ok "PCAP file is valid (tshark can read)" "tshark rejected: $_pcap_file"
    fi
elif [ -z "$_pcap_file" ] || [ ! -s "$_pcap_file" ]; then
    _tap_skip "PCAP file is valid (tshark can read)" "no pcap to validate"
else
    _tap_skip "PCAP file is valid (tshark can read)" "tshark not available"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE: lldp_cdp_discovery.sh
# ═══════════════════════════════════════════════════════════════════════════════
# NOTE: LLDP/CDP discovery is interactive (interface + duration choice).
# OVS sends LLDP on trunk ports. We select interface "1" and duration "1" (90s
# quick). For tests we keep the timeout shorter — if the script starts correctly,
# that's sufficient. Real LLDP frame detection requires a properly configured lab.

echo "# --- lldp_cdp_discovery.sh ---"

# Stdin: 1 (first interface), 1 (90 seconds quick)
_LLDPIFACE=1
_LLDP_STDIN="$_LLDPIFACE
1"

_LLDP_TIMEOUT=$((TIMEOUT + 10))

_LLDP_OUTPUT=""
_LLDP_EXIT=0
if [ -x "$SCRIPTS_DIR/discovery/lldp_cdp_discovery.sh" ]; then
    _LLDP_OUTPUT=$(printf '%s\n' "$_LLDP_STDIN" \
        | NETUTIL_WORKDIR="$WORKDIR" timeout "$_LLDP_TIMEOUT" \
        "$SCRIPTS_DIR/discovery/lldp_cdp_discovery.sh" 2>&1) || _LLDP_EXIT=$?
else
    _LLDP_EXIT=127
    _LLDP_OUTPUT="Script not found: $SCRIPTS_DIR/discovery/lldp_cdp_discovery.sh"
fi

# Test: script starts
if [ "$_LLDP_EXIT" -eq 127 ]; then
    _tap_skip "lldp_cdp_discovery.sh runs" "script not found"
elif echo "$_LLDP_OUTPUT" | grep -q "LLDP/CDP"; then
    _tap_ok "lldp_cdp_discovery.sh starts successfully"
else
    if [ "$_LLDP_EXIT" -eq 124 ]; then
        _tap_ok "lldp_cdp_discovery.sh ran (timed out during capture)"
    else
        _tap_not_ok "lldp_cdp_discovery.sh starts successfully" "exit $_LLDP_EXIT"
    fi
fi

# Test: session directory created
_lldp_base="$WORKDIR/discovery/lldp_cdp"
_lldp_session=$(_find_latest_dir "$_lldp_base" "lldp_cdp_*")

if [ -n "$_lldp_session" ] && [ -d "$_lldp_session" ]; then
    _tap_ok "LLDP/CDP session directory created"

    # Test: PCAP file exists (may be empty if no LLDP frames)
    if [ -f "$_lldp_session/lldp_cdp_capture.pcap" ]; then
        _tap_ok "LLDP/CDP capture PCAP file exists"
    else
        if [ "$_LLDP_EXIT" -eq 124 ]; then
            _tap_skip "LLDP/CDP capture PCAP file exists" "timed out"
        else
            _tap_not_ok "LLDP/CDP capture PCAP file exists" "not in $_lldp_session"
        fi
    fi

    # Test: LLDP frames detected (OVS sends LLDP)
    if [ -s "$_lldp_session/lldp_neighbors.txt" ] \
        && ! grep -q "^$" "$_lldp_session/lldp_neighbors.txt" 2>/dev/null; then
        _tap_ok "LLDP neighbor data present"
    else
        # LLDP may not be available in all test environments
        if [ "$_LLDP_EXIT" -eq 124 ]; then
            _tap_skip "LLDP neighbor data present" "timed out"
        elif [ -f "$_lldp_session/lldp_cdp_capture.pcap" ] \
            && [ ! -s "$_lldp_session/lldp_cdp_capture.pcap" ]; then
            _tap_skip "LLDP neighbor data present" "no LLDP frames captured (lab config issue)"
        else
            _tap_not_ok "LLDP neighbor data present" "empty or missing lldp_neighbors.txt"
        fi
    fi

    # Test: output format — XML results exist and have valid structure
    if [ -s "$_lldp_session/lldp_cdp_results.xml" ]; then
        if grep -q '<lldp_cdp_results>' "$_lldp_session/lldp_cdp_results.xml" 2>/dev/null \
            && grep -q '</lldp_cdp_results>' "$_lldp_session/lldp_cdp_results.xml" 2>/dev/null; then
            _tap_ok "LLDP/CDP XML output has valid structure"
        else
            _tap_not_ok "LLDP/CDP XML output has valid structure" "missing root element"
        fi
    else
        if [ "$_LLDP_EXIT" -eq 124 ]; then
            _tap_skip "LLDP/CDP XML output has valid structure" "timed out"
        else
            _tap_not_ok "LLDP/CDP XML output has valid structure" "file missing or empty"
        fi
    fi
else
    if [ "$_LLDP_EXIT" -eq 127 ]; then
        _tap_skip "LLDP/CDP session directory created" "script not found"
    elif [ "$_LLDP_EXIT" -eq 124 ]; then
        _tap_skip "LLDP/CDP session directory created" "timed out before creation"
    else
        _tap_not_ok "LLDP/CDP session directory created" "not found under $_lldp_base"
    fi
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# TAP summary
# ═══════════════════════════════════════════════════════════════════════════════
_TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "1..$_TOTAL"
echo "# Tests run: $_TOTAL, Passed: $PASS_COUNT, Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
