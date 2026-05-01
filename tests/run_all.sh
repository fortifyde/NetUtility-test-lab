#!/bin/sh
# run_all.sh - Master test orchestrator for NetUtility lab validation
# Runs on the Kali scanner VM against lab targets.
# Usage: run_all.sh [--skip CATEGORY...] [--only CATEGORY...] [--help]

set -e

# ── Colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Configuration ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NETUTIL_BIN="/opt/netutil/netutil"
NETUTIL_SCRIPTS="/opt/netutil/scripts"
NETUTIL_WORKDIR="${NETUTIL_WORKDIR:-/tmp/netutil-test}"
RESULTS_DIR="${NETUTIL_WORKDIR}/results"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

# Lab targets
KALI_IP="10.10.10.5"
DEBIAN_IP="10.10.10.10"
UBUNTU_IP="10.10.10.20"
WINDOWS_IP="10.10.10.30"
DMZ_WEB_IP="10.10.30.10"

PING_TIMEOUT=3

# Required tools
REQUIRED_TOOLS="nmap jq grep awk sed"

# Test categories in execution order
CATEGORIES="discovery scanning analysis recon config_gathering"

# ── State ───────────────────────────────────────────────────────────────
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
OVERALL_RESULT=0

# ── Helpers ─────────────────────────────────────────────────────────────
log() {
	printf "%b\n" "$1" >&2
}

info() {
	log "${CYAN}[*]${RESET} $1"
}

pass() {
	log "${GREEN}[+]${RESET} $1"
}

fail() {
	log "${RED}[-]${RESET} $1"
}

warn() {
	log "${YELLOW}[!]${RESET} $1"
}

die() {
	fail "$1"
	exit 1
}

timestamp() {
	date '+%Y-%m-%d %H:%M:%S'
}

# ── Parse arguments ─────────────────────────────────────────────────────
SKIP_CATEGORIES=""
ONLY_CATEGORIES=""

while [ $# -gt 0 ]; do
	case "$1" in
		--skip)
			shift
			if [ -z "$1" ]; then
				die "--skip requires a category name"
			fi
			SKIP_CATEGORIES="${SKIP_CATEGORIES} $1"
			shift
			;;
		--only)
			shift
			if [ -z "$1" ]; then
				die "--only requires a category name"
			fi
			ONLY_CATEGORIES="${ONLY_CATEGORIES} $1"
			shift
			;;
		--help|-h)
			echo "Usage: $0 [OPTIONS]"
			echo ""
			echo "Options:"
			echo "  --skip CATEGORY  Skip one or more test categories"
			echo "                    (can be repeated: --skip recon --skip config_gathering)"
			echo "  --only CATEGORY  Run only specified categories"
			echo "                    (can be repeated: --only discovery --only scanning)"
			echo "  --help           Show this help"
			echo ""
			echo "Categories: discovery, scanning, analysis, recon, config_gathering"
			exit 0
			;;
		*)
			die "Unknown argument: $1 (try --help)"
			;;
	esac
done

# ── Determine which categories to run ───────────────────────────────────
should_run() {
	_cat="$1"

	# If --only was specified, only run those
	if [ -n "$ONLY_CATEGORIES" ]; then
		for o in $ONLY_CATEGORIES; do
			if [ "$o" = "$_cat" ]; then
				return 0
			fi
		done
		return 1
	fi

	# If --skip was specified, skip those
	if [ -n "$SKIP_CATEGORIES" ]; then
		for s in $SKIP_CATEGORIES; do
			if [ "$s" = "$_cat" ]; then
				return 1
			fi
		done
	fi

	return 0
}

# ── Prerequisite checks ─────────────────────────────────────────────────

check_tools() {
	info "Checking required tools..."
	_missing=0
	for tool in $REQUIRED_TOOLS; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			fail "Missing required tool: $tool"
			_missing=1
		fi
	done
	if [ "$_missing" -eq 1 ]; then
		die "Install missing tools before running tests"
	fi
	pass "All required tools found"
}

check_netutil() {
	info "Checking NetUtility installation..."
	if [ ! -x "$NETUTIL_BIN" ]; then
		die "NetUtility binary not found or not executable: $NETUTIL_BIN"
	fi
	if [ ! -d "$NETUTIL_SCRIPTS" ]; then
		die "NetUtility scripts directory not found: $NETUTIL_SCRIPTS"
	fi
	pass "NetUtility installation verified"
}

# Returns 0 if target is reachable, 1 if not
ping_target() {
	_ip="$1"
	_timeout="${2:-$PING_TIMEOUT}"
	ping -c 1 -W "$_timeout" "$_ip" >/dev/null 2>&1
}

# Populates REACHABLE_TARGETS and UNREACHABLE_TARGETS
REACHABLE_TARGETS=""
UNREACHABLE_TARGETS=""

check_targets() {
	info "Checking target reachability..."

	# Core targets - failure here means we should skip, not fail
	_all_targets="$DEBIAN_IP $UBUNTU_IP $DMZ_WEB_IP"

	# Windows is optional
	_has_windows=true
	if ! ping_target "$WINDOWS_IP" 2; then
		_has_windows=false
		warn "Windows target ($WINDOWS_IP) not reachable - tests requiring Windows will be skipped"
	fi

	# Track which core targets are up
	_all_core_up=true
	for ip in $_all_targets; do
		if ping_target "$ip"; then
			REACHABLE_TARGETS="${REACHABLE_TARGETS} $ip"
			pass "Target $ip is reachable"
		else
			UNREACHABLE_TARGETS="${UNREACHABLE_TARGETS} $ip"
			warn "Target $ip is NOT reachable"
			_all_core_up=false
		fi
	done

	if [ "$_all_core_up" = false ]; then
		warn "Some core targets unreachable - tests against them will be skipped"
		warn "Unreachable targets:${UNREACHABLE_TARGETS}"
	fi

	# Export for child test scripts
	export NETUTIL_REACHABLE_TARGETS="$REACHABLE_TARGETS"
	export NETUTIL_UNREACHABLE_TARGETS="$UNREACHABLE_TARGETS"
	export NETUTIL_HAS_WINDOWS="$_has_windows"
}

prepare_workdir() {
	info "Preparing working directory: $NETUTIL_WORKDIR"
	mkdir -p "$NETUTIL_WORKDIR"
	mkdir -p "$RESULTS_DIR"
	export NETUTIL_WORKDIR
	pass "Working directory ready"
}

# ── Test execution ──────────────────────────────────────────────────────

# Map category name to test script filename
category_to_script() {
	case "$1" in
		discovery)        echo "test_discovery.sh" ;;
		scanning)         echo "test_scanning.sh" ;;
		analysis)         echo "test_analysis.sh" ;;
		recon)            echo "test_recon.sh" ;;
		config_gathering) echo "test_config_gathering.sh" ;;
		*)                echo "" ;;
	esac
}

run_test_script() {
	_category="$1"
	_script="$(category_to_script "$_category")"

	if [ -z "$_script" ]; then
		fail "Unknown category: $_category"
		TOTAL_SKIP=$((TOTAL_SKIP + 1))
		return 1
	fi

	_script_path="${SCRIPT_DIR}/${_script}"
	_log_file="${RESULTS_DIR}/${TIMESTAMP}-${_category}.log"

	if [ ! -x "$_script_path" ]; then
		warn "Test script not found or not executable: $_script_path"
		log "not ok - test script $_script missing" >> "$_log_file"
		TOTAL_SKIP=$((TOTAL_SKIP + 1))
		return 1
	fi

	info "Running: $_script (${_category})"
	_start="$(date +%s)"

	# Run the test script, capture output and exit code
	# Use timeout to prevent hangs (default 10 minutes per category)
	_timeout="${NETUTIL_TEST_TIMEOUT:-600}"
	if _output=$(timeout "$_timeout" "$_script_path" 2>&1); then
		_rc=0
	else
		_rc=$?
		# timeout returns 124 on timeout
		if [ "$_rc" -eq 124 ]; then
			_output="${_output}
# TIMED OUT after ${_timeout}s"
		fi
	fi

	_end="$(date +%s)"
	_duration=$((_end - _start))

	# Write log
	printf "%s" "$_output" > "$_log_file"

	# Parse TAP output for pass/fail counts
	_script_pass=0
	_script_fail=0
	_script_skip=0

	# Count TAP results from the output
	_passes=$(printf "%s" "$_output" | grep -c "^ok " || true)
	_fails=$(printf "%s" "$_output" | grep -c "^not ok " || true)
	_skips=$(printf "%s" "$_output" | grep -c "^ok .* # SKIP" || true)

	_script_pass=$_passes
	_script_fail=$_fails
	_script_skip=$_skips
	# Adjust pass count: skips are counted in both passes and skips
	_script_pass=$((_script_pass - _script_skip))

	TOTAL_PASS=$((TOTAL_PASS + _script_pass))
	TOTAL_FAIL=$((TOTAL_FAIL + _script_fail))
	TOTAL_SKIP=$((TOTAL_SKIP + _script_skip))

	if [ "$_rc" -eq 0 ]; then
		pass "${_category}: ${_script_pass} passed, ${_script_fail} failed, ${_script_skip} skipped (${_duration}s)"
	else
		fail "${_category}: FAILED (exit $_rc) - ${_script_pass} passed, ${_script_fail} failed, ${_script_skip} skipped (${_duration}s)"
		OVERALL_RESULT=1
	fi

	return 0
}

# ── Summary report ──────────────────────────────────────────────────────

print_summary() {
	_end_time="$(timestamp)"
	_summary_file="${RESULTS_DIR}/${TIMESTAMP}-summary.txt"

	{
		echo "========================================"
		echo "NetUtility Lab Test Results"
		echo "========================================"
		echo "Started:  ${_start_time}"
		echo "Finished: ${_end_time}"
		echo ""
		echo "Results:"
		echo "  Passed:   ${TOTAL_PASS}"
		echo "  Failed:   ${TOTAL_FAIL}"
		echo "  Skipped:  ${TOTAL_SKIP}"
		echo "  Total:    $((TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP))"
		echo ""
		if [ "$TOTAL_FAIL" -eq 0 ]; then
			echo "Status: ALL TESTS PASSED"
		else
			echo "Status: ${TOTAL_FAIL} TEST(S) FAILED"
		fi
		echo "========================================"
		echo ""
		echo "Individual test logs:"
		for _category in $CATEGORIES; do
			if should_run "$_category"; then
				_log="${RESULTS_DIR}/${TIMESTAMP}-${_category}.log"
				if [ -f "$_log" ]; then
					echo "  ${_category}: ${_log}"
				else
					echo "  ${_category}: (no log)"
				fi
			else
				echo "  ${_category}: SKIPPED (--skip/--only)"
			fi
		done
		echo ""
		echo "Summary written to: ${_summary_file}"
	} | tee "$_summary_file"
}

# ── Main ────────────────────────────────────────────────────────────────

_start_time="$(timestamp)"

log ""
log "${BOLD}NetUtility Lab Test Runner${RESET}"
log "${BOLD}========================${RESET}"
log ""

# Prerequisites
check_tools
check_netutil
prepare_workdir
check_targets

log ""
info "Test plan:"
for _category in $CATEGORIES; do
	if should_run "$_category"; then
		info "  RUN: ${_category}"
	else
		info "  SKIP: ${_category}"
	fi
done
log ""

# Run tests
for _category in $CATEGORIES; do
	if should_run "$_category"; then
		run_test_script "$_category" || true
	fi
done

log ""

# Summary
print_summary

exit $OVERALL_RESULT
