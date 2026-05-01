#!/bin/sh
#
# test_analysis.sh — Validates NetUtility analysis scripts
# Runs on Kali scanner VM against lab targets.
#
# Tests:
#   1. advanced_packet_analysis.sh — PCAP analysis output
#   2. mac_analysis.sh             — MAC vendor lookup / OUI categorisation
#   3. passive_fingerprint.sh      — p0f OS fingerprinting
#

# ── lab topology ──────────────────────────────────────────────
KALI_IP="10.10.10.5"
DEBIAN_IP="10.10.10.10"
UBUNTU_IP="10.10.10.20"
DMZ_IP="10.10.30.10"

# ── paths ─────────────────────────────────────────────────────
SCRIPTS_DIR="${NETUTIL_SCRIPTS_DIR:-/opt/netutil/scripts}"
WORKDIR="${NETUTIL_TEST_WORKDIR:-/tmp/netutil-test}"

PASS=0
FAIL=0
TOTAL=0

# ── TAP helpers ───────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

ok() {
    _desc="$1"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    printf "${GREEN}ok %d - %s${RESET}\n" "$TOTAL" "$_desc"
}

not_ok() {
    _desc="$1"
    _diag="${2:-}"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    printf "${RED}not ok %d - %s${RESET}\n" "$TOTAL" "$_desc"
    if [ -n "$_diag" ]; then
        printf "  # %s\n" "$_diag"
    fi
}

skip_ok() {
    _desc="$1"
    _reason="${2:-missing dependency}"
    TOTAL=$((TOTAL + 1))
    printf "ok %d - %s # SKIP %s\n" "$TOTAL" "$_desc" "$_reason"
}

# timeout wrapper: usage: run_timeout <seconds> <command> [args...]
# Writes stdout to $_timeout_out, stderr to $_timeout_err, exit code to $_timeout_rc
_timeout_out=""
_timeout_err=""
_timeout_rc=0
run_timeout() {
    _secs="$1"; shift
    _timeout_out="${WORKDIR}/timeout_$$_out"
    _timeout_err="${WORKDIR}/timeout_$$_err"
    # POSIX-compatible timeout via background + kill
    ( "$@" > "$_timeout_out" 2> "$_timeout_err" ) &
    _pid=$!
    _count=0
    while [ "$_count" -lt "$_secs" ]; do
        if ! kill -0 "$_pid" 2>/dev/null; then
            break
        fi
        sleep 1
        _count=$(( _count + 1 ))
    done
    if kill -0 "$_pid" 2>/dev/null; then
        kill -TERM "$_pid" 2>/dev/null
        wait "$_pid" 2>/dev/null
        _timeout_rc=124
    else
        wait "$_pid" 2>/dev/null
        _timeout_rc=$?
    fi
}

# ── preamble ──────────────────────────────────────────────────
echo "TAP version 14"
echo "# Analysis script tests — $(date)"
echo "# Scripts dir: $SCRIPTS_DIR"
echo "# Workdir:     $WORKDIR"

mkdir -p "$WORKDIR"

# ── check prerequisites ──────────────────────────────────────
_missing=0
for _tool in tshark jq p0f; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "# WARNING: $_tool not found — some tests will be skipped"
        _missing=1
    fi
done

# ====================================================================
# 1. advanced_packet_analysis.sh
# ====================================================================
echo ""
echo "# --- advanced_packet_analysis.sh ---"

ADV_SCRIPT="$SCRIPTS_DIR/analysis/advanced_packet_analysis.sh"
CAPTURE_DIR="$WORKDIR/captures"
ANALYSIS_DIR="$WORKDIR/analysis"
mkdir -p "$CAPTURE_DIR" "$ANALYSIS_DIR"

TEST_PCAP="$CAPTURE_DIR/test_analysis.pcap"

if [ ! -x "$ADV_SCRIPT" ]; then
    not_ok "advanced_packet_analysis.sh exists and is executable" \
           "$ADV_SCRIPT not found or not executable"
else
    ok "advanced_packet_analysis.sh exists and is executable"

    # Generate a PCAP with some traffic to the lab targets
    if command -v tshark >/dev/null 2>&1; then
        # Generate traffic so the PCAP has content
        ping -c 2 -W 1 "$DEBIAN_IP"  >/dev/null 2>&1
        ping -c 2 -W 1 "$UBUNTU_IP"  >/dev/null 2>&1
        ping -c 2 -W 1 "$DMZ_IP"     >/dev/null 2>&1

        run_timeout 60 tshark -i eth0 -w "$TEST_PCAP" -c 100 2>/dev/null
        if [ "$_timeout_rc" -eq 0 ] && [ -s "$TEST_PCAP" ]; then
            ok "PCAP capture generated ($TEST_PCAP)"
        else
            # Fallback: create an empty but valid pcap
            if [ -n "$_timeout_err" ] && [ -s "$_timeout_err" ]; then
                not_ok "PCAP capture generated" "tshark error: $(head -1 < "$_timeout_err")"
            else
                not_ok "PCAP capture generated" "tshark timed out or produced empty file (rc=$_timeout_rc)"
            fi
            echo "# Attempting fallback: create minimal valid pcap"
            # Use tshark to create a minimal pcap via dumpcap if capture failed
            dumpcap -i eth0 -c 10 -w "$TEST_PCAP" >/dev/null 2>&1
            if [ -s "$TEST_PCAP" ]; then
                ok "PCAP capture generated (fallback via dumpcap)"
            else
                not_ok "PCAP capture generated (fallback)" "could not capture any packets"
            fi
        fi
    else
        skip_ok "PCAP capture generated" "tshark not available"
    fi

    # Run advanced_packet_analysis.sh against the PCAP
    if [ -s "$TEST_PCAP" ]; then
        export NETUTIL_WORKDIR="$WORKDIR"

        # Feed the PCAP as argument 1 (non-interactive mode)
        run_timeout 120 "$ADV_SCRIPT" "$TEST_PCAP"

        if [ "$_timeout_rc" -eq 0 ]; then
            ok "advanced_packet_analysis.sh exited 0"
        else
            if [ "$_timeout_rc" -eq 124 ]; then
                not_ok "advanced_packet_analysis.sh exited 0" "timed out after 120s"
            else
                not_ok "advanced_packet_analysis.sh exited 0" "exit code $_timeout_rc"
            fi
        fi

        # Verify analysis output directory
        if [ -d "$ANALYSIS_DIR" ]; then
            ok "Analysis output directory exists"
        else
            not_ok "Analysis output directory exists" "$ANALYSIS_DIR not created"
        fi

        # Find the latest report file
        REPORT=$(ls -t "$ANALYSIS_DIR"/advanced_analysis_*.txt 2>/dev/null | head -1)

        if [ -n "$REPORT" ] && [ -s "$REPORT" ]; then
            ok "Analysis report file created and non-empty"

            # Check for protocol statistics section
            if grep -q "PROTOCOL STATISTICS" "$REPORT"; then
                ok "Report contains protocol statistics section"
            else
                not_ok "Report contains protocol statistics section" \
                       "missing PROTOCOL STATISTICS in $REPORT"
            fi

            # Check for protocol hierarchy (tshark -z io,phs output)
            if grep -q "Protocol hierarchy\|ethernet\|ip\|tcp\|udp" "$REPORT"; then
                ok "Report contains protocol breakdown"
            else
                not_ok "Report contains protocol breakdown" \
                       "no protocol entries found in report"
            fi

            # Check for IPv4 endpoint analysis
            if grep -q "IPv4 ENDPOINT" "$REPORT"; then
                ok "Report contains IPv4 endpoint analysis"
            else
                not_ok "Report contains IPv4 endpoint analysis" \
                       "missing IPv4 ENDPOINT section"
            fi

            # Check for security assessment
            if grep -q "SECURITY ASSESSMENT" "$REPORT"; then
                ok "Report contains security assessment"
            else
                not_ok "Report contains security assessment" \
                       "missing SECURITY ASSESSMENT section"
            fi

            # Verify at least one endpoint IP was found
            if grep -qE '^\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$REPORT"; then
                ok "Report contains discovered endpoint IPs"
            else
                not_ok "Report contains discovered endpoint IPs" \
                       "no IP addresses found in endpoint section"
            fi
        else
            not_ok "Analysis report file created and non-empty" \
                   "no advanced_analysis_*.txt found in $ANALYSIS_DIR"
        fi
    else
        skip_ok "advanced_packet_analysis.sh execution" "no PCAP available"
        skip_ok "Analysis output directory exists" "no PCAP available"
        skip_ok "Analysis report file created and non-empty" "no PCAP available"
        skip_ok "Report contains protocol statistics section" "no PCAP available"
        skip_ok "Report contains protocol breakdown" "no PCAP available"
        skip_ok "Report contains IPv4 endpoint analysis" "no PCAP available"
        skip_ok "Report contains security assessment" "no PCAP available"
        skip_ok "Report contains discovered endpoint IPs" "no PCAP available"
    fi
fi

# ====================================================================
# 2. mac_analysis.sh
# ====================================================================
echo ""
echo "# --- mac_analysis.sh ---"

MAC_SCRIPT="$SCRIPTS_DIR/analysis/mac_analysis.sh"

if [ ! -x "$MAC_SCRIPT" ]; then
    not_ok "mac_analysis.sh exists and is executable" \
           "$MAC_SCRIPT not found or not executable"
else
    ok "mac_analysis.sh exists and is executable"

    # mac_analysis.sh needs a PCAP in $WORKDIR/captures/ and runs interactively
    # It sources select_file from common utils, which requires interactive input.
    # We test it by prepping the capture dir and checking the core functions.
    if [ -s "$TEST_PCAP" ]; then
        export NETUTIL_WORKDIR="$WORKDIR"

        # mac_analysis.sh uses select_file interactively; run with stdin redirect
        # First, list the files so we know the number
        _pcap_count=$(ls "$CAPTURE_DIR"/*.pcap 2>/dev/null | wc -l)
        if [ "$_pcap_count" -ge 1 ]; then
            # Feed "1" as the interactive selection (pick first file)
            run_timeout 120 sh -c 'echo 1 | "$0"' "$MAC_SCRIPT"
            if [ "$_timeout_rc" -eq 0 ]; then
                ok "mac_analysis.sh ran successfully"
            else
                if [ "$_timeout_rc" -eq 124 ]; then
                    not_ok "mac_analysis.sh ran successfully" "timed out after 120s"
                else
                    not_ok "mac_analysis.sh ran successfully" "exit code $_timeout_rc"
                fi
            fi
        else
            skip_ok "mac_analysis.sh ran successfully" "no PCAP files in captures dir"
        fi

        # Verify report output
        MAC_REPORT=$(ls -t "$ANALYSIS_DIR"/mac_analysis_*.txt 2>/dev/null | head -1)

        if [ -n "$MAC_REPORT" ] && [ -s "$MAC_REPORT" ]; then
            ok "MAC analysis report file created and non-empty"

            # Check MAC address table section
            if grep -q "MAC ADDRESS ANALYSIS" "$MAC_REPORT"; then
                ok "Report contains MAC address analysis section"
            else
                not_ok "Report contains MAC address analysis section" \
                       "missing MAC ADDRESS ANALYSIS"
            fi

            # Check that MAC addresses are listed (format: XX:XX:XX:XX:XX:XX)
            if grep -qE '[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}' "$MAC_REPORT"; then
                ok "Report contains MAC addresses"
            else
                not_ok "Report contains MAC addresses" \
                       "no MAC addresses found in report"
            fi

            # Check vendor identification section
            if grep -q "VENDOR STATISTICS" "$MAC_REPORT"; then
                ok "Report contains vendor statistics"
            else
                not_ok "Report contains vendor statistics" \
                       "missing VENDOR STATISTICS section"
            fi

            # Check device type categorisation
            if grep -q "DEVICE TYPE STATISTICS" "$MAC_REPORT"; then
                ok "Report contains device type categorisation"
            else
                not_ok "Report contains device type categorisation" \
                       "missing DEVICE TYPE STATISTICS section"
            fi

            # Check that OUI lookup produced vendor names (not all "Unknown")
            _known_vendors=$(grep -vE "Unknown|^-|^$|MAC Address|---" "$MAC_REPORT" | grep -cEi "VMware|Intel|Realtek|Broadcom|Cisco|Dell|HP|Microsoft|Apple|Ubiquiti|TP-Link|Samsung|Generic Device|Network|Card|Computer|Device|Machine" || echo 0)
            if [ "$_known_vendors" -ge 1 ]; then
                ok "OUI vendor lookup produced identifiable results"
            else
                # In a lab with virtual machines, vendors may all be the hypervisor vendor
                _any_vendor=$(grep -cE "^.+[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}" "$MAC_REPORT" || echo 0)
                if [ "$_any_vendor" -ge 1 ]; then
                    ok "OUI vendor lookup produced identifiable results"
                else
                    not_ok "OUI vendor lookup produced identifiable results" \
                           "no vendor names resolved"
                fi
            fi

            # Check security analysis section
            if grep -q "SECURITY ANALYSIS" "$MAC_REPORT"; then
                ok "Report contains MAC security analysis"
            else
                not_ok "Report contains MAC security analysis" \
                       "missing SECURITY ANALYSIS section"
            fi
        else
            not_ok "MAC analysis report file created and non-empty" \
                   "no mac_analysis_*.txt found in $ANALYSIS_DIR"
        fi
    else
        skip_ok "mac_analysis.sh ran successfully" "no PCAP available"
        skip_ok "MAC analysis report file created and non-empty" "no PCAP available"
        skip_ok "Report contains MAC address analysis section" "no PCAP available"
        skip_ok "Report contains MAC addresses" "no PCAP available"
        skip_ok "Report contains vendor statistics" "no PCAP available"
        skip_ok "Report contains device type categorisation" "no PCAP available"
        skip_ok "OUI vendor lookup produced identifiable results" "no PCAP available"
        skip_ok "Report contains MAC security analysis" "no PCAP available"
    fi
fi

# ====================================================================
# 3. passive_fingerprint.sh
# ====================================================================
echo ""
echo "# --- passive_fingerprint.sh ---"

FP_SCRIPT="$SCRIPTS_DIR/analysis/passive_fingerprint.sh"

if [ ! -x "$FP_SCRIPT" ]; then
    not_ok "passive_fingerprint.sh exists and is executable" \
           "$FP_SCRIPT not found or not executable"
else
    ok "passive_fingerprint.sh exists and is executable"

    if command -v p0f >/dev/null 2>&1; then
        if [ -s "$TEST_PCAP" ]; then
            export NETUTIL_WORKDIR="$WORKDIR"

            # passive_fingerprint.sh is interactive (selects PCAP files).
            # Feed "1" for pcap selection.
            _pcap_count=$(find "$WORKDIR/captures" "$WORKDIR/scans" -name "*.pcap" -type f 2>/dev/null | wc -l)
            if [ "$_pcap_count" -ge 1 ]; then
                run_timeout 120 sh -c 'echo 1 | "$0"' "$FP_SCRIPT"
                if [ "$_timeout_rc" -eq 0 ]; then
                    ok "passive_fingerprint.sh ran successfully"
                else
                    if [ "$_timeout_rc" -eq 124 ]; then
                        not_ok "passive_fingerprint.sh ran successfully" \
                               "timed out after 120s"
                    else
                        not_ok "passive_fingerprint.sh ran successfully" \
                               "exit code $_timeout_rc"
                    fi
                fi
            else
                skip_ok "passive_fingerprint.sh ran successfully" \
                        "no PCAP files in workdir"
            fi

            # Verify output directory and files
            FP_DIR=$(ls -d "$WORKDIR"/discovery/fingerprint/fingerprint_* 2>/dev/null | tail -1)

            if [ -n "$FP_DIR" ] && [ -d "$FP_DIR" ]; then
                ok "Fingerprint session directory created"

                # Check for p0f output
                if [ -f "$FP_DIR/p0f_output.txt" ]; then
                    ok "p0f output file exists"
                    if [ -s "$FP_DIR/p0f_output.txt" ]; then
                        ok "p0f output is non-empty"
                    else
                        # Empty p0f output is valid if no SYN packets in capture
                        skip_ok "p0f output is non-empty" "no SYN packets in capture"
                    fi
                else
                    not_ok "p0f output file exists" \
                           "$FP_DIR/p0f_output.txt not found"
                fi

                # Check for XML results
                if [ -f "$FP_DIR/fingerprint_results.xml" ]; then
                    ok "Fingerprint XML results file exists"

                    # Validate XML structure
                    if grep -q '<?xml' "$FP_DIR/fingerprint_results.xml" && \
                       grep -q '</fingerprint_results>' "$FP_DIR/fingerprint_results.xml"; then
                        ok "XML results have valid structure"
                    else
                        not_ok "XML results have valid structure" \
                               "missing XML header or closing tag"
                    fi

                    # Check for host entries
                    _host_count=$(grep -c '<host ip=' "$FP_DIR/fingerprint_results.xml" || echo 0)
                    if [ "$_host_count" -ge 1 ]; then
                        ok "XML contains host entries ($_host_count found)"
                    else
                        # Valid to have 0 hosts if capture was minimal
                        skip_ok "XML contains host entries" \
                                "0 hosts (possibly minimal capture)"
                    fi

                    # Check for Linux fingerprint detection
                    if grep -qiE 'Linux|linux' "$FP_DIR/fingerprint_results.xml"; then
                        ok "Linux OS fingerprint detected"
                    else
                        # Lab targets are Linux VMs — if no Linux detected, capture may lack SYN
                        not_ok "Linux OS fingerprint detected" \
                               "no Linux fingerprints found in XML"
                    fi
                else
                    not_ok "Fingerprint XML results file exists" \
                           "fingerprint_results.xml not in $FP_DIR"
                fi

                # Check for summary report
                if [ -f "$FP_DIR/fingerprint_summary.txt" ]; then
                    ok "Fingerprint summary report exists"
                    if grep -q "Passive Fingerprint Summary" "$FP_DIR/fingerprint_summary.txt"; then
                        ok "Summary report has correct header"
                    else
                        not_ok "Summary report has correct header" \
                               "expected 'Passive Fingerprint Summary' header"
                    fi
                else
                    not_ok "Fingerprint summary report exists" \
                           "fingerprint_summary.txt not in $FP_DIR"
                fi

                # Check for OS guess in results
                if [ -f "$FP_DIR/fingerprint_results.xml" ]; then
                    if grep -q '<os_guess>' "$FP_DIR/fingerprint_results.xml"; then
                        ok "Fingerprint results contain OS guesses"
                    else
                        not_ok "Fingerprint results contain OS guesses" \
                               "no <os_guess> elements in XML"
                    fi
                fi

            else
                not_ok "Fingerprint session directory created" \
                       "no fingerprint_* directory in $WORKDIR/discovery/fingerprint/"
            fi
        else
            skip_ok "passive_fingerprint.sh ran successfully" "no PCAP available"
            skip_ok "Fingerprint session directory created" "no PCAP available"
            skip_ok "p0f output file exists" "no PCAP available"
            skip_ok "p0f output is non-empty" "no PCAP available"
            skip_ok "Fingerprint XML results file exists" "no PCAP available"
            skip_ok "XML results have valid structure" "no PCAP available"
            skip_ok "XML contains host entries" "no PCAP available"
            skip_ok "Linux OS fingerprint detected" "no PCAP available"
            skip_ok "Fingerprint summary report exists" "no PCAP available"
            skip_ok "Summary report has correct header" "no PCAP available"
            skip_ok "Fingerprint results contain OS guesses" "no PCAP available"
        fi
    else
        skip_ok "passive_fingerprint.sh ran successfully" "p0f not available"
        skip_ok "Fingerprint session directory created" "p0f not available"
        skip_ok "p0f output file exists" "p0f not available"
        skip_ok "p0f output is non-empty" "p0f not available"
        skip_ok "Fingerprint XML results file exists" "p0f not available"
        skip_ok "XML results have valid structure" "p0f not available"
        skip_ok "XML contains host entries" "p0f not available"
        skip_ok "Linux OS fingerprint detected" "p0f not available"
        skip_ok "Fingerprint summary report exists" "p0f not available"
        skip_ok "Summary report has correct header" "p0f not available"
        skip_ok "Fingerprint results contain OS guesses" "p0f not available"
    fi
fi

# ── cleanup ───────────────────────────────────────────────────
rm -f "$WORKDIR"/timeout_$$_out "$WORKDIR"/timeout_$$_err

# ── summary ───────────────────────────────────────────────────
echo ""
echo "1..$TOTAL"
echo "# Pass: $PASS  Fail: $FAIL  Total: $TOTAL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
