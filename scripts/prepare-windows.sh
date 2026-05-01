#!/bin/sh
# prepare-windows.sh - Prepare Windows VM installation media for NetUtility lab
# Creates an ISO with autounattend.xml for unattended Windows Server install.
# Requires: genisoimage or mkisofs or xorriso
# POSIX-compliant.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="${IMAGE_DIR:-${LAB_DIR}/images}"
CLOUD_INIT_DIR="${LAB_DIR}/cloud-init/windows"

WINDOWS_ISO="${IMAGE_DIR}/windows-server-eval.iso"
VIRTIO_ISO="${IMAGE_DIR}/virtio-win.iso"
AUTOUNATTEND_SRC="${CLOUD_INIT_DIR}/autounattend.xml"
SETUP_PS1_SRC="${CLOUD_INIT_DIR}/setup-services.ps1"
AUTOUNATTEND_ISO="${IMAGE_DIR}/autounattend.iso"

VIRTIO_WIN_URL="${VIRTIO_WIN_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"

# ── Logging helpers ────────────────────────────────────────────────────
log()   { printf "[+] %s\n" "$*"; }
warn()  { printf "[!] %s\n" "$*" >&2; }
err()   { printf "[-] %s\n" "$*" >&2; }

# ── Dependency check ───────────────────────────────────────────────────
check_mkisofs() {
    if command -v genisoimage >/dev/null 2>&1; then
        echo "genisoimage"
    elif command -v mkisofs >/dev/null 2>&1; then
        echo "mkisofs"
    elif command -v xorriso >/dev/null 2>&1; then
        echo "xorriso"
    else
        echo ""
    fi
}

# ── Download virtio-win ISO if missing ─────────────────────────────────
ensure_virtio_iso() {
    if [ -f "$VIRTIO_ISO" ]; then
        log "VirtIO drivers ISO already exists: $VIRTIO_ISO"
        return 0
    fi

    warn "VirtIO drivers ISO not found at $VIRTIO_ISO"
    log "Downloading from $VIRTIO_WIN_URL ..."

    mkdir -p "$IMAGE_DIR"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --progress-bar -o "${VIRTIO_ISO}.part" "$VIRTIO_WIN_URL"
        mv "${VIRTIO_ISO}.part" "$VIRTIO_ISO"
        log "Downloaded virtio-win.iso"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${VIRTIO_ISO}.part" "$VIRTIO_WIN_URL"
        mv "${VIRTIO_ISO}.part" "$VIRTIO_ISO"
        log "Downloaded virtio-win.iso"
    else
        err "Neither curl nor wget found. Download virtio-win.iso manually:"
        err "  $VIRTIO_WIN_URL"
        err "  Save to: $VIRTIO_ISO"
        return 1
    fi
}

# ── Build autounattend ISO ─────────────────────────────────────────────
build_autounattend_iso() {
    if [ ! -f "$AUTOUNATTEND_SRC" ]; then
        err "autounattend.xml not found: $AUTOUNATTEND_SRC"
        return 1
    fi

    if [ ! -f "$SETUP_PS1_SRC" ]; then
        err "setup-services.ps1 not found: $SETUP_PS1_SRC"
        return 1
    fi

    # Create temp staging directory
    staging="$(mktemp -d)"
    trap 'rm -rf "$staging"' EXIT

    # autounattend.xml must be in the root of the ISO
    cp "$AUTOUNATTEND_SRC" "$staging/autounattend.xml"
    # Include setup-services.ps1 so FirstLogonCommands can find it
    cp "$SETUP_PS1_SRC" "$staging/setup-services.ps1"

    mkiso_cmd="$(check_mkisofs)"
    case "$mkiso_cmd" in
        genisoimage)
            log "Creating autounattend.iso with genisoimage..."
            genisoimage -iso-level 4 -J -r -o "$AUTOUNATTEND_ISO" "$staging"
            ;;
        mkisofs)
            log "Creating autounattend.iso with mkisofs..."
            mkisofs -iso-level 4 -J -r -o "$AUTOUNATTEND_ISO" "$staging"
            ;;
        xorriso)
            log "Creating autounattend.iso with xorriso..."
            xorriso -as mkisofs -iso-level 4 -J -r -o "$AUTOUNATTEND_ISO" "$staging"
            ;;
        *)
            err "No ISO creation tool found. Install one of: genisoimage, mkisofs, xorriso"
            err "  Debian/Ubuntu: apt-get install genisoimage"
            err "  Fedora/RHEL:   dnf install genisoimage"
            err "  Arch:          pacman -S cdrtools"
            return 1
            ;;
    esac

    log "Created: $AUTOUNATTEND_ISO"
}

# ── Validate all required files ────────────────────────────────────────
validate() {
    errors=0

    if [ ! -f "$WINDOWS_ISO" ]; then
        err "MISSING: Windows Server Evaluation ISO"
        err "  Expected: $WINDOWS_ISO"
        errors=$((errors + 1))
    else
        log "FOUND: $WINDOWS_ISO"
    fi

    if [ ! -f "$VIRTIO_ISO" ]; then
        err "MISSING: VirtIO drivers ISO"
        err "  Expected: $VIRTIO_ISO"
        errors=$((errors + 1))
    else
        log "FOUND: $VIRTIO_ISO"
    fi

    if [ ! -f "$AUTOUNATTEND_ISO" ]; then
        err "MISSING: Autounattend ISO (run this script to create it)"
        err "  Expected: $AUTOUNATTEND_ISO"
        errors=$((errors + 1))
    else
        log "FOUND: $AUTOUNATTEND_ISO"
    fi

    if [ ! -f "$AUTOUNATTEND_SRC" ]; then
        err "MISSING: autounattend.xml source"
        err "  Expected: $AUTOUNATTEND_SRC"
        errors=$((errors + 1))
    else
        log "FOUND: $AUTOUNATTEND_SRC"
    fi

    return $errors
}

# ── Print Windows ISO download instructions ────────────────────────────
print_windows_instructions() {
    cat <<EOF

============================================================
  Windows Server Evaluation ISO - Manual Download Required
============================================================

The Windows evaluation ISO cannot be downloaded automatically
(Microsoft requires license agreement + browser interaction).

Steps:
  1. Visit: https://www.microsoft.com/evalcenter/
  2. Download Windows Server 2022 Evaluation ISO (Desktop Experience)
  3. Save to: $WINDOWS_ISO

After downloading, re-run this script to validate.

============================================================
EOF
}

# ── Main ───────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Prepare Windows VM installation media for NetUtility lab.

Actions:
  --build     Build autounattend.iso from autounattend.xml (default)
  --download  Download virtio-win ISO if not present
  --validate  Check all required files exist
  --help      Show this help message

Required files:
  Source:  $AUTOUNATTEND_SRC
           $SETUP_PS1_SRC
  Input:   $WINDOWS_ISO  (manual download)
           $VIRTIO_ISO   (auto-downloadable)
  Output:  $AUTOUNATTEND_ISO

Environment:
  IMAGE_DIR       Override image directory (default: lab/images/)
  VIRTIO_WIN_URL  Override virtio-win download URL
EOF
}

ACTION="build"

while [ $# -gt 0 ]; do
    case "$1" in
        --build)    ACTION="build";    shift ;;
        --download) ACTION="download"; shift ;;
        --validate) ACTION="validate"; shift ;;
        --help|-h)  usage; exit 0 ;;
        *)          err "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

log "Lab directory:  $LAB_DIR"
log "Image directory: $IMAGE_DIR"

case "$ACTION" in
    build)
        ensure_virtio_iso
        build_autounattend_iso
        log ""
        log "Build complete. Validating..."
        if validate; then
            log ""
            log "All files ready. Run 'terraform apply' with enable_windows=true."
        else
            log ""
            print_windows_instructions
        fi
        ;;
    download)
        ensure_virtio_iso
        ;;
    validate)
        if validate; then
            log ""
            log "All files present. Ready to deploy."
        else
            log ""
            print_windows_instructions
            exit 1
        fi
        ;;
esac
