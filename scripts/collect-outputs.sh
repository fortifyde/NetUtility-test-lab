#!/bin/sh
#
# Collect NetUtility scan outputs from the Kali scanner VM.
#
# Two modes:
#   --mode workspace   Copy results into a local workspace dir that can be
#                      opened directly by the NetUtility TUI. The TUI's
#                      ScanWorkspaceForResults() will find and parse all
#                      .xml/.nmap/.json files recursively.
#
#   --mode archive     Copy results into a timestamped archive directory
#                      under lab/results/ for record-keeping.
#
# The default mode is "workspace" so you can immediately review results.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(dirname "$LAB_DIR")"

# Defaults
KALI_USER="kali"
KALI_HOST=""
REMOTE_WORKDIR=""
SSH_KEY=""
MODE="workspace"

# --mode workspace: output goes to a TUI-consumable workspace directory.
# Default is <project>/netutil-lab-workspace/ so the host's `netutil` binary
# can point at it directly.
WORKSPACE_DIR="${PROJECT_DIR}/netutil-lab-workspace"

# --mode archive: output goes to a timestamped directory under lab/results/
ARCHIVE_DIR="${LAB_DIR}/results"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Collect NetUtility scan outputs from the Kali scanner VM into a form
consumable by the NetUtility TUI.

Modes:
  --mode workspace  (default) Copy results into a local workspace directory.
                    The NetUtility TUI can open this directory directly:
                      ./netutil --workspace <workspace-dir>
                    This places files in the exact directory structure the
                    TUI expects (scans/, discovery/, analysis/, etc.).

  --mode archive    Copy results into a timestamped archive directory
                    under lab/results/ for record-keeping.

OPTIONS:
    --host HOST       Kali VM management IP (required, or use --auto)
    --user USER       SSH username (default: kali)
    --key FILE        SSH private key file
    --remote DIR      Remote NETUTIL_WORKDIR on Kali (auto-detected if unset)
    --workspace DIR   Local workspace dir for --mode workspace
                      (default: <project>/netutil-lab-workspace/)
    --auto            Auto-detect Kali IP from terraform output
    -h, --help        Show this help message

WORKFLOW:
    1. Run scans on Kali (via test scripts or interactively through TUI)
    2. Collect results:  $0 --auto
    3. View in TUI:      ./netutil
       (configure workspace to point at netutil-lab-workspace/)

EXAMPLES:
    # Collect into workspace (default mode)
    $0 --auto

    # Collect with known IP
    $0 --host 192.168.100.101

    # Collect into archive for record-keeping
    $0 --auto --mode archive

    # Custom workspace location
    $0 --auto --workspace /tmp/lab-results

    # Custom SSH key
    $0 --host 192.168.100.101 --key ~/.ssh/lab_key
EOF
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --host)
            KALI_HOST="$2"
            shift 2
            ;;
        --user)
            KALI_USER="$2"
            shift 2
            ;;
        --key)
            SSH_KEY="$2"
            shift 2
            ;;
        --remote)
            REMOTE_WORKDIR="$2"
            shift 2
            ;;
        --mode)
            MODE="$2"
            shift 2
            ;;
        --workspace)
            WORKSPACE_DIR="$2"
            shift 2
            ;;
        --auto)
            if [ -f "${LAB_DIR}/terraform.tfstate" ]; then
                KALI_HOST=$(cd "$LAB_DIR" && terraform output -raw kali_mgmt_ip 2>/dev/null) || true
            fi
            if [ -z "$KALI_HOST" ]; then
                echo "ERROR: Could not auto-detect Kali IP. Use --host or run from lab/ with terraform apply." >&2
                exit 1
            fi
            shift
            # Auto-detect SSH key when --auto is used without --key
            if [ -z "$SSH_KEY" ]; then
                if [ -f "${LAB_DIR}/terraform.tfvars" ]; then
                    SSH_KEY=$(grep -E '^ssh_private_key_path' "${LAB_DIR}/terraform.tfvars" 2>/dev/null \
                         | sed 's/.*"\(.*\)".*/\1/' | sed "s|^~|$HOME|" || true)
                fi
                if [ -z "$SSH_KEY" ] && [ -f "${LAB_DIR}/.lab-ssh-key" ]; then
                    SSH_KEY="${LAB_DIR}/.lab-ssh-key"
                fi
                if [ -z "$SSH_KEY" ] && [ -f "$HOME/.ssh/id_rsa" ]; then
                    SSH_KEY="$HOME/.ssh/id_rsa"
                fi
            fi
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ -z "$KALI_HOST" ]; then
    echo "ERROR: --host or --auto is required" >&2
    usage >&2
    exit 1
fi

case "$MODE" in
    workspace|archive) ;;
    *)
        echo "ERROR: --mode must be 'workspace' or 'archive'" >&2
        exit 1
        ;;
esac

# Build SSH command
SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
if [ -n "$SSH_KEY" ]; then
    SSH_CMD="$SSH_CMD -i $SSH_KEY"
fi
SSH_CMD="$SSH_CMD ${KALI_USER}@${KALI_HOST}"

echo "=== Collecting NetUtility Outputs ==="
echo "Target: ${KALI_USER}@${KALI_HOST}"
echo "Mode: ${MODE}"

# Test connectivity
echo "Testing SSH connectivity..."
if ! $SSH_CMD "echo ok" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to ${KALI_USER}@${KALI_HOST}" >&2
    echo "Ensure the VM is running and SSH key is configured." >&2
    exit 1
fi
echo "Connected."

# Auto-detect remote NETUTIL_WORKDIR
if [ -z "$REMOTE_WORKDIR" ]; then
    REMOTE_WORKDIR=$($SSH_CMD "python3 -c \"import json; print(json.load(open('/opt/netutil/netutil-config.json'))['workspace_dir'])\" 2>/dev/null" 2>/dev/null) || true
    if [ -z "$REMOTE_WORKDIR" ]; then
        REMOTE_WORKDIR="/tmp/testing"
    fi
fi
echo "Remote workdir: ${REMOTE_WORKDIR}"

# Determine output directory
if [ "$MODE" = "workspace" ]; then
    OUTPUT_DIR="$WORKSPACE_DIR"
    # Create workspace subdirectories matching what scripts expect
    mkdir -p "$OUTPUT_DIR/scans" "$OUTPUT_DIR/discovery" "$OUTPUT_DIR/analysis" "$OUTPUT_DIR/configs" "$OUTPUT_DIR/captures" "$OUTPUT_DIR/reports" "$OUTPUT_DIR/logs" "$OUTPUT_DIR/topology"
else
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    OUTPUT_DIR="${ARCHIVE_DIR}/collect_${TIMESTAMP}"
    mkdir -p "$OUTPUT_DIR"
fi
echo "Local output: ${OUTPUT_DIR}"
echo
# Copy each category's results from remote to local.
# For --mode workspace, files go directly into the workspace subdirs
# so the TUI's recursive scanner finds them.
# For --mode archive, same structure under a timestamped directory.
copy_remote_dir() {
    _name="$1"
    _remote_subdir="$2"
    _local_subdir="$3"
    echo "  - ${_name}..."
    $SSH_CMD "tar czf - -C ${REMOTE_WORKDIR} ${_remote_subdir} 2>/dev/null" \
        | tar xzf - -C "${OUTPUT_DIR}" 2>/dev/null \
        || echo "    (no ${_name} results)"
}
copy_remote_dir "Scans (port/service/vuln)" "scans" "scans"
copy_remote_dir "Discovery (ARP, LLDP, SNMP)" "discovery" "discovery"
copy_remote_dir "Analysis (packet, MAC, fingerprint)" "analysis" "analysis"
copy_remote_dir "Config gathering" "configs" "configs"
copy_remote_dir "Packet captures" "captures" "captures"
copy_remote_dir "Topology (network maps)" "topology" "topology"
copy_remote_dir "Reports" "reports" "reports"
copy_remote_dir "Logs" "logs" "logs"

# Copy TAP test output if available
echo "  - Test results..."
$SSH_CMD "cat /tmp/netutil-test-results.tap 2>/dev/null" \
    > "${OUTPUT_DIR}/test_results.tap" 2>/dev/null || echo "    (no TAP output)"

# Copy gowitness database if present (screenshots DB)
echo "  - Screenshot database..."
$SSH_CMD "tar czf - -C ${REMOTE_WORKDIR} screenshots 2>/dev/null" \
    | tar xzf - -C "${OUTPUT_DIR}" 2>/dev/null \
    || echo "    (no screenshot database)"

# Copy correlations.json if present (stored in /opt/netutil/correlations/ on Kali)
echo "  - Correlation data..."
    $SSH_CMD "cat /opt/netutil/correlations/correlations.json 2>/dev/null" \
    > "${OUTPUT_DIR}/correlations.json" 2>/dev/null || true
    $SSH_CMD "cat /opt/netutil/correlations/manual_categories.json 2>/dev/null" \
        > "${OUTPUT_DIR}/manual_categories.json" 2>/dev/null || true

echo
echo "=== Collection Complete ==="
echo "Results saved to: ${OUTPUT_DIR}"
echo

# Summary
_file_count=$(find "$OUTPUT_DIR" -type f | wc -l)
echo "Total files: ${_file_count}"
echo

# Mode-specific instructions
if [ "$MODE" = "workspace" ]; then
    echo "To view results in the NetUtility TUI:"
    echo "  1. cd ${PROJECT_DIR}"
    echo "  2. Edit netutil-config.json and set workspace_dir to:"
    echo "     ${OUTPUT_DIR}"
    echo "  3. Run: ./netutil"
    echo
    echo "Or launch with the workspace directly:"
    echo "  ./netutil --workspace ${OUTPUT_DIR}"
    echo

    # Count parseable results (what the TUI will find)
    _parseable=$(find "$OUTPUT_DIR" \( -name "*.xml" -o -name "*.nmap" -o -name "*.json" -o -name "categorization_details.txt" \) -type f 2>/dev/null | wc -l)
    echo "TUI-parseable files (.xml/.nmap/.json/categorization_details.txt): ${_parseable}"
else
    echo "Archive saved. To view in TUI, copy contents to a workspace directory."
fi
