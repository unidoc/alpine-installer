#!/bin/bash
#
# Install Alpine Linux with GRUB and a plain (non-ZFS) root from a rescue
# system - alpine-install-zfs.sh (this repo) is the ZFS counterpart, kept
# as a separate script rather than merged: ZFS gets one opinionated
# layout, this one is meant to flex.
#
# Target:
#   - x86_64 or aarch64
#   - BIOS (msdos) or UEFI (GPT)
#   - single disk
#   - Alpine Linux, latest stable by default (see ALPINE_VERSION below)
#   - linux-virt or linux-lts (see VIRT below)
#   - ext4 root, optionally on top of LVM (USE_LVM)
#
# Disk layout (each row optional per config, in this order):
#   [EFI System Partition, 256 MiB - only if USE_UEFI=yes]
#   [swap, SWAP_SIZE_GIB - only if SWAP_SIZE_GIB > 0, default 0/off]
#   root - remaining space (a plain partition, or an LVM PV -> vg0/root
#          if USE_LVM=yes)
#
# WARNING: This script destroys all data on SYSDRIVE without confirmation.
#

# This script uses real bash features (arrays) and needs to run under
# bash, not /bin/sh - on plenty of rescue environments (including
# alpine-rescue) /bin/sh is BusyBox ash, which ignores the shebang above
# entirely when invoked as `sh alpine-install-normal.sh` and fails with a
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

# "auto" (default) checks the rescue system's OWN kernel command line
# for console=ttyS0 (x86_64) / console=ttyAMA0 (aarch64) - see
# detect_serial() below. Deliberately not "check the live tty" (e.g.
# `tty` or $SSH_TTY): if this rescue session is reached over SSH, the
# controlling tty is a pts that says nothing about which physical/
# remote-console channel will actually be available after reboot, since
# SSH isn't available that early in boot. What the rescue kernel itself
# was told to use as a console is a much better signal - a bare-metal/
# VPS host with no VGA almost always has its rescue image booted with
# console=ttyS0 for exactly the same reason the installed system will
# need it too. Still a heuristic - force "yes"/"no" if you already know.
USE_SERIAL="${USE_SERIAL:-auto}"
USE_UEFI="${USE_UEFI:-auto}"

# "auto" (default) guesses from a CPUID hypervisor flag / ARM hypervisor
# device-tree node / DMI vendor strings - see detect_virt() below. It's a
# heuristic, not a certainty - force "yes" or "no" if you already know
# which one you want. "yes" installs linux-virt (smaller, faster kernel,
# no real-hardware driver bloat); "no" installs linux-lts (real disk/GPU/
# NIC drivers, for bare metal).
VIRT="${VIRT:-auto}"
KERNEL_FLAVOR=""
KERNEL_PACKAGE=""

MOUNT_LOCATION="/mnt/alpine"

# 0 disables swap entirely (default - most cloud/VM hosts already provide
# swap another way, or the operator wants none). Set to a positive whole
# number of GiB to carve out a dedicated swap partition instead.
SWAP_SIZE_GIB="${SWAP_SIZE_GIB:-0}"

# "yes" puts root on an LVM logical volume (vg0/root, one PV, one LV
# spanning the whole VG) instead of directly on the raw partition. This
# is intentionally the one bit of "flexibility" this script offers beyond
# swap on/off - if you want a genuinely custom multi-LV or multi-PV
# layout, partition and pvcreate/vgcreate/lvcreate yourself first, then
# point ROOT_PARTITION at the resulting /dev/vgX/lvY and set
# SKIP_PARTITIONING=yes too. With SKIP_PARTITIONING=yes, USE_LVM=yes
# never runs pvcreate/vgcreate/lvcreate itself (it would destroy your
# existing volume) - it only makes sure lvm2 and mkinitfs's "lvm" feature
# get installed, since ROOT_PARTITION already IS the final LV at that
# point. Still set USE_LVM=yes in that case - otherwise this script has
# no way to know your root needs LVM support at boot at all.
USE_LVM="${USE_LVM:-no}"
LVM_VG_NAME="${LVM_VG_NAME:-vg0}"
LVM_LV_NAME="${LVM_LV_NAME:-root}"

# "yes" skips partition_disk() entirely and uses EFI_PARTITION/
# ROOT_PARTITION/SWAP_PARTITION exactly as given - for operators who
# already partitioned the disk their own way and just want the rest of
# the install (rootfs, packages, bootloader, credentials model) done for
# them. Not validated beyond "is it a block device" - a partition table
# that doesn't actually match USE_UEFI's assumptions (e.g. an
# EFI_PARTITION with no ESP type-GUID, or a GPT disk with no bios_grub
# gap for USE_UEFI=no) fails later, inside the chroot, not here.
SKIP_PARTITIONING="${SKIP_PARTITIONING:-no}"

ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"

# Populated by resolve_alpine_version() / partition_disk() as the install
# proceeds. Pre-set EFI_PARTITION/ROOT_PARTITION yourself when
# SKIP_PARTITIONING=yes.
ROOTFS_FILE=""
ROOTFS_URL=""
ROOTFS_SHA256_URL=""
EFI_PARTITION="${EFI_PARTITION:-}"
SWAP_PARTITION="${SWAP_PARTITION:-}"
ROOT_PARTITION="${ROOT_PARTITION:-}"
EFI_FALLBACK_NAME=""
WORKDIR=""
efi_uuid=""
swap_uuid=""
root_uuid=""

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

    for path in boot/efi run dev proc sys; do
        if mountpoint -q "${MOUNT_LOCATION}/${path}" 2>/dev/null; then
            umount -l "${MOUNT_LOCATION}/${path}"
        fi
    done

    if mountpoint -q "${MOUNT_LOCATION}" 2>/dev/null; then
        umount "${MOUNT_LOCATION}"
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

# Some rescue images don't ship every tool this script needs by default -
# install it automatically rather than making the operator do it by hand
# on every single run. Best-effort only: if apk isn't available, there's
# no network, or the package genuinely doesn't provide the command, the
# command -v recheck in require_command() below still catches it and
# dies with a clear message either way.
apk_package_for_command() {
    case "$1" in
        # Not actually used by this script (it partitions with parted,
        # not sgdisk) - kept only so this function stays identical to
        # alpine-install-zfs.sh's. Alpine packages this as plain
        # "sgdisk", not "gptfdisk" (the upstream/Debian package name).
        sgdisk) echo "sgdisk" ;;
        mkfs.vfat) echo "dosfstools" ;;
        mkfs.ext4) echo "e2fsprogs" ;;
        parted) echo "parted" ;;
        pvcreate|vgcreate|lvcreate) echo "lvm2" ;;
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

# Best-effort: see the USE_SERIAL comment above for why this checks the
# rescue system's own boot-time console= setting rather than the live
# tty.
detect_serial() {
    local cmdline serial_dev
    [ -r /proc/cmdline ] || return 1
    cmdline="$(cat /proc/cmdline)"
    case "${ARCH}" in
        x86_64) serial_dev="ttyS" ;;
        aarch64) serial_dev="ttyAMA" ;;
        *) return 1 ;;
    esac
    case " ${cmdline} " in
        *" console=${serial_dev}"*) return 0 ;;
        *) return 1 ;;
    esac
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
        x86_64)
            EFI_FALLBACK_NAME="BOOTX64.EFI"
            ;;
        aarch64)
            EFI_FALLBACK_NAME="BOOTAA64.EFI"
            ;;
        *)
            die "Unsupported ARCH: ${ARCH}. Supported values: x86_64 and aarch64."
            ;;
    esac

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
    if [ "${USE_UEFI}" = "yes" ]; then
        [ -d /sys/firmware/efi ] ||
            die "USE_UEFI=yes but the rescue system was not booted in UEFI mode."
    fi

    case "${SWAP_SIZE_GIB}" in
        ''|*[!0-9]*)
            die "SWAP_SIZE_GIB must be a non-negative integer, got: ${SWAP_SIZE_GIB}"
            ;;
    esac

    case "${USE_SERIAL}" in
        auto)
            if detect_serial; then
                USE_SERIAL="yes"
            else
                USE_SERIAL="no"
            fi
            log "USE_SERIAL=auto detected USE_SERIAL=${USE_SERIAL}"
            ;;
        yes|no) ;;
        # Not just an enum check: USE_SERIAL's value is spliced verbatim
        # into the unquoted heredoc that generates chroot-install-script.sh
        # (see write_chroot_install_script()) and later executed as root
        # inside the chroot. An unvalidated value there is a real command
        # injection, not just a bad-input inconvenience - resolving
        # "auto" to a literal yes/no above, before this check, keeps
        # that guarantee intact.
        *) die "Unsupported USE_SERIAL: ${USE_SERIAL}. Supported values: auto, yes, and no." ;;
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
        yes) KERNEL_FLAVOR="virt" ;;
        no) KERNEL_FLAVOR="lts" ;;
    esac
    KERNEL_PACKAGE="linux-${KERNEL_FLAVOR}"

    case "${USE_LVM}" in
        yes|no) ;;
        *) die "Unsupported USE_LVM: ${USE_LVM}. Supported values: yes and no." ;;
    esac

    case "${SKIP_PARTITIONING}" in
        yes)
            [ -b "${ROOT_PARTITION}" ] ||
                die "SKIP_PARTITIONING=yes requires ROOT_PARTITION to already point at an existing block device (partition or LV)."
            if [ "${USE_UEFI}" = "yes" ]; then
                [ -b "${EFI_PARTITION}" ] ||
                    die "SKIP_PARTITIONING=yes with USE_UEFI=yes requires EFI_PARTITION to already point at an existing block device."
            fi
            if [ "${SWAP_SIZE_GIB}" -gt 0 ]; then
                [ -b "${SWAP_PARTITION}" ] ||
                    die "SKIP_PARTITIONING=yes with SWAP_SIZE_GIB>0 requires SWAP_PARTITION to already point at an existing block device."
            fi
            ;;
        no) ;;
        *) die "Unsupported SKIP_PARTITIONING: ${SKIP_PARTITIONING}. Supported values: yes and no." ;;
    esac

    [ "$(uname -m)" = "${ARCH}" ] || die "ARCH=${ARCH} does not match rescue architecture $(uname -m)."

    local -a required_commands=(
        awk blkid chroot curl getent grep install mkfs.ext4 mkfs.vfat
        mktemp mount mountpoint parted partprobe sed sha256sum tar umount
        wipefs
    )
    if [ "${USE_LVM}" = "yes" ]; then
        required_commands+=(pvcreate vgcreate lvcreate)
    fi
    if [ "${SKIP_PARTITIONING}" = "no" ]; then
        :
    fi
    for command in "${required_commands[@]}"; do
        require_command "${command}"
    done

    getent hosts dl-cdn.alpinelinux.org >/dev/null 2>&1 ||
        die "Unable to resolve dl-cdn.alpinelinux.org."
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

partition_disk() {
    if [ "${SKIP_PARTITIONING}" = "yes" ]; then
        log "SKIP_PARTITIONING=yes - using pre-existing partitions as given"
        lsblk "${SYSDRIVE}"
        return 0
    fi

    log "Installation target"
    lsblk "${SYSDRIVE}"
    log "Destroying all data on ${SYSDRIVE}"

    mkdir -p "${MOUNT_LOCATION}"

    if mountpoint -q "${MOUNT_LOCATION}" 2>/dev/null; then
        umount -R "${MOUNT_LOCATION}" || true
    fi

    wipefs -a "${SYSDRIVE}"

    # Build the partition list in disk order: [efi] [swap] root - each
    # optional per config except root. Ends are cumulative MiB offsets;
    # "-1" means "rest of the disk" (parted's own convention).
    local -a part_names=() part_ends=() part_flags=()
    local offset=1

    if [ "${USE_UEFI}" = "yes" ]; then
        offset=$((offset + 256))
        part_names+=("efi"); part_ends+=("${offset}"); part_flags+=("esp")
    fi
    if [ "${SWAP_SIZE_GIB}" -gt 0 ]; then
        offset=$((offset + SWAP_SIZE_GIB * 1024))
        part_names+=("swap"); part_ends+=("${offset}"); part_flags+=("")
    fi
    part_names+=("root"); part_ends+=("-1")
    if [ "${USE_UEFI}" = "no" ]; then
        part_flags+=("boot")
    else
        part_flags+=("")
    fi

    log "Creating partitions"
    local -a parted_args=(-s -a optimal "${SYSDRIVE}" unit mib)
    if [ "${USE_UEFI}" = "yes" ]; then
        parted_args+=(mklabel gpt)
    else
        parted_args+=(mklabel msdos)
    fi

    local i=0 start=1 fstype
    while [ "${i}" -lt "${#part_names[@]}" ]; do
        case "${part_names[$i]}" in
            efi) fstype="fat32" ;;
            swap) fstype="linux-swap" ;;
            root) fstype="ext4" ;;
        esac
        parted_args+=(mkpart primary "${fstype}" "${start}" "${part_ends[$i]}")
        # parted's "name" subcommand only works on GPT (and Mac/PC98)
        # labels - msdos partition tables have no concept of a partition
        # name and parted errors out on it. Since USE_UEFI=no selects
        # msdos a few lines up, this has to be conditional or every
        # legacy-BIOS install fails here - after wipefs has already
        # destroyed the disk's previous partition table.
        if [ "${USE_UEFI}" = "yes" ]; then
            parted_args+=(name "$((i + 1))" "${part_names[$i]}")
        fi
        if [ -n "${part_flags[$i]}" ]; then
            parted_args+=(set "$((i + 1))" "${part_flags[$i]}" on)
        fi
        start="${part_ends[$i]}"
        i=$((i + 1))
    done

    parted "${parted_args[@]}"

    partprobe "${SYSDRIVE}" || true
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true
    command -v mdev >/dev/null 2>&1 && mdev -s || true

    i=0
    while [ "${i}" -lt "${#part_names[@]}" ]; do
        local dev
        dev="$(partition_path "${SYSDRIVE}" "$((i + 1))")"
        wait_for_device "${dev}"
        case "${part_names[$i]}" in
            efi) EFI_PARTITION="${dev}" ;;
            swap) SWAP_PARTITION="${dev}" ;;
            root) ROOT_PARTITION="${dev}" ;;
        esac
        i=$((i + 1))
    done
}

setup_lvm() {
    [ "${USE_LVM}" = "yes" ] || return 0

    if [ "${SKIP_PARTITIONING}" = "yes" ]; then
        # Never pvcreate/vgcreate/lvcreate here when the operator already
        # partitioned (and possibly already LVM'd) the disk themselves -
        # `pvcreate -f` would silently destroy/reformat their existing
        # volume as a nested PV. USE_LVM=yes + SKIP_PARTITIONING=yes means
        # "ROOT_PARTITION already IS the final LV, just make sure lvm2 and
        # mkinitfs's lvm feature get installed" (see write_chroot_install_script()) -
        # nothing to create here.
        log "SKIP_PARTITIONING=yes - using ${ROOT_PARTITION} as the pre-existing LV, not creating a new PV/VG/LV"
        return 0
    fi

    log "Creating LVM volume group ${LVM_VG_NAME} and logical volume ${LVM_LV_NAME}"
    pvcreate -f "${ROOT_PARTITION}"
    vgcreate "${LVM_VG_NAME}" "${ROOT_PARTITION}"
    lvcreate -n "${LVM_LV_NAME}" -l 100%FREE "${LVM_VG_NAME}"

    ROOT_PARTITION="/dev/${LVM_VG_NAME}/${LVM_LV_NAME}"
    wait_for_device "${ROOT_PARTITION}"
}

format_root() {
    log "Formatting root partition"
    mkfs.ext4 -F "${ROOT_PARTITION}"
    mount "${ROOT_PARTITION}" "${MOUNT_LOCATION}"
    root_uuid="$(blkid -s UUID -o value "${ROOT_PARTITION}")"
}

create_swap() {
    [ "${SWAP_SIZE_GIB}" -gt 0 ] || return 0
    log "Creating swap"
    mkswap -L swap "${SWAP_PARTITION}"
    swap_uuid="$(blkid -s UUID -o value "${SWAP_PARTITION}")"
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

write_bootloader_config() {
    log "Preparing GRUB configuration"
    local grub_linux_normal grub_linux_serial
    grub_linux_normal="net.ifnames=0 modules=virtio_mmio,usbkbd,ext4 rootfstype=ext4"
    grub_linux_serial="${grub_linux_normal} console=ttyS0,115200n8"

    if [ "${ARCH}" = "aarch64" ]; then
        # No serial console handling for aarch64 here; fall back to tty0/ttyAMA0.
        grub_linux_normal="${grub_linux_normal} console=ttyAMA0 console=tty0"
    fi

    if [ "${USE_SERIAL}" = "yes" ]; then
        cat > "${MOUNT_LOCATION}/root/grub.conf" <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=Alpine
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="${grub_linux_serial}"
GRUB_TERMINAL=serial
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF
    else
        cat > "${MOUNT_LOCATION}/root/grub.conf" <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=Alpine
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="${grub_linux_normal}"
GRUB_TERMINAL=console
EOF
    fi

    log "Preparing bootloader installer"
    if [ "${USE_UEFI}" = "yes" ]; then
        cat > "${MOUNT_LOCATION}/root/install-bootloader.sh" <<'EOF'
#!/bin/sh
set -eu
apk add grub grub-efi
grub-install --efi-directory=/boot/efi --removable
EOF
    else
        cat > "${MOUNT_LOCATION}/root/install-bootloader.sh" <<EOF
#!/bin/sh
set -eu
apk add grub grub-bios
grub-install ${SYSDRIVE}
EOF
    fi
    chmod 0755 "${MOUNT_LOCATION}/root/install-bootloader.sh"
}

write_fstab() {
    cat > "${MOUNT_LOCATION}/etc/fstab" <<EOF
UUID=${root_uuid} / ext4 defaults 0 1
EOF
    if [ "${SWAP_SIZE_GIB}" -gt 0 ]; then
        printf 'UUID=%s none swap sw 0 0\n' "${swap_uuid}" >> "${MOUNT_LOCATION}/etc/fstab"
    fi
    cat >> "${MOUNT_LOCATION}/etc/fstab" <<'EOF'
proc /proc proc defaults,hidepid=2 0 0
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF

    if [ "${USE_UEFI}" = "yes" ]; then
        log "Formatting EFI System Partition"
        mkfs.vfat -F32 -n EFI "${EFI_PARTITION}"
        efi_uuid="$(blkid -s UUID -o value "${EFI_PARTITION}")"

        mkdir -p "${MOUNT_LOCATION}/boot/efi"
        mount "${EFI_PARTITION}" "${MOUNT_LOCATION}/boot/efi"

        printf 'UUID=%s /boot/efi vfat defaults,noauto,noatime 0 2\n' "${efi_uuid}" \
            >> "${MOUNT_LOCATION}/etc/fstab"
    fi
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
    local lvm_package="" lvm_feature=""
    if [ "${USE_LVM}" = "yes" ]; then
        lvm_package="lvm2"
        lvm_feature=" lvm"
    fi

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
    ${lvm_package}

echo 'LANG=en_US.UTF-8' > /etc/profile.d/locale.sh

sh /root/install-bootloader.sh
rm -f /root/install-bootloader.sh
mv -f /root/grub.conf /etc/default/grub

mkdir -p /etc/mkinitfs/features.d
which /sbin/fsck.ext4 > /etc/mkinitfs/features.d/alpine-installer.files
which /sbin/fsck.vfat >> /etc/mkinitfs/features.d/alpine-installer.files
sed -i 's/^features="/features="alpine-installer${lvm_feature} /' /etc/mkinitfs/mkinitfs.conf

kernel_path="\$(find /lib/modules -mindepth 1 -maxdepth 1 -type d | head -n1)"
[ -n "\${kernel_path}" ]
kernel_version="\$(basename "\${kernel_path}")"
mkinitfs -c /etc/mkinitfs/mkinitfs.conf "\${kernel_version}"

update-grub

rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit
rc-update add hwdrivers sysinit

rc-update add hwclock boot
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add networking boot
rc-update add acpid boot
EOF
    if [ "${SWAP_SIZE_GIB}" -gt 0 ]; then
        printf 'rc-update add swap boot\n' >> "${MOUNT_LOCATION}/chroot-install-script.sh"
    fi
    cat >> "${MOUNT_LOCATION}/chroot-install-script.sh" <<EOF

rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown

rc-update add crond default
rc-update add chronyd default
rc-update add sshd default

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
# SSH until someone does that.
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

if [ "${USE_SERIAL}" = "yes" ]; then
    sed -i '/^[#]\\?ttyS0/s/^#//' /etc/inittab
fi

rm -f /chroot-install-script.sh
EOF

    chmod 0755 "${MOUNT_LOCATION}/chroot-install-script.sh"
}

run_chroot_install() {
    log "Installing Alpine packages"
    chroot "${MOUNT_LOCATION}" /bin/sh /chroot-install-script.sh
}

verify_installation() {
    log "Validating installation"
    test -f "${MOUNT_LOCATION}/boot/vmlinuz-${KERNEL_FLAVOR}" ||
        die "Missing Alpine ${KERNEL_FLAVOR} kernel."

    test -f "${MOUNT_LOCATION}/boot/initramfs-${KERNEL_FLAVOR}" ||
        die "Missing Alpine initramfs."

    test -f "${MOUNT_LOCATION}/boot/grub/grub.cfg" ||
        die "Missing /boot/grub/grub.cfg; GRUB installation may have failed."

    if [ "${USE_UEFI}" = "yes" ]; then
        test -f "${MOUNT_LOCATION}/boot/efi/EFI/BOOT/${EFI_FALLBACK_NAME}" ||
            die "Missing portable GRUB EFI executable."
    fi

    if [ "${SWAP_SIZE_GIB}" -gt 0 ]; then
        # grep -c, not -q - -q closes its input as soon as it finds a
        # match, which can SIGPIPE the upstream command; under pipefail
        # that makes the pipeline report failure even on a real match
        # (confirmed as a real, silent-crash-causing bug elsewhere in
        # this codebase's resolve_alpine_version() on a real BusyBox
        # system - not hypothetical). grep -c always reads to EOF.
        [ "$(blkid "${SWAP_PARTITION}" | grep -c 'TYPE="swap"')" -gt 0 ] ||
            die "Swap partition is invalid."
    fi
}

print_summary() {
    log "Installation completed successfully"
    printf '%s\n' \
        "Alpine ${ALPINE_VERSION} is installed on ${ROOT_PARTITION}$( [ "${USE_LVM}" = "yes" ] && printf ' (LVM: %s/%s)' "${LVM_VG_NAME}" "${LVM_LV_NAME}" )." \
        "GRUB is installed ($( [ "${USE_UEFI}" = "yes" ] && echo UEFI || echo BIOS ))." \
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
    partition_disk
    setup_lvm
    format_root
    create_swap
    fetch_rootfs
    write_base_config
    write_bootloader_config
    write_fstab
    install_acpi_handler
    mount_chroot_filesystems
    write_chroot_install_script
    run_chroot_install
    verify_installation
    print_summary

    trap - EXIT
    cleanup
}

main "$@"
