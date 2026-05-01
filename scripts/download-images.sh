#!/bin/sh
# download-images.sh - Download cloud-init images for NetUtility test lab
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE_DIR="${IMAGE_DIR:-${LAB_DIR}/images}"

# Default image URLs (overridable via environment)
# Kali cloud images are tar.xz archives containing disk.raw, not qcow2.
# We download, extract, and convert to qcow2 with qemu-img.
KALI_URL="${KALI_URL:-https://kali.download/cloud-images/current/kali-linux-2026.1-cloud-genericcloud-amd64.tar.xz}"
DEBIAN_URL="${DEBIAN_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2}"
UBUNTU_URL="${UBUNTU_URL:-https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img}"
VIRTIO_WIN_URL="${VIRTIO_WIN_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"

# Checksum URLs
KALI_CHECKSUM_URL="${KALI_CHECKSUM_URL:-https://kali.download/cloud-images/current/SHA256SUMS}"
# Debian publishes SHA512SUMS (not SHA256SUMS)
DEBIAN_CHECKSUM_URL="${DEBIAN_CHECKSUM_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS}"
UBUNTU_CHECKSUM_URL="${UBUNTU_CHECKSUM_URL:-https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS}"

# Retry settings
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-30}"

# Minimum disk space in MB required per image (generous estimate)
MIN_SPACE_MB=4000

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [IMAGE...]

Download cloud-init VM images for the NetUtility test lab.

Images:
  kali       Kali Linux cloud image (qcow2)
  debian     Debian 12 Bookworm cloud image (qcow2)
  ubuntu     Ubuntu 22.04 Jammy cloud image (qcow2)
  virtio     VirtIO Windows drivers ISO
  windows    Print instructions for obtaining Windows eval ISO
  all        Download all of the above (except windows)

Options:
  --help       Show this help message
  --list       List available images and their URLs
  --force      Re-download even if image already exists
  --dir PATH   Override image download directory (default: lab/images/)
  --no-check   Skip checksum verification

Environment Variables:
  KALI_URL, DEBIAN_URL, UBUNTU_URL, VIRTIO_WIN_URL
               Override default download URLs
  IMAGE_DIR    Override image storage directory
  MAX_RETRIES  Number of download retries (default: 3)

Examples:
  $(basename "$0") all
  $(basename "$0") --force kali debian
  KALI_URL=http://mirror/kali.qcow2 $(basename "$0") kali
EOF
}

log() {
    printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"
}

warn() {
    printf "[%s] WARN: %s\n" "$(date '+%H:%M:%S')" "$*" >&2
}

die() {
    printf "[%s] ERROR: %s\n" "$(date '+%H:%M:%S')" "$*" >&2
    exit 1
}

check_deps() {
    missing=""
    for cmd in curl tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="${missing} ${cmd}"
        fi
    done
    # sha256sum is needed for Kali and Ubuntu; sha512sum for Debian
    if ! command -v sha256sum >/dev/null 2>&1; then
        missing="${missing} sha256sum"
    fi
    if ! command -v sha512sum >/dev/null 2>&1; then
        missing="${missing} sha512sum"
    fi
    # xz for extracting Kali archive; qemu-img for raw->qcow2 conversion
    if ! command -v xz >/dev/null 2>&1; then
        missing="${missing} xz"
    fi
    if ! command -v qemu-img >/dev/null 2>&1; then
        missing="${missing} qemu-img"
    fi
    if [ -n "$missing" ]; then
        die "Missing required dependencies:${missing}. Please install them and retry."
    fi
}

check_disk_space() {
    if ! command -v df >/dev/null 2>&1; then
        warn "df not found; skipping disk space check"
        return 0
    fi
    available_kb=$(df "$IMAGE_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$available_kb" ]; then
        # Directory may not exist yet; try parent
        available_kb=$(df "$(dirname "$IMAGE_DIR")" 2>/dev/null | awk 'NR==2 {print $4}')
    fi
    if [ -n "$available_kb" ]; then
        available_mb=$((available_kb / 1024))
        if [ "$available_mb" -lt "$MIN_SPACE_MB" ]; then
            die "Insufficient disk space: ${available_mb}MB available, need at least ${MIN_SPACE_MB}MB"
        fi
    fi
}

# download_file URL OUTPUT_FILE
# Uses curl with retry and resume support.
download_file() {
    _url="$1"
    _out="$2"
    _tries=0

    while [ "$_tries" -lt "$MAX_RETRIES" ]; do
        _tries=$((_tries + 1))
        log "Downloading ${_out} (attempt ${_tries}/${MAX_RETRIES})..."
        if curl --fail --location --continue-at - \
                --connect-timeout "$CONNECT_TIMEOUT" \
                --retry "$MAX_RETRIES" \
                --retry-delay "$RETRY_DELAY" \
                --progress-bar \
                -o "$_out" "$_url"; then
            return 0
        fi
        warn "Download attempt ${_tries} failed, retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
    done
    die "Failed to download ${_url} after ${MAX_RETRIES} attempts"
}

# verify_checksum IMAGE_FILE CHECKSUM_URL BASENAME [HASH_ALG]
# Downloads checksums file, extracts expected hash, and verifies.
# HASH_ALG: sha256 (default) or sha512
verify_checksum() {
    _img="$1"
    _sum_url="$2"
    _basename="$3"
    _alg="${4:-sha256}"
    _sum_file="${IMAGE_DIR}/.checksums/${_basename}.${_alg}sums"

    if [ "$SKIP_CHECKSUM" = "1" ]; then
        log "Skipping checksum verification (--no-check)"
        return 0
    fi

    mkdir -p "${IMAGE_DIR}/.checksums"

    log "Fetching checksums from ${_sum_url}..."
    if ! curl --fail --location --silent -o "$_sum_file" "$_sum_url"; then
        warn "Could not download checksums; skipping verification for ${_basename}"
        return 0
    fi

    # Try to find the hash for our specific file
    expected=""
    if [ -f "$_sum_file" ]; then
        # Checksum files have format: <hash>  <filename> or <hash> *<filename>
        expected=$(grep -E "[[:space:]].*${_basename}" "$_sum_file" 2>/dev/null | head -1 | awk '{print $1}')
    fi

    if [ -z "$expected" ]; then
        warn "No checksum found for ${_basename} in checksum file; skipping verification"
        return 0
    fi

    log "Verifying ${_alg} checksum for ${_basename}..."
    actual=$("${_alg}sum" "$_img" 2>/dev/null | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        die "Checksum mismatch for ${_basename}\n  expected: ${expected}\n  actual:   ${actual}"
    fi
    log "Checksum verified (${_alg}): ${_basename}"
}

# download_image NAME URL CHECKSUM_URL FILENAME [HASH_ALG]
# Downloads a single image file and verifies its checksum.
download_image() {
    _name="$1"
    _url="$2"
    _cksum_url="$3"
    _filename="$4"
    _hash_alg="${5:-sha256}"
    _dest="${IMAGE_DIR}/${_filename}"

    if [ -f "$_dest" ] && [ "$FORCE" != "1" ]; then
        log "${_name} already exists at ${_dest} (use --force to re-download)"
        return 0
    fi

    mkdir -p "$IMAGE_DIR"
    download_file "$_url" "${_dest}.part"

    # Checksum verification
    if [ -n "$_cksum_url" ]; then
        verify_checksum "${_dest}.part" "$_cksum_url" "$_filename" "$_hash_alg"
    fi

    mv "${_dest}.part" "$_dest"
    log "Saved ${_name} -> ${_dest}"
}

# download_kali
# Downloads Kali Linux cloud image tar.xz, extracts disk.raw,
# converts to qcow2 with qemu-img, and saves to the expected filename.
download_kali() {
    _dest="${IMAGE_DIR}/kali-linux-last-amd64.qcow2"

    if [ -f "$_dest" ] && [ "$FORCE" != "1" ]; then
        log "Kali Linux already exists at ${_dest} (use --force to re-download)"
        return 0
    fi

    mkdir -p "$IMAGE_DIR"
    _archive="${IMAGE_DIR}/kali-cloud-amd64.tar.xz"

    # Download the tar.xz archive (~200MB)
    download_file "$KALI_URL" "${_archive}.part"

    # Verify checksum of the tar.xz
    # SHA256SUMS references the .tar.xz filename
    _tar_basename=$(basename "$KALI_URL")
    verify_checksum "${_archive}.part" "$KALI_CHECKSUM_URL" "$_tar_basename" sha256

    mv "${_archive}.part" "$_archive"
    log "Downloaded Kali archive: ${_archive}"

    # Extract disk.raw from the tar.xz
    log "Extracting disk.raw from Kali archive..."
    _raw="${IMAGE_DIR}/kali-disk.raw"
    _old_pwd=$(pwd)
    cd "$IMAGE_DIR"
    tar xJf "$_archive" 2>/dev/null || tar xf "$_archive" 2>/dev/null || \
        die "Failed to extract Kali archive ${_archive}"
    cd "$_old_pwd"

    # Locate the extracted raw image (may be disk.raw or <name>.raw)
    _raw=""
    # Check for the file most recently extracted
    _raw=$(find "$IMAGE_DIR" -maxdepth 1 -name '*.raw' -newer "$_archive" | head -1)
    if [ -z "$_raw" ]; then
        _raw=$(find "$IMAGE_DIR" -maxdepth 1 -name 'disk.raw' | head -1)
    fi
    if [ -z "$_raw" ]; then
        die "Could not find extracted disk.raw from Kali archive"
    fi

    # Convert raw to qcow2 (sparse, saves space)
    log "Converting raw image to qcow2..."
    if ! qemu-img convert -f raw -O qcow2 "$_raw" "$_dest"; then
        die "qemu-img convert failed for Kali image"
    fi
    log "Converted Kali image: ${_dest}"

    # Clean up archive, raw image, and any nvram file
    rm -f "$_archive"
    rm -f "$_raw"
    rm -f "${IMAGE_DIR}"/*.nvram 2>/dev/null
    log "Cleaned up temporary files"
}

print_windows_instructions() {
    cat <<EOF

============================================================
  Windows Evaluation ISO - Manual Step Required
============================================================

The Windows evaluation ISO must be obtained manually due to
Microsoft's download flow (license agreement + JavaScript).

1. Visit: https://www.microsoft.com/evalcenter/
   Download a Windows Server evaluation ISO (e.g., Windows Server 2022).

2. Save the ISO to: ${IMAGE_DIR}/windows-server-eval.iso

3. The VirtIO drivers ISO will be downloaded automatically with 'all'.
   Mount both ISOs during Windows installation.

4. For automation, consider using a pre-built Windows qcow2 image
   from https://github.com/nickryand/virtio-windows-image or
   build one with packer.

============================================================

EOF
}

list_images() {
    cat <<EOF
Available images for NetUtility test lab:

  kali (Kali Linux cloud)
    URL:  ${KALI_URL}
    File: kali-linux-last-amd64.qcow2 (converted from disk.raw)
    Note: Kali cloud images ship as tar.xz containing disk.raw;
          extracted and converted to qcow2 with qemu-img

  debian (Debian 12 Bookworm cloud)
    URL:  ${DEBIAN_URL}
    File: debian-12-generic-amd64.qcow2

  ubuntu (Ubuntu 22.04 Jammy cloud)
    URL:  ${UBUNTU_URL}
    File: jammy-server-cloudimg-amd64.img

  virtio (VirtIO Windows drivers)
    URL:  ${VIRTIO_WIN_URL}
    File: virtio-win.iso

  windows (instructions only)
    Manual download required from Microsoft Eval Center
    Expected file: windows-server-eval.iso

Download directory: ${IMAGE_DIR}
EOF
}

# --- Main ---

FORCE=0
SKIP_CHECKSUM=0
IMAGES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --list|-l)
            list_images
            exit 0
            ;;
        --force|-f)
            FORCE=1
            shift
            ;;
        --dir)
            [ -z "${2:-}" ] && die "--dir requires a path argument"
            IMAGE_DIR="$2"
            shift 2
            ;;
        --no-check)
            SKIP_CHECKSUM=1
            shift
            ;;
        all|kali|debian|ubuntu|virtio|windows)
            IMAGES="${IMAGES} $1"
            shift
            ;;
        *)
            die "Unknown argument: $1\nRun '$(basename "$0") --help' for usage."
            ;;
    esac
done

if [ -z "$IMAGES" ]; then
    die "No images specified. Run '$(basename "$0") --help' for usage."
fi

# Validate dependencies before doing anything
check_deps
check_disk_space

log "Image directory: ${IMAGE_DIR}"

# Process each requested image
for img in $IMAGES; do
    case "$img" in
        all)
            download_kali
            download_image "Debian 12" "$DEBIAN_URL" "$DEBIAN_CHECKSUM_URL" \
                "debian-12-generic-amd64.qcow2" sha512
            download_image "Ubuntu 22.04" "$UBUNTU_URL" "$UBUNTU_CHECKSUM_URL" \
                "jammy-server-cloudimg-amd64.img"
            download_image "VirtIO Drivers" "$VIRTIO_WIN_URL" "" \
                "virtio-win.iso"
            print_windows_instructions
            ;;
        kali)
            download_kali
            ;;
        debian)
            download_image "Debian 12" "$DEBIAN_URL" "$DEBIAN_CHECKSUM_URL" \
                "debian-12-generic-amd64.qcow2" sha512
            ;;
        ubuntu)
            download_image "Ubuntu 22.04" "$UBUNTU_URL" "$UBUNTU_CHECKSUM_URL" \
                "jammy-server-cloudimg-amd64.img"
            ;;
        virtio)
            download_image "VirtIO Drivers" "$VIRTIO_WIN_URL" "" \
                "virtio-win.iso"
            ;;
        windows)
            print_windows_instructions
            ;;
    esac
done

log "Done."
