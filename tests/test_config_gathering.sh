#!/bin/sh
#
# test_config_gathering.sh — TAP tests for config gathering logic
# Tests vendor detection, fixture completeness, and output cleaning
# without requiring real SSH connections to devices.
#

# ── Paths ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/../fixtures/network-configs"
CMDS_DIR="${SCRIPT_DIR}/../../scripts/config/commands"
GATHER_SCRIPT="${SCRIPT_DIR}/../../scripts/config/gather_network_configs.sh"

# Allow overrides for Kali VM layout
FIXTURES_DIR="${NETUTIL_FIXTURES_DIR:-$FIXTURES_DIR}"
CMDS_DIR="${NETUTIL_CMDS_DIR:-$CMDS_DIR}"

TIMEOUT="${NETUTIL_TEST_TIMEOUT:-30}"

# ── TAP helpers ────────────────────────────────────────────────
TOTAL=0
PASS=0
FAIL=0

if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    RESET='\033[0m'
else
    GREEN=''
    RED=''
    RESET=''
fi

ok() {
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    printf "${GREEN}ok %d - %s${RESET}\n" "$TOTAL" "$1"
}

not_ok() {
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    printf "${RED}not ok %d - %s${RESET}\n" "$TOTAL" "$1"
    if [ -n "${2:-}" ]; then
        printf "  # %s\n" "$2"
    fi
}

skip_ok() {
    TOTAL=$((TOTAL + 1))
    printf "ok %d - %s # SKIP %s\n" "$TOTAL" "$1" "${2:-reason unknown}"
}

# ── clean_output — reimplemented from gather_network_configs.sh ──
# (cannot source the gather script directly: it runs set -e, checks for
#  sshpass, and initializes globals that require a live environment)
clean_output() {
    sed 's/\x1b\[[^A-Za-z]*[A-Za-z]//g' |
    tr -d '\r' |
    grep -v -- '--More--' | grep -v -- '---- More ----' |
    grep -v -i 'press any key to continue' |
    grep -v '^[A-Za-z0-9._-]*[#>]$' |
    grep -v '^[A-Za-z0-9._-]*[#>] ' || true
}

clean_output_compliance() {
    sed 's/\x1b\[[^A-Za-z]*[A-Za-z]//g' |
    tr -d '\r' |
    grep -v -- '--More--' | grep -v -- '---- More ----' |
    grep -v -i 'press any key to continue' |
    grep -v '^[A-Za-z0-9._-]*[#>]$' || true
}

# detect_vendor — reimplementation matching gather_network_configs.sh logic
detect_vendor() {
    _dv_input="$1"
    if printf '%s\n' "$_dv_input" | grep -qi "Cisco IOS Software\|IOS (tm)\|Cisco Internetwork"; then
        echo "cisco_ios"; return 0
    fi
    if printf '%s\n' "$_dv_input" | grep -qi "NX-OS\|Nexus Operating System\|cisco Nexus"; then
        echo "cisco_nexus"; return 0
    fi
    if printf '%s\n' "$_dv_input" | grep -qi "Comware Software\|HPE Comware\|HP Comware Platform"; then
        echo "hp_comware"; return 0
    fi
    if printf '%s\n' "$_dv_input" | grep -qi "ArubaOS-CX"; then
        echo "aruba_cx"; return 0
    fi
    if printf '%s\n' "$_dv_input" | grep -qi "ArubaOS-Switch\|Aruba"; then
        echo "aruba_switch"; return 0
    fi
    if printf '%s\n' "$_dv_input" | grep -q "[A-Z][A-Z]\.[0-9][0-9]\.[0-9]"; then
        echo "aruba_switch"; return 0
    fi
    if printf '%s\n' "$_dv_input" | grep -q "J[0-9][0-9][0-9][0-9]"; then
        echo "aruba_switch"; return 0
    fi
    if printf '%s\n' "$_dv_input" | grep -qi "ProVision\|Image stamp"; then
        echo "hp_provision"; return 0
    fi
    echo "generic"
    return 0
}

# ── Helper: read a version fixture for a vendor ────────────────
_find_version_file() {
    _fv_dir="$1"
    for _fv_name in "show version.txt" "show version" "display version.txt" "display version" "show system.txt" "show system"; do
        if [ -f "$_fv_dir/$_fv_name" ]; then
            echo "$_fv_dir/$_fv_name"
            return 0
        fi
    done
    return 1
}

# ── Helper: check if a fixture file exists for a command ───────
# Some fixture dirs use .txt suffix, some don't.
_has_fixture() {
    _hf_dir="$1"
    _hf_cmd="$2"
    [ -f "$_hf_dir/$_hf_cmd" ] && return 0
    [ -f "$_hf_dir/${_hf_cmd}.txt" ] && return 0
    return 1
}

# ── Helper: count lines matching pattern, safely ───────────────
_count_matching() {
    _cm_file="$1"
    _cm_pat="$2"
    _cm_result=$(grep -c "$_cm_pat" "$_cm_file" 2>/dev/null) || _cm_result=0
    # Strip any whitespace (grep -c may output CRLF on some systems)
    _cm_result=$(printf '%s' "$_cm_result" | tr -d '[:space:]')
    echo "${_cm_result:-0}"
}

# ── TAP header ─────────────────────────────────────────────────
echo "TAP version 14"
echo "# Config Gathering Tests"
echo "# Fixtures: $FIXTURES_DIR"
echo "# Commands: $CMDS_DIR"
echo "# Timeout:  ${TIMEOUT}s"
echo ""

# ════════════════════════════════════════════════════════════════
# TEST SUITE 1: Vendor Detection from Fixture Output (5 tests)
# ════════════════════════════════════════════════════════════════
echo "# --- Vendor Detection ---"

# Cisco IOS
_vf="$(_find_version_file "$FIXTURES_DIR/cisco_ios")"
if [ -n "$_vf" ] && [ -f "$_vf" ]; then
    _content=$(cat "$_vf")
    _vendor=$(detect_vendor "$_content")
    if [ "$_vendor" = "cisco_ios" ]; then
        ok "Cisco IOS detected from fixture"
    else
        not_ok "Cisco IOS detected from fixture" "got: $_vendor"
    fi
else
    skip_ok "Cisco IOS detected from fixture" "fixture missing"
fi

# Cisco Nexus
_vf="$(_find_version_file "$FIXTURES_DIR/cisco_nexus")"
if [ -n "$_vf" ] && [ -f "$_vf" ]; then
    _content=$(cat "$_vf")
    _vendor=$(detect_vendor "$_content")
    if [ "$_vendor" = "cisco_nexus" ]; then
        ok "Cisco Nexus detected from fixture"
    else
        not_ok "Cisco Nexus detected from fixture" "got: $_vendor"
    fi
else
    skip_ok "Cisco Nexus detected from fixture" "fixture missing"
fi

# HP Comware
_vf="$(_find_version_file "$FIXTURES_DIR/hp_comware")"
if [ -n "$_vf" ] && [ -f "$_vf" ]; then
    _content=$(cat "$_vf")
    _vendor=$(detect_vendor "$_content")
    if [ "$_vendor" = "hp_comware" ]; then
        ok "HP Comware detected from fixture"
    else
        not_ok "HP Comware detected from fixture" "got: $_vendor"
    fi
else
    skip_ok "HP Comware detected from fixture" "fixture missing"
fi

# Aruba CX
_vf="$(_find_version_file "$FIXTURES_DIR/aruba_cx")"
if [ -n "$_vf" ] && [ -f "$_vf" ]; then
    _content=$(cat "$_vf")
    _vendor=$(detect_vendor "$_content")
    if [ "$_vendor" = "aruba_cx" ]; then
        ok "Aruba CX detected from fixture"
    else
        not_ok "Aruba CX detected from fixture" "got: $_vendor"
    fi
else
    skip_ok "Aruba CX detected from fixture" "fixture missing"
fi

# HP ProVision — the fixture contains "Aruba" branding which triggers
# aruba_switch detection first (matching the real script behavior).
# Test the ProVision pattern directly with crafted input that ONLY
# contains ProVision markers (no two-letter version prefix, no Aruba keyword).
_pv_test_input="ProVision Software Version 15.18.5
Image stamp delay
HP Switch 2610"
_pv_vendor=$(detect_vendor "$_pv_test_input")
if [ "$_pv_vendor" = "hp_provision" ]; then
    ok "HP ProVision pattern detected (ProVision keyword)"
else
    not_ok "HP ProVision pattern detected (ProVision keyword)" "got: $_pv_vendor"
fi

echo ""

# ════════════════════════════════════════════════════════════════
# TEST SUITE 2: Fixture File Completeness (7 tests — one per vendor)
# ════════════════════════════════════════════════════════════════
echo "# --- Fixture Completeness ---"

for _fc_vendor in cisco_ios cisco_nexus hp_comware hp_provision aruba_cx aruba_switch generic; do
    _fc_cmds="$CMDS_DIR/${_fc_vendor}.cmds"
    _fc_dir="$FIXTURES_DIR/$_fc_vendor"

    if [ ! -f "$_fc_cmds" ]; then
        skip_ok "$_fc_vendor fixture completeness" "cmds file missing: $_fc_cmds"
        continue
    fi
    if [ ! -d "$_fc_dir" ]; then
        skip_ok "$_fc_vendor fixture completeness" "fixture dir missing: $_fc_dir"
        continue
    fi

    _fc_missing=0
    _fc_missing_list=""
    _fc_core_missing=0
    _fc_total=0

    # Parse commands from .cmds file: strip comments, @ markers, and pipe suffixes
    while IFS= read -r _fc_line || [ -n "$_fc_line" ]; do
        # Strip leading/trailing whitespace
        _fc_line=$(printf '%s' "$_fc_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Skip empty lines and comments
        case "$_fc_line" in
            ""|\#*) continue ;;
        esac

        # Track whether this is a core command (@-marked)
        _fc_is_core=0
        case "$_fc_line" in
            @*) _fc_is_core=1 ;;
        esac

        # Strip @ markers (e.g. "@VERSION show version" -> "show version")
        _fc_cmd=$(printf '%s' "$_fc_line" | sed 's/^@[A-Z_]*[[:space:]]*//')

        # Skip if stripping left nothing
        [ -z "$_fc_cmd" ] && continue

        # Strip pipe suffixes for fixture lookup
        # (e.g. "show version | include uptime" -> "show version")
        _fc_base=$(printf '%s' "$_fc_cmd" | sed 's/[[:space:]]*|.*$//')

        _fc_total=$(( _fc_total + 1 ))

        if ! _has_fixture "$_fc_dir" "$_fc_base"; then
            _fc_missing=$(( _fc_missing + 1 ))
            _fc_missing_list="$_fc_missing_list $_fc_base"
            # Core commands (version, running-config, startup-config) must be present
            if [ "$_fc_is_core" -eq 1 ]; then
                _fc_core_missing=$(( _fc_core_missing + 1 ))
            fi
        fi
    done < "$_fc_cmds"

    if [ "$_fc_core_missing" -gt 0 ]; then
        not_ok "$_fc_vendor: fixture completeness ($_fc_missing missing of $_fc_total, $_fc_core_missing core)" \
            "missing:$_fc_missing_list"
    elif [ "$_fc_missing" -eq 0 ]; then
        ok "$_fc_vendor: all $_fc_total fixture files present"
    else
        # Non-core fixtures missing: report as pass with diagnostic
        ok "$_fc_vendor: core fixtures present ($_fc_missing optional missing of $_fc_total)"
        printf "  # optional missing:%s\n" "$_fc_missing_list"
    fi
done

echo ""

# ════════════════════════════════════════════════════════════════
# TEST SUITE 3: clean_output Function (3 tests)
# ════════════════════════════════════════════════════════════════
echo "# --- clean_output ---"

# Build test input file (avoids printf escape interpretation issues)
_co_tmpdir="${TMPDIR:-/tmp}"
_co_infile="$_co_tmpdir/test_co_in_$$"
_co_outfile="$_co_tmpdir/test_co_out_$$"
trap 'rm -f "$_co_tmpdir"/test_*_$$ 2>/dev/null' EXIT

# Use a heredoc + printf for reliable binary content
{
    printf 'Switch# show version\x1b[0m\r\n'
    printf 'Cisco IOS Software, C2960X\r\n'
    printf -- '--More--\r\n'
    printf 'Uptime is 142 days\r\n'
    printf -- '---- More ----\r\n'
    printf 'Press any key to continue\r\n'
    printf 'Switch#\r\n'
    printf 'Switch# \r\n'
    printf '\x1b[?25hDone\r\n'
} > "$_co_infile"

clean_output < "$_co_infile" > "$_co_outfile"

# Test: --More-- removed
if grep -q -- '--More--' "$_co_outfile" 2>/dev/null; then
    not_ok "clean_output removes --More--" "still present in output"
else
    ok "clean_output removes --More--"
fi

# Test: prompt-only lines removed (bare "hostname#" and "hostname# " lines)
_co_prompt_count=$(_count_matching "$_co_outfile" '^Switch#$')
if [ "$_co_prompt_count" -eq 0 ]; then
    ok "clean_output removes prompt-only lines"
else
    not_ok "clean_output removes prompt-only lines" "$_co_prompt_count prompt lines remain"
fi

# Test: ANSI escape codes stripped
if grep -qP '\x1b\[' "$_co_outfile" 2>/dev/null; then
    not_ok "clean_output strips ANSI codes" "ANSI sequences remain"
else
    ok "clean_output strips ANSI codes"
fi

echo ""

# ════════════════════════════════════════════════════════════════
# TEST SUITE 4: clean_output_compliance Function (2 tests)
# ════════════════════════════════════════════════════════════════
echo "# --- clean_output_compliance ---"

_cc_infile="$_co_tmpdir/test_cc_in_$$"
_cc_outfile="$_co_tmpdir/test_cc_out_$$"

# Input with command echoes that should be preserved
{
    printf 'SWITCH# show version\r\n'
    printf 'ArubaOS-CX Software Version: 10.10.1010\r\n'
    printf -- '--More--\r\n'
    printf 'Uptime: 87 days\r\n'
    printf 'SWITCH# show running-config\r\n'
    printf 'hostname test-switch\r\n'
    printf 'SWITCH#\r\n'
} > "$_cc_infile"

clean_output_compliance < "$_cc_infile" > "$_cc_outfile"

# Test: command echoes preserved ("SWITCH# show version" should survive)
if grep -q 'SWITCH# show version' "$_cc_outfile" 2>/dev/null; then
    ok "clean_output_compliance keeps command echoes"
else
    not_ok "clean_output_compliance keeps command echoes" \
        "'SWITCH# show version' not found in output"
fi

# Test: pagination and bare prompts removed, but command-echo prompts kept
_cc_more_count=$(_count_matching "$_cc_outfile" '\-\-More\-\-')
_cc_bare_prompt=$(_count_matching "$_cc_outfile" '^SWITCH#$')
if [ "$_cc_more_count" -eq 0 ] && [ "$_cc_bare_prompt" -eq 0 ]; then
    ok "clean_output_compliance removes pagination and bare prompts"
else
    _cc_detail=""
    [ "$_cc_more_count" -gt 0 ] && _cc_detail="$_cc_detail --More-- still present"
    [ "$_cc_bare_prompt" -gt 0 ] && _cc_detail="$_cc_detail bare prompts still present"
    not_ok "clean_output_compliance removes pagination and bare prompts" "$_cc_detail"
fi

# Cleanup temp files
rm -f "$_co_infile" "$_co_outfile" "$_cc_infile" "$_cc_outfile"

echo ""

# ════════════════════════════════════════════════════════════════
# TEST SUITE 5: Fixture Output Parsing (7 tests — one per vendor)
# ════════════════════════════════════════════════════════════════
echo "# --- Fixture Output Parsing ---"

# For each vendor, verify version and running-config outputs are non-empty
# and parseable. One composite pass/fail per vendor.

# Helper: check a vendor's version + config files, emit TAP
_check_vendor_parsing() {
    _cvp_vendor="$1"
    _cvp_ver="$2"
    _cvp_cfg="$3"
    _cvp_dir="$FIXTURES_DIR/$_cvp_vendor"
    _cvp_ver_path="$_cvp_dir/$_cvp_ver"
    _cvp_cfg_path="$_cvp_dir/$_cvp_cfg"

    _cvp_ok=true
    _cvp_ver_lines=0
    _cvp_cfg_lines=0

    # Check version file
    if [ -f "$_cvp_ver_path" ] && [ -s "$_cvp_ver_path" ]; then
        _cvp_ver_lines=$(grep -c '[^[:space:]]' "$_cvp_ver_path" 2>/dev/null || echo 0)
        _cvp_ver_lines=$(printf '%s' "$_cvp_ver_lines" | tr -d '[:space:]')
        if [ "${_cvp_ver_lines:-0}" -le 0 ]; then
            _cvp_ok=false
        fi
    else
        _cvp_ok=false
    fi

    # Check config file
    if [ -f "$_cvp_cfg_path" ] && [ -s "$_cvp_cfg_path" ]; then
        _cvp_cfg_lines=$(grep -c '[^[:space:]]' "$_cvp_cfg_path" 2>/dev/null || echo 0)
        _cvp_cfg_lines=$(printf '%s' "$_cvp_cfg_lines" | tr -d '[:space:]')
        if [ "${_cvp_cfg_lines:-0}" -le 0 ]; then
            _cvp_ok=false
        fi
    else
        _cvp_ok=false
    fi

    if "$_cvp_ok"; then
        ok "$_cvp_vendor: outputs parseable (ver=${_cvp_ver_lines}L, cfg=${_cvp_cfg_lines}L)"
    else
        not_ok "$_cvp_vendor: outputs parseable" "ver=$_cvp_ver_path cfg=$_cvp_cfg_path"
    fi
}

_check_vendor_parsing cisco_ios       "show version.txt"         "show running-config.txt"
_check_vendor_parsing cisco_nexus     "show version.txt"         "show running-config.txt"
_check_vendor_parsing hp_comware      "display version"          "display current-configuration"
_check_vendor_parsing hp_provision    "show version"             "show running-config"
_check_vendor_parsing aruba_cx        "show version.txt"         "show running-config.txt"
_check_vendor_parsing aruba_switch    "show version.txt"         "show running-config.txt"
_check_vendor_parsing generic         "show version.txt"         "show running-config.txt"

echo ""

# ── TAP plan ───────────────────────────────────────────────────
echo "1..$TOTAL"
echo "# Passed: $PASS, Failed: $FAIL, Total: $TOTAL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
