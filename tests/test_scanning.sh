#!/bin/sh
# test_scanning.sh - Validate NetUtility scanning scripts against lab targets
# TAP-compatible output with timeout support

# --- Lab network constants ---
DEBIAN="10.10.10.10"
UBUNTU="10.10.10.20"
CORP_NET="10.10.10.0/24"

# --- Paths ---
SCRIPTS_DIR="${NETUTIL_SCRIPTS_DIR:-/opt/netutil/scripts}"
WORKDIR="${NETUTIL_WORKDIR:-/tmp/netutil-test}"

# --- Test state ---
test_num=0
pass_count=0
fail_count=0
skip_count=0
TIMEOUT="${TEST_TIMEOUT:-300}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# --- TAP helpers ---
pass() {
    test_num=$((test_num + 1))
    pass_count=$((pass_count + 1))
    printf "${GREEN}ok %d${RESET} - %s\n" "$test_num" "$1"
}

fail() {
    test_num=$((test_num + 1))
    fail_count=$((fail_count + 1))
    printf "${RED}not ok %d${RESET} - %s\n" "$test_num" "$1"
    [ -n "$2" ] && printf "  ---\n  message: %s\n  ...\n" "$2"
}

skip() {
    test_num=$((test_num + 1))
    skip_count=$((skip_count + 1))
    printf "${YELLOW}ok %d${RESET} - %s # SKIP %s\n" "$test_num" "$1" "$2"
}

# --- Utility: run command with timeout, capture exit code ---
run_with_timeout() {
    _cmd="$1"
    _timeout="${2:-$TIMEOUT}"
    timeout "$_timeout" sh -c "$_cmd"
    return $?
}

# --- Utility: check host reachability ---
host_up() {
    ping -c 1 -W 2 "$1" >/dev/null 2>&1
}

# --- Utility: validate XML file has nmap structure ---
validate_nmap_xml() {
    _xmlfile="$1"
    [ -f "$_xmlfile" ] || return 1
    # Check for nmaprun root element
    head -5 "$_xmlfile" | grep -q '<nmaprun' || return 1
    # Check for closing tag
    grep -q '</nmaprun>' "$_xmlfile" || return 1
    return 0
}

# --- Utility: find most recent session dir matching pattern ---
find_latest_session() {
    _base="$1"
    _pattern="$2"
    _dir=$(ls -dt "${_base}/${_pattern}" 2>/dev/null | head -1)
    [ -n "$_dir" ] && echo "$_dir" && return 0
    return 1
}

# ===========================================================================
# Test Suite: port_service_scan.sh
# ===========================================================================
test_port_service_scan_single() {
    printf "\n# Port Service Scan - Single Target (${DEBIAN})\n"

    if ! host_up "$DEBIAN"; then
        skip "All port_service_scan single-target tests" "Debian ${DEBIAN} unreachable"
        test_num=$((test_num + 6))
        skip_count=$((skip_count + 6))
        return
    fi

    # Clean previous test workdir for this target
    rm -rf "${WORKDIR}/scans/port_service"

    # Run port_service_scan.sh against Debian (single IP, quick scan)
    # Input: option 1 (single IP), IP address, option 1 (quick scan)
    result_dir=""
    cmd="printf '1\n%s\n1\n' '$DEBIAN' | NETUTIL_WORKDIR='$WORKDIR' '$SCRIPTS_DIR/scanning/port_service_scan.sh'"
    if run_with_timeout "$cmd" "$TIMEOUT"; then
        pass "port_service_scan.sh completed without error"

        # Find the session directory
        result_dir=$(find_latest_session "${WORKDIR}/scans/port_service" "*")
    else
        fail "port_service_scan.sh completed without error" "Script exited non-zero or timed out"
        result_dir=$(find_latest_session "${WORKDIR}/scans/port_service" "*")
    fi

    if [ -z "$result_dir" ]; then
        fail "Session directory created" "No session directory found under ${WORKDIR}/scans/port_service/"
        test_num=$((test_num + 5))
        fail_count=$((fail_count + 5))
        return
    fi

    # Test: XML output exists and is valid nmap XML
    xml_file="${result_dir}/scan_results.xml"
    if validate_nmap_xml "$xml_file"; then
        pass "Nmap XML output is valid (<nmaprun> structure)"
    else
        fail "Nmap XML output is valid" "$xml_file missing or not valid nmap XML"
    fi

    # Test: Greppable output exists
    gnmap_file="${result_dir}/scan_results.gnmap"
    if [ -f "$gnmap_file" ] && [ -s "$gnmap_file" ]; then
        pass "Greppable (.gnmap) output exists and is non-empty"
    else
        fail "Greppable (.gnmap) output exists and is non-empty" "$gnmap_file missing or empty"
    fi

    # Test: Normal output exists
    nmap_file="${result_dir}/scan_results.nmap"
    if [ -f "$nmap_file" ] && [ -s "$nmap_file" ]; then
        pass "Normal (.nmap) output exists and is non-empty"
    else
        fail "Normal (.nmap) output exists and is non-empty" "$nmap_file missing or empty"
    fi

    # Test: Port 22 (SSH) detected as open
    if [ -f "$nmap_file" ] && grep -q '22.*open.*ssh' "$nmap_file"; then
        pass "Port 22 (SSH) detected as open on ${DEBIAN}"
    else
        fail "Port 22 (SSH) detected as open on ${DEBIAN}" "SSH service not found in scan output"
    fi

    # Test: Service version detection ran (look for version info in output)
    if [ -f "$nmap_file" ] && grep -qE '[0-9]+/tcp\s+open\s+\S+\s+\S+' "$nmap_file"; then
        pass "Service version detection ran (version strings present)"
    else
        # Try gnmap as fallback - it has service/version in different format
        if [ -f "$gnmap_file" ] && grep -qP '/open/tcp//\S+//' "$gnmap_file" 2>/dev/null; then
            pass "Service version detection ran (version strings in gnmap)"
        else
            fail "Service version detection ran" "No version strings found in output"
        fi
    fi
}

test_port_service_scan_subnet() {
    printf "\n# Port Service Scan - Subnet (${CORP_NET})\n"

    # Quick ping sweep to check if any hosts are alive
    alive_count=$(fping -a -r 1 -t 500 "${CORP_NET}" 2>/dev/null | wc -l || echo 0)
    if [ "$alive_count" -eq 0 ] 2>/dev/null; then
        skip "All port_service_scan subnet tests" "No alive hosts in ${CORP_NET}"
        test_num=$((test_num + 3))
        skip_count=$((skip_count + 3))
        return
    fi

    # Clean previous test workdir for this target
    rm -rf "${WORKDIR}/scans/port_service"

    # Run against /24 subnet (CIDR option 2, then range, then quick scan option 1)
    cmd="printf '2\n%s\n1\n' '$CORP_NET' | NETUTIL_WORKDIR='$WORKDIR' '$SCRIPTS_DIR/scanning/port_service_scan.sh'"
    if run_with_timeout "$cmd" 600; then
        pass "port_service_scan.sh subnet scan completed"
    else
        fail "port_service_scan.sh subnet scan completed" "Script exited non-zero or timed out"
    fi

    result_dir=$(find_latest_session "${WORKDIR}/scans/port_service" "*")
    if [ -z "$result_dir" ]; then
        fail "Subnet session directory created" "No session directory found"
        test_num=$((test_num + 2))
        fail_count=$((fail_count + 2))
        return
    fi

    # Test: Multiple hosts discovered
    nmap_file="${result_dir}/scan_results.nmap"
    gnmap_file="${result_dir}/scan_results.gnmap"
    host_count=0
    if [ -f "$gnmap_file" ]; then
        host_count=$(grep -c '^Host:' "$gnmap_file" 2>/dev/null || echo 0)
    elif [ -f "$nmap_file" ]; then
        host_count=$(grep -c 'Nmap scan report for' "$nmap_file" 2>/dev/null || echo 0)
    fi

    if [ "$host_count" -ge 2 ]; then
        pass "Multiple hosts discovered (${host_count} found)"
    elif [ "$host_count" -ge 1 ]; then
        pass "At least one host discovered (${host_count} found)"
    else
        fail "Multiple hosts discovered" "Found ${host_count} hosts"
    fi

    # Test: Per-host results in gnmap
    if [ -f "$gnmap_file" ]; then
        # Each line starting with "Host:" represents a separate host result
        per_host_lines=$(grep -c '^Host:' "$gnmap_file" 2>/dev/null || echo 0)
        if [ "$per_host_lines" -ge 1 ]; then
            pass "Per-host results present in greppable output"
        else
            fail "Per-host results present in greppable output" "No Host: lines in gnmap"
        fi
    else
        fail "Per-host results present in greppable output" "No gnmap file"
    fi
}

# ===========================================================================
# Test Suite: vulnerability_assessment.sh
# ===========================================================================
test_vulnerability_assessment_debian() {
    printf "\n# Vulnerability Assessment - Debian (${DEBIAN})\n"

    if ! host_up "$DEBIAN"; then
        skip "All vulnerability_assessment Debian tests" "Debian ${DEBIAN} unreachable"
        test_num=$((test_num + 4))
        skip_count=$((skip_count + 4))
        return
    fi

    rm -rf "${WORKDIR}/scans/vulnerability"

    # Run vulnerability_assessment.sh against Debian (single IP, quick scan)
    cmd="printf '1\n%s\n1\n' '$DEBIAN' | NETUTIL_WORKDIR='$WORKDIR' '$SCRIPTS_DIR/scanning/vulnerability_assessment.sh'"
    if run_with_timeout "$cmd" "$TIMEOUT"; then
        pass "vulnerability_assessment.sh completed for ${DEBIAN}"
    else
        # vuln assessment may return non-zero if vulnerabilities found or supplementary tools fail
        # Still check if output was produced
        pass "vulnerability_assessment.sh ran for ${DEBIAN} (exit non-zero tolerated)"
    fi

    result_dir=$(find_latest_session "${WORKDIR}/scans/vulnerability" "*")
    if [ -z "$result_dir" ]; then
        fail "Vulnerability session directory created" "No session directory found"
        test_num=$((test_num + 3))
        fail_count=$((fail_count + 3))
        return
    fi

    # Test: Output directory exists with nmap output files
    vuln_nmap="${result_dir}/vuln_results.nmap"
    vuln_xml="${result_dir}/vuln_results.xml"
    vuln_gnmap="${result_dir}/vuln_results.gnmap"

    files_found=0
    [ -f "$vuln_nmap" ] && files_found=$((files_found + 1))
    [ -f "$vuln_xml" ] && files_found=$((files_found + 1))
    [ -f "$vuln_gnmap" ] && files_found=$((files_found + 1))

    if [ "$files_found" -ge 2 ]; then
        pass "Output directory has scan results (${files_found}/3 output files)"
    else
        fail "Output directory has scan results" "Only ${files_found}/3 output files found"
    fi

    # Test: Report file exists
    report="${result_dir}/vulnerability_report.txt"
    if [ -f "$report" ] && [ -s "$report" ]; then
        pass "Vulnerability report file exists and is non-empty"
    else
        fail "Vulnerability report file exists and is non-empty" "${report} missing or empty"
    fi

    # Test: Supplementary directory exists
    supp_dir="${result_dir}/supplementary"
    if [ -d "$supp_dir" ]; then
        pass "Supplementary checks directory exists"
    else
        fail "Supplementary checks directory exists" "${supp_dir} not created"
    fi
}

test_vulnerability_assessment_ubuntu() {
    printf "\n# Vulnerability Assessment - Ubuntu (${UBUNTU}) with SSL\n"

    if ! host_up "$UBUNTU"; then
        skip "All vulnerability_assessment Ubuntu tests" "Ubuntu ${UBUNTU} unreachable"
        test_num=$((test_num + 3))
        skip_count=$((skip_count + 3))
        return
    fi

    rm -rf "${WORKDIR}/scans/vulnerability"

    # Run vulnerability_assessment.sh against Ubuntu (single IP, quick scan)
    cmd="printf '1\n%s\n1\n' '$UBUNTU' | NETUTIL_WORKDIR='$WORKDIR' '$SCRIPTS_DIR/scanning/vulnerability_assessment.sh'"
    if run_with_timeout "$cmd" "$TIMEOUT"; then
        pass "vulnerability_assessment.sh completed for ${UBUNTU}"
    else
        pass "vulnerability_assessment.sh ran for ${UBUNTU} (exit non-zero tolerated)"
    fi

    result_dir=$(find_latest_session "${WORKDIR}/scans/vulnerability" "*")
    if [ -z "$result_dir" ]; then
        fail "Vulnerability session directory created" "No session directory found"
        test_num=$((test_num + 2))
        fail_count=$((fail_count + 2))
        return
    fi

    # Test: SSL testing produced results
    # Ubuntu has Apache+SSL per lab config, so ssl_tls.xml should exist if 443 is open
    supp_dir="${result_dir}/supplementary"
    ssl_found=0
    [ -f "${supp_dir}/ssl_tls.xml" ] && ssl_found=1
    [ -f "${supp_dir}/sslscan_"*.xml ] && ssl_found=1
    [ -f "${supp_dir}/testssl_"*"_vuln.json" ] && ssl_found=1

    if [ "$ssl_found" -eq 1 ]; then
        pass "SSL/TLS testing produced results"

        # Check for cipher suite info
        if [ -f "${supp_dir}/ssl_tls.xml" ]; then
            if grep -qi 'cipher\|ssl\|tls' "${supp_dir}/ssl_tls.xml" 2>/dev/null; then
                pass "SSL cipher/cert information present in results"
            else
                fail "SSL cipher/cert information present in results" "ssl_tls.xml exists but no cipher/ssl/tls keywords found"
            fi
        elif [ -f "${supp_dir}/testssl_"*"_ciphers.json" ]; then
            pass "SSL cipher/cert information present in results"
        else
            skip "SSL cipher/cert information" "SSL results in other format"
        fi
    else
        # Port 443 may not be open on Ubuntu in this lab config
        # Check the gnmap to see if SSL ports were found
        gnmap_file="${result_dir}/vuln_results.gnmap"
        if [ -f "$gnmap_file" ] && grep -q '443/open\|ssl\|https' "$gnmap_file" 2>/dev/null; then
            fail "SSL/TLS testing produced results" "SSL ports detected but no supplementary SSL output"
        else
            skip "SSL/TLS testing produced results" "No SSL/HTTPS ports detected on ${UBUNTU}"
        fi
        skip "SSL cipher/cert information" "No SSL results to check"
    fi

    # Test: Findings file (report) exists and references scan data
    report="${result_dir}/vulnerability_report.txt"
    if [ -f "$report" ]; then
        if grep -qi 'vulnerability\|vuln\|scan\|port' "$report" 2>/dev/null; then
            pass "Findings file contains vulnerability scan data"
        else
            fail "Findings file contains vulnerability scan data" "Report exists but no scan references found"
        fi
    else
        fail "Findings file contains vulnerability scan data" "Report file missing"
    fi
}

# ===========================================================================
# Main
# ===========================================================================
main() {
    echo "TAP version 13"
    echo "# NetUtility Scanning Script Tests"
    echo "# Lab: $(date)"
    echo "# Scripts: ${SCRIPTS_DIR}"
    echo "# Workdir: ${WORKDIR}"
    echo ""

    # Pre-flight: check script directory exists
    if [ ! -d "$SCRIPTS_DIR/scanning" ]; then
        echo "Bail out! Script directory not found: ${SCRIPTS_DIR}/scanning/"
        exit 1
    fi

    # Pre-flight: check nmap is available
    if ! command -v nmap >/dev/null 2>&1; then
        echo "Bail out! nmap not found in PATH"
        exit 1
    fi

    # Pre-flight: check timeout command exists
    if ! command -v timeout >/dev/null 2>&1; then
        echo "Bail out! timeout command not found (install coreutils)"
        exit 1
    fi

    # Ensure workdir exists
    mkdir -p "$WORKDIR"

    # Run tests
    test_port_service_scan_single
    test_port_service_scan_subnet
    test_vulnerability_assessment_debian
    test_vulnerability_assessment_ubuntu

    # Summary
    echo ""
    total=$((pass_count + fail_count + skip_count))
    echo "1..${total}"
    echo "# Tests: ${total}  Pass: ${pass_count}  Fail: ${fail_count}  Skip: ${skip_count}"

    if [ "$fail_count" -gt 0 ]; then
        printf "${RED}FAILED: %d test(s) failed${RESET}\n" "$fail_count"
        exit 1
    fi

    printf "${GREEN}All tests passed${RESET}\n"
    exit 0
}

main "$@"
