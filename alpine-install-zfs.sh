#!/bin/bash
#
# Install Alpine Linux with ZFS root and ZFSBootMenu from a rescue system.
#
# Target:
#   - x86_64 or aarch64
#   - UEFI or legacy BIOS (x86_64 only - e.g. cloud hosts that offer no
#     UEFI). USE_UEFI="auto" (default) detects /sys/firmware/efi; force
#     "yes"/"no" to override. BIOS mode chainloads ZFSBootMenu's Components
#     output (separate kernel+initramfs, not the EFI bundle) through GRUB.
#   - single disk
#   - Alpine Linux, latest stable by default (see ALPINE_VERSION below)
#   - linux-virt + zfs-virt
#   - unencrypted ZFS root
#
# Disk layout:
#   1: 512 MiB EFI System Partition (also holds GRUB + ZBM Components in
#      BIOS mode - GRUB's BIOS-stage vfat driver reads it directly)
#   2: swap (SWAP_SIZE_GIB, default 2 GiB - set to 0 to skip it entirely)
#   3: remaining space for ZFS
#   4: 1 MiB BIOS boot partition (GPT bios_grub) - only created when
#      USE_UEFI=no; carved from partition 3's trailing alignment gap, so
#      partitions 1-3 keep identical numbers/sizes in both modes.
#
# This is one opinionated layout, not a configurable one - if you want a
# different pool/dataset shape or partitioning, use this script as a
# starting point and edit it. install-normal.sh (the non-ZFS installer in
# this repo) is the one built to be flexible; ZFS gets a single blessed
# shape instead.
#
# Credentials:
#   PUBKEY (required) - one or more SSH public key lines for root. The
#   installer refuses to run at all without it - there is no built-in
#   fallback key, ever. Root's password is left EMPTY (not locked, not
#   set) - see the comment in write_chroot_install_script() below for
#   exactly what that does and does not allow.
#
# WARNING: This script destroys all data on SYSDRIVE without confirmation.
#

# This script uses real bash features (arrays) and needs to run under
# bash, not /bin/sh - on plenty of rescue environments (including
# alpine-rescue) /bin/sh is BusyBox ash, which ignores the shebang above
# entirely when invoked as `sh alpine-install-zfs.sh` and fails with a
# confusing "syntax error: unexpected (" deep in the file instead of a
# clear message. Rather than just tell whoever's already fighting a
# rescue console to go retype the command, re-exec under bash
# automatically - this check runs fine under ash BEFORE it ever reaches
# the array syntax further down (verified: ash parses/executes
# top-to-bottom, not the whole file upfront), so `exec` here works
# regardless of which shell actually launched this script. PUBKEY and
# every other env var set as a `VAR=val command` prefix are already in
# this process's environment by the time this line runs, and `exec`
# preserves the environment across the re-exec - nothing gets lost.
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "ERROR: This script requires bash, and bash was not found on this system. Install it (e.g. apk add bash) and re-run." >&2
    exit 1
fi

set -Eeuo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

# Required configuration.
PUBKEY="${PUBKEY:-}"
SYSDRIVE="${SYSDRIVE:-/dev/sda}"
ARCH="$(uname -m)"

# Optional configuration.
SYSHOSTNAME="${SYSHOSTNAME:-alpine}"
ALPINE_BRANCH=""
# Leave empty to auto-detect Alpine's own current latest-stable release at
# run time (see resolve_alpine_version()) - set it explicitly to pin a
# specific release instead.
ALPINE_VERSION="${ALPINE_VERSION:-}"

# Name of the ZFS pool this script creates. "zroot" matches the name
# ZFSBootMenu's own docs and most root-on-ZFS guides use by convention -
# change it only if you already have another pool by that name imported
# (e.g. multiple ZFS-root machines managed from the same rescue session).
POOL_NAME="${POOL_NAME:-zroot}"
ROOT_DATASET="${POOL_NAME}/ROOT/alpine"
MOUNT_LOCATION="/mnt/alpine"
USE_SERIAL="${USE_SERIAL:-no}"
SWAP_SIZE_GIB="${SWAP_SIZE_GIB:-2}"

# "auto" (default) guesses from a CPUID hypervisor flag / ARM
# hypervisor device-tree node / DMI vendor strings - see detect_virt()
# below. It's a heuristic, not a certainty (nested virt, unusual DMI
# vendors, etc. can fool it) - force "yes" or "no" if you already know
# which one you want. "yes" installs linux-virt (smaller, faster kernel,
# no real-hardware driver bloat); "no" installs linux-lts (real disk/GPU/
# NIC drivers, for bare metal).
VIRT="${VIRT:-auto}"

# "auto" (default) detects /sys/firmware/efi and picks yes/no accordingly.
# Force "yes" or "no" to override detection - "yes" on a BIOS-only rescue
# boot still dies with a clear error rather than silently doing the wrong
# thing; "no" on aarch64 (no legacy BIOS exists there) always dies.
USE_UEFI="${USE_UEFI:-auto}"

# Every EFI image below is built by this repo itself
# (.github/workflows/build-zbm-images.yml) - one per arch, not split by
# console type. The kernel command line it's built with lists both
# console=tty0 and a serial console, so a single image covers VGA and
# serial; ZFSBootMenu's own docs don't confirm whether the interactive
# menu itself works on both at once (only that kernel messages go to
# both) - untested in practice as of this writing. Low-stakes to find
# out empirically: the *-latest-* URLs below always resolve to whichever
# GitHub Release is currently marked latest, so a bad build just needs a
# new release, no script change.
#
# BIOS mode's separate kernel+initramfs Components pair is also built
# and published there. Its output filenames aren't something upstream
# defines either (their own build.yml just globs "not *.EFI"), so the
# workflow picks them out by the vmlinu*/initr* substring every such
# file has - if that guess is ever wrong for some future ZFSBootMenu
# version, the fix is a one-line rename in the workflow, not here.
ZBM_X86_64_URL="https://github.com/unidoc/alpine-installer/releases/latest/download/zfsbootmenu-x86_64.EFI"
ZBM_AARCH64_URL="https://github.com/unidoc/alpine-installer/releases/latest/download/zfsbootmenu-aarch64.EFI"
ZBM_VMLINUZ_X86_64_URL="https://github.com/unidoc/alpine-installer/releases/latest/download/zfsbootmenu-vmlinuz"
ZBM_INITRAMFS_X86_64_URL="https://github.com/unidoc/alpine-installer/releases/latest/download/zfsbootmenu-initramfs.img"
ZBM_EFI_URL="${ZBM_EFI_URL:-}"
ZBM_EFI_FILE="${ZBM_EFI_FILE:-}"
ZBM_VMLINUZ_URL="${ZBM_VMLINUZ_URL:-}"
ZBM_VMLINUZ_FILE="${ZBM_VMLINUZ_FILE:-}"
ZBM_INITRAMFS_URL="${ZBM_INITRAMFS_URL:-}"
ZBM_INITRAMFS_FILE="${ZBM_INITRAMFS_FILE:-}"

# Published alongside our own EFI/Components builds - the Alpine rootfs
# gets a sha256 check a few lines below (fetch_rootfs()); these are the
# actual bootloader, so they get one too. Only covers our own default
# *_URL values - a custom ZBM_EFI_URL/ZBM_VMLINUZ_URL/ZBM_INITRAMFS_URL
# pointing somewhere else (e.g. upstream's get.zfsbootmenu.org/efi) has
# no entry in it, so verify_zbm_checksum() skips with a warning instead
# of failing - we can't vouch for a URL we don't control.
ZBM_CHECKSUMS_URL="https://github.com/unidoc/alpine-installer/releases/latest/download/SHA256SUMS"

ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"

# Populated by resolve_alpine_version() / partition_disk() /
# format_boot_partition() / create_swap() / select_zbm_artifacts() as the
# install proceeds.
ROOTFS_FILE=""
ROOTFS_URL=""
ROOTFS_SHA256_URL=""
EFI_PARTITION=""
SWAP_PARTITION=""
ZFS_PARTITION=""
BIOS_BOOT_PARTITION=""
EFI_FALLBACK_NAME=""
KERNEL_FLAVOR=""
KERNEL_PACKAGE=""
ZFS_KMOD_PACKAGE=""
KERNEL_CONSOLE=""
efi_uuid=""
swap_uuid=""
WORKDIR=""

# ==============================================================================
# Helpers
# ==============================================================================

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    set +e

    if mountpoint -q "${MOUNT_LOCATION}/boot/efi" 2>/dev/null; then
        umount "${MOUNT_LOCATION}/boot/efi"
    fi

    for path in run dev proc sys; do
        if mountpoint -q "${MOUNT_LOCATION}/${path}" 2>/dev/null; then
            umount -l "${MOUNT_LOCATION}/${path}"
        fi
    done

    # grep -c, not -q: -q closes its input as soon as it finds a match,
    # which can SIGPIPE zpool if it's still writing - under pipefail
    # that makes the pipeline report failure even though grep DID find
    # the pool, so `if ... | grep -q; then` can silently take the wrong
    # branch (confirmed this exact failure mode elsewhere in this
    # script, see resolve_alpine_version()). grep -c always reads to
    # EOF, so it can't trigger this.
    if [ "$(zpool list -H -o name 2>/dev/null | grep -cx "${POOL_NAME}")" -gt 0 ]; then
        zpool export "${POOL_NAME}"
    fi

    if [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ]; then
        rm -rf "${WORKDIR}"
    fi
}
trap cleanup EXIT

partition_path() {
    local disk="$1"
    local number="$2"

    case "${disk}" in
        *[0-9])
            printf '%sp%s\n' "${disk}" "${number}"
            ;;
        *)
            printf '%s%s\n' "${disk}" "${number}"
            ;;
    esac
}

_apk_updated=0
ensure_apk_updated() {
    [ "${_apk_updated}" -eq 1 ] && return 0
    apk update >/dev/null 2>&1
    _apk_updated=1
}

# Some rescue images don't ship every tool this script needs by default
# (gptfdisk/sgdisk in particular, seen missing on a real alpine-rescue
# boot even though this is a ZFS-focused rescue image) - install it
# automatically rather than making the operator do it by hand on every
# single run. Best-effort only: if apk isn't available, there's no
# network, or the package genuinely doesn't provide the command, the
# command -v recheck in require_command() below still catches it and
# dies with a clear message either way.
apk_package_for_command() {
    case "$1" in
        sgdisk) echo "gptfdisk" ;;
        mkfs.vfat) echo "dosfstools" ;;
        zfs|zpool|zgenhostid) echo "zfs" ;;
        *) echo "" ;;
    esac
}

require_command() {
    command -v "$1" >/dev/null 2>&1 && return 0

    local pkg
    pkg="$(apk_package_for_command "$1")"
    if [ -n "${pkg}" ] && command -v apk >/dev/null 2>&1; then
        log "Missing command: $1 - installing package '${pkg}'"
        ensure_apk_updated
        apk add --quiet "${pkg}" >/dev/null 2>&1 || true
    fi

    command -v "$1" >/dev/null 2>&1 ||
        die "Missing required command: $1${pkg:+ (tried apk add ${pkg}, still missing - check network/apk repositories)}"
}

wait_for_device() {
    local device="$1"
    local attempt

    for attempt in $(seq 1 20); do
        [ -b "${device}" ] && return 0
        sleep 1
    done

    die "Device did not appear: ${device}"
}

# Deliberately loose: real key-type prefixes only, no attempt to fully
# validate base64 payloads - this exists to catch "pasted the wrong thing"
# (a private key, a path, an empty string) not to be a full parser.
looks_like_pubkey() {
    case "$1" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ecdsa-sha2-*\ *|sk-ssh-ed25519\ *)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Verifies a downloaded file against our own published SHA256SUMS, by
# basename. Silently (well - loudly logged, not fatal) skips verification
# if the checksums file can't be fetched or has no entry for this
# basename - that's expected for a custom, non-default ZBM_*_URL we don't
# control. A checksum entry that IS found but doesn't match is always
# fatal: that means either a corrupted download or a compromised
# artifact, and this file is about to become the system's bootloader.
verify_zbm_checksum() {
    local file="$1" name="$2" sums_file
    sums_file="$(mktemp)"

    if ! curl --fail --silent --location --output "${sums_file}" "${ZBM_CHECKSUMS_URL}" 2>/dev/null; then
        log "Could not fetch SHA256SUMS - skipping checksum verification for ${name}"
        rm -f "${sums_file}"
        return 0
    fi

    if ! grep -q "  ${name}\$" "${sums_file}"; then
        log "No checksum entry for ${name} in SHA256SUMS - skipping verification"
        rm -f "${sums_file}"
        return 0
    fi

    (cd "$(dirname "${file}")" && grep "  ${name}\$" "${sums_file}" | sha256sum -c -) ||
        die "Checksum mismatch for ${name} - the downloaded ZFSBootMenu artifact does not match what this repo published. Refusing to install a boot image that doesn't match its own checksum."
    rm -f "${sums_file}"
}

# Best-effort, not authoritative - covers the common cases (KVM/Xen-HVM/
# VMware/VirtualBox/Hyper-V on x86, QEMU's ARM "virt" machine, most cloud
# DMI vendor strings on either arch) without needing any extra package.
# Known real false-positive: AWS *.metal and GCP bare-metal instance
# types are documented to still report the same "Amazon EC2"/"Google
# Compute Engine" DMI strings as their virtualized siblings, even though
# nothing is virtualized - VIRT=auto would wrongly pick linux-virt
# (limited real-hardware drivers) there. Force VIRT=no explicitly on
# those instance types.
detect_virt() {
    if [ -r /proc/cpuinfo ] && grep -qw hypervisor /proc/cpuinfo 2>/dev/null; then
        return 0
    fi
    if [ -e /proc/device-tree/hypervisor/compatible ]; then
        return 0
    fi
    local dmi_file
    for dmi_file in /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name; do
        if [ -r "${dmi_file}" ]; then
            case "$(cat "${dmi_file}" 2>/dev/null)" in
                *QEMU*|*KVM*|*VirtualBox*|*VMware*|*Xen*|*"Microsoft Corporation"*|*"Google Compute Engine"*|*"Amazon EC2"*|*Bochs*|*OpenStack*|*DigitalOcean*|*innotek*)
                    return 0
                    ;;
            esac
        fi
    done
    return 1
}

# ==============================================================================
# Install phases
# ==============================================================================

validate_environment() {
    [ "$(id -u)" -eq 0 ] || die "Run this script as root."

    if [ -z "${PUBKEY}" ]; then
        die "PUBKEY is not set. Export PUBKEY=\"ssh-ed25519 AAAA... you@host\" (one or more newline-separated key lines) and re-run. There is no default key - this installer refuses to run without one."
    fi
    local key_line found_key=0
    while IFS= read -r key_line; do
        [ -z "${key_line}" ] && continue
        looks_like_pubkey "${key_line}" ||
            die "PUBKEY does not look like an SSH public key line: '${key_line}'. Expected something starting with ssh-ed25519, ssh-rsa, ecdsa-sha2-*, or sk-*."
        found_key=1
    done <<EOF
${PUBKEY}
EOF
    [ "${found_key}" -eq 1 ] ||
        die "PUBKEY is set but contains no actual key line (blank/whitespace only). There is no default key - this installer refuses to run without one."

    [ -n "${SYSHOSTNAME}" ] || die "SYSHOSTNAME is empty."
    [ -b "${SYSDRIVE}" ] || die "SYSDRIVE is not a block device: ${SYSDRIVE}"

    case "${ARCH}" in
        x86_64|aarch64)
            ;;
        *)
            die "Unsupported ARCH: ${ARCH}. Supported values: x86_64 and aarch64."
            ;;
    esac

    case "${VIRT}" in
        auto)
            if detect_virt; then
                VIRT="yes"
            else
                VIRT="no"
            fi
            log "VIRT=auto detected VIRT=${VIRT}"
            ;;
        yes|no)
            ;;
        *)
            die "Unsupported VIRT: ${VIRT}. Supported values: auto, yes, and no."
            ;;
    esac
    case "${VIRT}" in
        yes)
            KERNEL_FLAVOR="virt"
            ;;
        no)
            KERNEL_FLAVOR="lts"
            ;;
    esac
    KERNEL_PACKAGE="linux-${KERNEL_FLAVOR}"
    ZFS_KMOD_PACKAGE="zfs-${KERNEL_FLAVOR}"

    case "${USE_UEFI}" in
        auto)
            if [ -d /sys/firmware/efi ]; then
                USE_UEFI="yes"
            else
                USE_UEFI="no"
            fi
            ;;
        yes|no)
            ;;
        *)
            die "Unsupported USE_UEFI: ${USE_UEFI}. Supported values: auto, yes, and no."
            ;;
    esac
    if [ "${ARCH}" = "aarch64" ] && [ "${USE_UEFI}" = "no" ]; then
        die "aarch64 has no legacy BIOS boot path; USE_UEFI=no is only valid for x86_64."
    fi

    case "${SWAP_SIZE_GIB}" in
        ''|*[!0-9]*)
            die "SWAP_SIZE_GIB must be a non-negative integer, got: ${SWAP_SIZE_GIB}"
            ;;
    esac

    case "${USE_SERIAL}" in
        yes|no) ;;
        # Not just an enum check: USE_SERIAL's value is spliced verbatim
        # into the unquoted heredoc that generates chroot-install-script.sh
        # (see write_chroot_install_script()) and later executed as root
        # inside the chroot. An unvalidated value there is a real command
        # injection, not just a bad-input inconvenience.
        *) die "Unsupported USE_SERIAL: ${USE_SERIAL}. Supported values: yes and no." ;;
    esac

    if [ "${USE_UEFI}" = "yes" ]; then
        [ -d /sys/firmware/efi ] || die "The rescue system was not booted in UEFI mode."
    fi

    for command in \
        awk blkid chroot curl getent grep install lsblk mkfs.vfat mktemp \
        modprobe mount mountpoint mkswap od partprobe sha256sum sgdisk tar \
        tr umount wipefs zfs zgenhostid zpool
    do
        require_command "${command}"
    done

    getent hosts dl-cdn.alpinelinux.org >/dev/null 2>&1 ||
        die "Unable to resolve dl-cdn.alpinelinux.org."

    modprobe zfs
    grep -qw zfs /proc/filesystems ||
        die "The ZFS kernel module is not available."
}

# Sets ALPINE_BRANCH/ALPINE_VERSION (if not already pinned) and the
# rootfs download URLs derived from them.
resolve_alpine_version() {
    if [ -z "${ALPINE_VERSION}" ]; then
        log "Looking up Alpine's latest stable release"
        # curl's own failure has to be caught explicitly like this
        # (inside an `if !`), not by assigning straight into
        # ALPINE_VERSION and relying on the `[ -n ... ] || die` below -
        # under `set -Eeuo pipefail`, a failing command inside a plain
        # `var="$(cmd)"` assignment aborts the script immediately at
        # that line (verified empirically), never reaching the "was it
        # empty" check at all. That silently killed the whole install
        # with no error message on a real run where the mirror was
        # unreachable - just two log lines, then back to the prompt.
        local latest_releases
        if ! latest_releases="$(curl -fsSL "${ALPINE_MIRROR}/latest-stable/releases/${ARCH}/latest-releases.yaml")"; then
            die "Could not reach ${ALPINE_MIRROR} to look up Alpine's latest stable release - check network connectivity, or set ALPINE_VERSION= explicitly to skip this lookup."
        fi
        # The `|| true` is load-bearing, not decoration: confirmed on a
        # real alpine-rescue boot (BusyBox sed/head) that this pipeline
        # can report a nonzero exit status even though ALPINE_VERSION
        # gets the right value - `head -1` closes its input as soon as
        # it has one line, and if sed is still writing more matches (this
        # YAML has one "version:" line per release flavor) the resulting
        # SIGPIPE makes sed exit nonzero, which pipefail then reports as
        # the whole pipeline failing. Under set -e that killed the script
        # right here with zero output, even on a fully successful lookup
        # - the `[ -n ... ] || die` immediately below is what actually
        # validates the result; this pipeline's own exit status isn't a
        # meaningful signal either way once curl itself is already
        # confirmed to have succeeded above.
        ALPINE_VERSION="$(printf '%s\n' "${latest_releases}" | sed -n 's/^  version: //p' | head -1)" || true
        [ -n "${ALPINE_VERSION}" ] ||
            die "Could not determine Alpine's latest stable version from the fetched data. Set ALPINE_VERSION= explicitly and re-run."
    fi
    ALPINE_BRANCH="v$(printf '%s' "${ALPINE_VERSION}" | cut -d. -f1,2)"

    ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}-${ARCH}.tar.gz"
    ROOTFS_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ARCH}/${ROOTFS_FILE}"
    ROOTFS_SHA256_URL="${ROOTFS_URL}.sha256"
}

# Sets EFI_FALLBACK_NAME always; resolves either the EFI-bundle URL/file
# (USE_UEFI=yes) or the Components kernel+initramfs URLs (USE_UEFI=no).
select_zbm_artifacts() {
    case "${ARCH}" in
        x86_64)
            EFI_FALLBACK_NAME="BOOTX64.EFI"
            ;;
        aarch64)
            EFI_FALLBACK_NAME="BOOTAA64.EFI"
            ;;
    esac

    if [ "${USE_UEFI}" = "yes" ]; then
        if [ -n "${ZBM_EFI_URL}" ] || [ -n "${ZBM_EFI_FILE}" ]; then
            return 0
        fi
        case "${ARCH}" in
            x86_64) ZBM_EFI_URL="${ZBM_X86_64_URL}" ;;
            aarch64) ZBM_EFI_URL="${ZBM_AARCH64_URL}" ;;
        esac
    else
        if [ -z "${ZBM_VMLINUZ_URL}" ] && [ -z "${ZBM_VMLINUZ_FILE}" ]; then
            ZBM_VMLINUZ_URL="${ZBM_VMLINUZ_X86_64_URL}"
        fi
        if [ -z "${ZBM_INITRAMFS_URL}" ] && [ -z "${ZBM_INITRAMFS_FILE}" ]; then
            ZBM_INITRAMFS_URL="${ZBM_INITRAMFS_X86_64_URL}"
        fi
    fi
}

partition_disk() {
    EFI_PARTITION="$(partition_path "${SYSDRIVE}" 1)"
    SWAP_PARTITION="$(partition_path "${SYSDRIVE}" 2)"
    ZFS_PARTITION="$(partition_path "${SYSDRIVE}" 3)"
    if [ "${USE_UEFI}" = "no" ]; then
        BIOS_BOOT_PARTITION="$(partition_path "${SYSDRIVE}" 4)"
    fi

    log "Installation target"
    lsblk "${SYSDRIVE}"
    log "Destroying all data on ${SYSDRIVE}"

    mkdir -p "${MOUNT_LOCATION}"

    if mountpoint -q "${MOUNT_LOCATION}" 2>/dev/null; then
        umount -R "${MOUNT_LOCATION}" || true
    fi

    # grep -c, not -q: -q closes its input as soon as it finds a match,
    # which can SIGPIPE zpool if it's still writing - under pipefail
    # that makes the pipeline report failure even though grep DID find
    # the pool, so `if ... | grep -q; then` can silently take the wrong
    # branch (confirmed this exact failure mode elsewhere in this
    # script, see resolve_alpine_version()). grep -c always reads to
    # EOF, so it can't trigger this.
    if [ "$(zpool list -H -o name 2>/dev/null | grep -cx "${POOL_NAME}")" -gt 0 ]; then
        zpool export "${POOL_NAME}"
    fi

    zpool labelclear -f "${ZFS_PARTITION}" 2>/dev/null || true
    wipefs -a "${SYSDRIVE}"
    sgdisk --zap-all "${SYSDRIVE}"

    log "Creating GPT partitions"
    local -a sgdisk_args
    sgdisk_args=( -n 1:1MiB:+512MiB -t 1:EF00 -c 1:EFI )
    if [ "${SWAP_SIZE_GIB}" -gt 0 ]; then
        sgdisk_args+=( -n 2:0:+"${SWAP_SIZE_GIB}"GiB -t 2:8200 -c 2:SWAP )
    else
        sgdisk_args+=( -n 2:0:+1MiB -t 2:8200 -c 2:SWAP )
    fi
    sgdisk_args+=( -n 3:0:-10MiB -t 3:BF00 -c 3:ZFS )
    if [ "${USE_UEFI}" = "no" ]; then
        sgdisk_args+=( -n 4:0:+1MiB -t 4:EF02 -c 4:BIOSBOOT )
    fi
    sgdisk "${sgdisk_args[@]}" "${SYSDRIVE}"

    partprobe "${SYSDRIVE}" || true
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true
    command -v mdev >/dev/null 2>&1 && mdev -s || true

    wait_for_device "${EFI_PARTITION}"
    wait_for_device "${SWAP_PARTITION}"
    wait_for_device "${ZFS_PARTITION}"
    if [ -n "${BIOS_BOOT_PARTITION}" ]; then
        wait_for_device "${BIOS_BOOT_PARTITION}"
    fi
}

create_swap() {
    if [ "${SWAP_SIZE_GIB}" -eq 0 ]; then
        log "Skipping swap (SWAP_SIZE_GIB=0) - the swap partition slot still exists on disk (see the layout comment at the top of this file) but is left unformatted and unused"
        return 0
    fi
    log "Creating swap"
    mkswap -L swap "${SWAP_PARTITION}"
    swap_uuid="$(blkid -s UUID -o value "${SWAP_PARTITION}")"
}

create_zpool() {
    log "Creating ZFS pool"
    zpool create -f \
        -o compatibility=openzfs-2.2-linux \
        -o ashift=12 \
        -o autotrim=off \
        -O acltype=posixacl \
        -O atime=off \
        -O compression=lz4 \
        -O normalization=formD \
        -O xattr=sa \
        -m none \
        "${POOL_NAME}" "${ZFS_PARTITION}"

    zfs create -o mountpoint=none -o canmount=off "${POOL_NAME}/ROOT"
    zfs create -o mountpoint=/ -o canmount=noauto "${ROOT_DATASET}"
    zfs create -o mountpoint=/home "${POOL_NAME}/home"
    zfs create -o mountpoint=/var "${POOL_NAME}/var"
    zfs create -o mountpoint=/var/log "${POOL_NAME}/var/log"
    zpool set bootfs="${ROOT_DATASET}" "${POOL_NAME}"

    # KERNEL_CONSOLE feeds both the org.zfsbootmenu:commandline property
    # below (governs the console once ZBM chainloads into Alpine) and, in
    # BIOS mode, the GRUB menuentry that boots ZBM itself - always set it,
    # regardless of USE_SERIAL, so later reuse never hits an unbound var.
    local kernel_console_serial
    case "${ARCH}" in
        x86_64)
            kernel_console_serial="console=ttyS0,115200n8"
            ;;
        aarch64)
            kernel_console_serial="console=ttyAMA0,115200n8"
            ;;
    esac

    if [ "${USE_SERIAL}" = "yes" ]; then
        KERNEL_CONSOLE="${kernel_console_serial}"
    else
        KERNEL_CONSOLE="console=tty0"
    fi

    zfs set org.zfsbootmenu:commandline="${KERNEL_CONSOLE} net.ifnames=0" \
        "${POOL_NAME}/ROOT"
}

import_pool() {
    log "Importing pool under ${MOUNT_LOCATION}"
    zpool export "${POOL_NAME}"
    zpool import -N -R "${MOUNT_LOCATION}" "${POOL_NAME}"
    zfs mount "${ROOT_DATASET}"
    zfs mount "${POOL_NAME}/home"
    zfs mount "${POOL_NAME}/var"
    zfs mount "${POOL_NAME}/var/log"
}

fetch_rootfs() {
    log "Downloading Alpine ${ALPINE_VERSION} root filesystem"
    WORKDIR="$(mktemp -d)"

    curl --fail --location \
        --output "${WORKDIR}/${ROOTFS_FILE}" \
        "${ROOTFS_URL}"

    curl --fail --location \
        --output "${WORKDIR}/${ROOTFS_FILE}.sha256" \
        "${ROOTFS_SHA256_URL}"

    (
        cd "${WORKDIR}"
        sha256sum -c "${ROOTFS_FILE}.sha256"
    )

    tar -xzf "${WORKDIR}/${ROOTFS_FILE}" -C "${MOUNT_LOCATION}"
}

write_base_config() {
    log "Preparing base configuration"
    cat > "${MOUNT_LOCATION}/etc/apk/repositories" <<EOF
${ALPINE_MIRROR}/${ALPINE_BRANCH}/main
${ALPINE_MIRROR}/${ALPINE_BRANCH}/community
EOF

    cat > "${MOUNT_LOCATION}/etc/resolv.conf" <<'EOF'
nameserver 8.8.8.8
nameserver 2001:4860:4860::8844
EOF

    printf '%s\n' "${SYSHOSTNAME}" > "${MOUNT_LOCATION}/etc/hostname"

    cat > "${MOUNT_LOCATION}/etc/hosts" <<EOF
127.0.0.1       ${SYSHOSTNAME} localhost localhost.localdomain
::1             ${SYSHOSTNAME} localhost localhost.localdomain
EOF

    printf 'Welcome to %s\n' "${SYSHOSTNAME}" > "${MOUNT_LOCATION}/etc/motd"

    install -d -m 0700 "${MOUNT_LOCATION}/root/.ssh"
    printf '%s\n' "${PUBKEY}" > "${MOUNT_LOCATION}/root/.ssh/authorized_keys"
    chmod 0600 "${MOUNT_LOCATION}/root/.ssh/authorized_keys"
}

create_hostid() {
    log "Creating host ID"
    local hostid_hex
    hostid_hex="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
    zgenhostid -f "0x${hostid_hex}"
    cp /etc/hostid "${MOUNT_LOCATION}/etc/hostid"
}

format_boot_partition() {
    log "Formatting EFI System Partition"
    mkfs.vfat -F32 -n EFI "${EFI_PARTITION}"
    efi_uuid="$(blkid -s UUID -o value "${EFI_PARTITION}")"

    mkdir -p "${MOUNT_LOCATION}/boot/efi"
    mount "${EFI_PARTITION}" "${MOUNT_LOCATION}/boot/efi"
}

write_fstab() {
    cat > "${MOUNT_LOCATION}/etc/fstab" <<EOF
UUID=${efi_uuid} /boot/efi vfat defaults,noauto,noatime 0 2
EOF
    if [ "${SWAP_SIZE_GIB}" -gt 0 ]; then
        printf 'UUID=%s none swap sw 0 0\n' "${swap_uuid}" >> "${MOUNT_LOCATION}/etc/fstab"
    fi
    cat >> "${MOUNT_LOCATION}/etc/fstab" <<'EOF'
proc /proc proc defaults,hidepid=2 0 0
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF
}

install_acpi_handler() {
    log "Installing ACPI power-button handler"
    install -d -m 0755 "${MOUNT_LOCATION}/etc/acpi/handlers"
    install -d -m 0755 "${MOUNT_LOCATION}/etc/acpi/events"

    cat > "${MOUNT_LOCATION}/etc/acpi/events/anything" <<'EOF'
event=.*
action=/etc/acpi/handlers/power-button.sh %e
EOF

    cat > "${MOUNT_LOCATION}/etc/acpi/handlers/power-button.sh" <<'EOF'
#!/bin/sh

PATH="/usr/share/acpid:$PATH"
alias log='logger -t acpid'

case "$1:$2:$3:$4" in
    button/power:*)
        log "Power button pressed - shutting down"
        poweroff
        ;;
esac

exit 0
EOF

    chmod 0755 "${MOUNT_LOCATION}/etc/acpi/handlers/power-button.sh"
}

mount_chroot_filesystems() {
    log "Mounting chroot filesystems"
    mount -t proc proc "${MOUNT_LOCATION}/proc"
    mount -t sysfs sys "${MOUNT_LOCATION}/sys"
    mount --rbind /dev "${MOUNT_LOCATION}/dev"
    mount --make-rslave "${MOUNT_LOCATION}/dev"
    mount --rbind /run "${MOUNT_LOCATION}/run"
    mount --make-rslave "${MOUNT_LOCATION}/run"
}

write_chroot_install_script() {
    cat > "${MOUNT_LOCATION}/chroot-install-script.sh" <<EOF
#!/bin/sh
set -eu

apk update
apk upgrade

apk add \
    alpine-base \
    acpid \
    bash \
    chrony \
    curl \
    dosfstools \
    e2fsprogs \
    ${KERNEL_PACKAGE} \
    ncurses-terminfo \
    openrc \
    openssh \
    openssh-server \
    shadow \
    sudo \
    vim \
    wget \
    whois \
    zfs \
    zfs-openrc \
    zfs-scripts \
    ${ZFS_KMOD_PACKAGE}

echo 'LANG=en_US.UTF-8' > /etc/profile.d/locale.sh

rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit
rc-update add hwdrivers sysinit
rc-update add zfs-import sysinit
rc-update add zfs-mount sysinit

rc-update add hwclock boot
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add networking boot
rc-update add swap boot
rc-update add acpid boot

rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown

rc-update add crond default
rc-update add chronyd default
rc-update add sshd default
rc-update add zfs-zed default

echo button >> /etc/modules

setup-timezone UTC

# Root's password is deliberately left EMPTY, not set and not locked -
# shadow(5) is explicit that an empty password field means "no password
# required" for whoever authenticates that way. Combined with the sshd
# drop-in below (PermitEmptyPasswords no, which is also OpenSSH's own
# compiled-in default - stated here so this doesn't silently depend on
# that default never changing), that means: a real physical/KVM console
# login prompt lets root in with no password at all (run \`passwd\` there
# to set a real one), while sshd refuses to ever accept that same empty
# password over the network - only the PUBKEY installed above works over
# SSH until someone does that. This is the persistent-install equivalent
# of alpine-rescue's locked-root pattern; alpine-rescue gets away with
# never touching /etc/shadow because its live image auto-logs into the
# console without checking a password at all, so there's nothing to
# clear there - a real install's console runs a normal login prompt,
# so it has to be told explicitly.
passwd -d root

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/local.conf <<'SSHDEOF'
PermitRootLogin yes
PermitEmptyPasswords no
PasswordAuthentication yes
PubkeyAuthentication yes
SSHDEOF
chmod 0644 /etc/ssh/sshd_config.d/local.conf

getent passwd sshd >/dev/null || adduser -h / -s /sbin/nologin -S sshd

mkdir -p /etc/mkinitfs/features.d
echo /etc/hostid > /etc/mkinitfs/features.d/zfshost.files
echo 'features="ata base keymap scsi usb virtio nvme zfs zfshost"' > /etc/mkinitfs/mkinitfs.conf

kernel_path="\$(find /lib/modules -mindepth 1 -maxdepth 1 -type d | head -n1)"
[ -n "\${kernel_path}" ]
kernel_version="\$(basename "\${kernel_path}")"
mkinitfs -c /etc/mkinitfs/mkinitfs.conf "\${kernel_version}"

if [ "${USE_SERIAL}" = "yes" ]; then
    case "${ARCH}" in
        x86_64)
            sed -i '/^[#]\\?ttyS0/s/^#//' /etc/inittab
            ;;
        aarch64)
            sed -i '/^[#]\\?ttyAMA0/s/^#//' /etc/inittab
            ;;
    esac
fi

if [ "${USE_UEFI}" = "no" ]; then
    apk add grub grub-bios
    grub-install --target=i386-pc --boot-directory=/boot/efi "${SYSDRIVE}"
fi

rm -f /chroot-install-script.sh
EOF

    chmod 0755 "${MOUNT_LOCATION}/chroot-install-script.sh"
}

run_chroot_install() {
    log "Installing Alpine packages"
    chroot "${MOUNT_LOCATION}" /bin/sh /chroot-install-script.sh
}

install_zfsbootmenu_uefi() {
    mkdir -p "${MOUNT_LOCATION}/boot/efi/EFI/ZBM"
    mkdir -p "${MOUNT_LOCATION}/boot/efi/EFI/BOOT"

    if [ -n "${ZBM_EFI_FILE}" ]; then
        [ -f "${ZBM_EFI_FILE}" ] ||
            die "Missing ZFSBootMenu EFI file: ${ZBM_EFI_FILE}"

        cp "${ZBM_EFI_FILE}" \
            "${MOUNT_LOCATION}/boot/efi/EFI/ZBM/VMLINUZ.EFI"
    else
        curl --fail --location \
            --output "${MOUNT_LOCATION}/boot/efi/EFI/ZBM/VMLINUZ.EFI" \
            "${ZBM_EFI_URL}"
        verify_zbm_checksum "${MOUNT_LOCATION}/boot/efi/EFI/ZBM/VMLINUZ.EFI" "$(basename "${ZBM_EFI_URL}")"
    fi

    cp "${MOUNT_LOCATION}/boot/efi/EFI/ZBM/VMLINUZ.EFI" \
       "${MOUNT_LOCATION}/boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI"

    cp "${MOUNT_LOCATION}/boot/efi/EFI/ZBM/VMLINUZ.EFI" \
       "${MOUNT_LOCATION}/boot/efi/EFI/BOOT/${EFI_FALLBACK_NAME}"
}

# GRUB itself (package + grub-install) was already handled inside the
# chroot by write_chroot_install_script(). This only fetches the ZBM
# Components (kernel+initramfs) onto the vfat partition GRUB reads, and
# writes the grub.cfg that chainloads them - both plain host-side file
# operations, no chroot needed.
install_zfsbootmenu_bios() {
    if [ -n "${ZBM_VMLINUZ_FILE}" ]; then
        [ -f "${ZBM_VMLINUZ_FILE}" ] ||
            die "Missing ZFSBootMenu kernel file: ${ZBM_VMLINUZ_FILE}"

        cp "${ZBM_VMLINUZ_FILE}" "${MOUNT_LOCATION}/boot/efi/vmlinuz-bootmenu"
    else
        curl --fail --location \
            --output "${MOUNT_LOCATION}/boot/efi/vmlinuz-bootmenu" \
            "${ZBM_VMLINUZ_URL}"
        verify_zbm_checksum "${MOUNT_LOCATION}/boot/efi/vmlinuz-bootmenu" "$(basename "${ZBM_VMLINUZ_URL}")"
    fi

    if [ -n "${ZBM_INITRAMFS_FILE}" ]; then
        [ -f "${ZBM_INITRAMFS_FILE}" ] ||
            die "Missing ZFSBootMenu initramfs file: ${ZBM_INITRAMFS_FILE}"

        cp "${ZBM_INITRAMFS_FILE}" "${MOUNT_LOCATION}/boot/efi/initramfs-bootmenu.img"
    else
        curl --fail --location \
            --output "${MOUNT_LOCATION}/boot/efi/initramfs-bootmenu.img" \
            "${ZBM_INITRAMFS_URL}"
        verify_zbm_checksum "${MOUNT_LOCATION}/boot/efi/initramfs-bootmenu.img" "$(basename "${ZBM_INITRAMFS_URL}")"
    fi

    cp "${MOUNT_LOCATION}/boot/efi/vmlinuz-bootmenu" \
       "${MOUNT_LOCATION}/boot/efi/vmlinuz-bootmenu-backup"

    cp "${MOUNT_LOCATION}/boot/efi/initramfs-bootmenu.img" \
       "${MOUNT_LOCATION}/boot/efi/initramfs-bootmenu-backup.img"

    mkdir -p "${MOUNT_LOCATION}/boot/efi/grub"
    cat > "${MOUNT_LOCATION}/boot/efi/grub/grub.cfg" <<EOF
set timeout=5

menuentry "ZFSBootMenu" {
    search --no-floppy --fs-uuid --set=root ${efi_uuid}
    linux /vmlinuz-bootmenu zfsbootmenu quiet ${KERNEL_CONSOLE}
    initrd /initramfs-bootmenu.img
}

menuentry "ZFSBootMenu (backup)" {
    search --no-floppy --fs-uuid --set=root ${efi_uuid}
    linux /vmlinuz-bootmenu-backup zfsbootmenu quiet ${KERNEL_CONSOLE}
    initrd /initramfs-bootmenu-backup.img
}
EOF
}

install_zfsbootmenu() {
    log "Installing ZFSBootMenu"
    if [ "${USE_UEFI}" = "yes" ]; then
        install_zfsbootmenu_uefi
    else
        install_zfsbootmenu_bios
    fi
}

verify_installation() {
    log "Validating installation"
    test -f "${MOUNT_LOCATION}/boot/vmlinuz-${KERNEL_FLAVOR}" ||
        die "Missing Alpine ${KERNEL_FLAVOR} kernel."

    test -f "${MOUNT_LOCATION}/boot/initramfs-${KERNEL_FLAVOR}" ||
        die "Missing Alpine initramfs."

    if [ "${USE_UEFI}" = "yes" ]; then
        test -f "${MOUNT_LOCATION}/boot/efi/EFI/BOOT/${EFI_FALLBACK_NAME}" ||
            die "Missing portable ZFSBootMenu EFI executable."
    else
        test -f "${MOUNT_LOCATION}/boot/efi/vmlinuz-bootmenu" ||
            die "Missing ZFSBootMenu kernel (Components)."

        test -f "${MOUNT_LOCATION}/boot/efi/initramfs-bootmenu.img" ||
            die "Missing ZFSBootMenu initramfs (Components)."

        test -f "${MOUNT_LOCATION}/boot/efi/grub/grub.cfg" ||
            die "Missing GRUB configuration."
    fi

    test -f "${MOUNT_LOCATION}/etc/hostid" ||
        die "Missing /etc/hostid."

    if [ "${SWAP_SIZE_GIB}" -gt 0 ]; then
        # grep -c, not -q - see the comment on the zpool checks in
        # cleanup()/partition_disk() for why -q's early-close-on-match
        # behavior is unsafe piped from a command under pipefail.
        [ "$(blkid "${SWAP_PARTITION}" | grep -c 'TYPE="swap"')" -gt 0 ] ||
            die "Swap partition is invalid."
    fi

    test -d "${MOUNT_LOCATION}/var/empty" ||
        die "Missing /var/empty; /var dataset was not populated correctly."

    zpool status "${POOL_NAME}"
    zfs list -r "${POOL_NAME}"
}

print_summary() {
    local boot_summary
    if [ "${USE_UEFI}" = "yes" ]; then
        boot_summary="ZFSBootMenu is installed at EFI/BOOT/${EFI_FALLBACK_NAME}."
    else
        boot_summary="ZFSBootMenu boots via GRUB (legacy BIOS) from /boot/efi/grub/grub.cfg."
    fi

    log "Installation completed successfully"
    printf '%s\n' \
        "Alpine ${ALPINE_VERSION} is installed on ${ROOT_DATASET}." \
        "${boot_summary}" \
        "SSH: key-only (your PUBKEY), root has no password. Log in at the" \
        "real console and run 'passwd' there to also enable SSH password login." \
        "Exit the rescue environment and reboot."
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    validate_environment
    resolve_alpine_version
    select_zbm_artifacts
    partition_disk
    create_swap
    create_zpool
    import_pool
    fetch_rootfs
    write_base_config
    create_hostid
    format_boot_partition
    write_fstab
    install_acpi_handler
    mount_chroot_filesystems
    write_chroot_install_script
    run_chroot_install
    install_zfsbootmenu
    verify_installation
    print_summary

    trap - EXIT
    cleanup
}

main "$@"
