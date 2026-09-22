#!/bin/bash
#
# Install Alpine Linux with ZFS root and alpine-zfsboot from a rescue system.
#
# Target:
#   - x86_64 or aarch64
#   - UEFI, or legacy BIOS (x86_64 only - aarch64 has no legacy BIOS equivalent
#     at all). USE_UEFI="auto" (default) detects /sys/firmware/efi; force
#     "yes"/"no" to override. BIOS mode uses alpine-zfsboot's own from-scratch
#     stage1/stage2 boot code (see the alpine-zfsboot repo's bios/ directory) -
#     no third-party bootloader dependency at all, unlike an earlier version
#     of this script.
#   - single disk
#   - Alpine Linux, latest stable by default (see ALPINE_VERSION below)
#   - linux-virt + zfs-virt
#   - unencrypted ZFS root by default; ENCRYPT_ZROOT=yes (+ ZROOT_PASSPHRASE)
#     makes the ROOT hierarchy natively encrypted instead - see that
#     variable's own comment below for exactly what that does and does
#     not cover
#
# Disk layout:
#   UEFI mode:
#     1: 512 MiB EFI System Partition - holds alpine-zfsboot's own
#        self-contained .EFI (kernel+initramfs+cmdline all bundled into one
#        file - see the alpine-zfsboot repo's build.sh) at the standard
#        removable-media fallback path, so any UEFI firmware finds it with no
#        NVRAM boot entry needed.
#     2: swap (SWAP_SIZE_GIB, default 2 GiB - set to 0 to skip it entirely)
#     3: remaining space for ZFS
#   BIOS mode (USE_UEFI=no):
#     1: 32 KiB-and-a-bit "BIOS boot" partition (GPT type EF02, the standard
#        GPT type code for this purpose) at a FIXED
#        starting LBA (34, immediately after the GPT header + partition
#        array) - alpine-zfsboot's stage1 (the protective-MBR boot sector)
#        does a raw, unconditional fixed-LBA read here with no GPT parsing at
#        all, so this partition's start position is a hard, load-bearing
#        build-time invariant, not a convention this script can freely
#        rearrange. Holds stage2 (real GPT-parsing + Linux boot-protocol
#        code).
#     2: alpine-zfsboot's own "boot blob" (header + kernel + initrd +
#        cmdline, packed by its own build.sh) - a dedicated GPT partition
#        found by TYPE GUID (not position - see gpt.h in the alpine-zfsboot
#        repo), sized to the actual downloaded bootblob file plus a little
#        headroom.
#     3: swap (SWAP_SIZE_GIB, default 2 GiB - set to 0 to skip it entirely)
#     4: remaining space for ZFS
#     No EFI System Partition at all in this mode - alpine-zfsboot's BIOS
#     path has no filesystem code whatsoever, only raw sector reads, so
#     there's nothing here that would ever read one.
#   BIOS mode, DISK_LAYOUT=msdos (also USE_UEFI=no - see DISK_LAYOUT's own
#   comment): the SAME two BIOS-only entries above, on a classic 4-primary-
#   partition MBR/msdos partition table (via sfdisk) instead of GPT (via
#   sgdisk) - alpine-zfsboot's own stage2 auto-detects which one is
#   actually on the disk at real boot time (see bios/stage2_main.c/mbr.h in
#   that repo) and finds the boot-blob the matching way either way, so this
#   is a second, real, equally-supported target, not a degraded fallback:
#     1: stage2, at the SAME fixed LBA 34 stage1.S always reads regardless
#        of partitioning scheme - given a REAL, typed (but functionally
#        unread-by-any-code - see ALPINE_ZFSBOOT_STAGE2_MBR_TYPE's own
#        comment) primary partition entry here too, purely so it's visible
#        to `fdisk -l`/`sfdisk -d` instead of sitting in a partition-table-
#        invisible gap.
#     2: boot blob - found by MBR partition TYPE BYTE this time (not GPT
#        type GUID - see ALPINE_ZFSBOOT_BOOTBLOB_MBR_TYPE, and bios/mbr.h's
#        own mbr_find_partition()), same file, same packing, same sizing
#        as the GPT case.
#     3: swap
#     4: remaining space for ZFS
#   Exactly 4 primary partitions, deliberately - a classic MBR has room for
#   no more than that without an extended/logical partition chain, which
#   this project has no need for and does not support.
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

# Name of the ZFS pool this script creates. "zroot" matches this project's
# own convention (see alpine-zfsboot's own menu.py) - change it only if you
# already have another pool by that name imported (e.g. multiple ZFS-root
# machines managed from the same rescue session).
POOL_NAME="${POOL_NAME:-zroot}"
ROOT_DATASET="${POOL_NAME}/ROOT/alpine"
MOUNT_LOCATION="/mnt/alpine"

# "auto" (default) checks the rescue system's OWN kernel command line
# for console=ttyS0 (x86_64) / console=ttyAMA0 (aarch64) - see
# detect_serial() below. Deliberately not "check the live tty" (e.g.
# `tty` or $SSH_TTY): if this rescue session is reached over SSH, the
# controlling tty is a pts that says nothing about which physical/
# remote-console channel will actually be available to interact with
# alpine-zfsboot's own menu after reboot, since SSH isn't available that
# early in boot. What the rescue kernel itself was told to use as a console
# is a much better signal - a bare-metal/VPS host with no VGA almost always
# has its rescue image booted with console=ttyS0 for exactly the same
# reason the installed system will need it too. Still a heuristic -
# force "yes"/"no" if you already know.
USE_SERIAL="${USE_SERIAL:-auto}"
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

# "gpt" (default) - this project's own primary, sgdisk-based layout (see
# this file's own disk-layout comment above). "msdos" is a SECOND, real
# disk-layout option for the SAME USE_UEFI=no BIOS boot code, using a
# classic 4-primary-partition MBR/msdos partition table instead of GPT -
# only valid combined with USE_UEFI=no (there is no msdos+UEFI path in
# this project at all: UEFI firmware needs a GPT+ESP layout, full stop).
# alpine-zfsboot's own stage2 (see the repo's bios/stage2_main.c) already
# auto-detects which of the two is actually on the disk at real boot time
# (a valid GPT header at LBA 1, or else a classic MBR partition table) and
# finds the boot-blob partition the matching way either way - see
# bios/mbr.h's own header comment for the full design reasoning. This
# variable only controls which one THIS install actually WRITES; nothing
# here is a fallback for the other at runtime, both are real, supported,
# first-class targets.
DISK_LAYOUT="${DISK_LAYOUT:-gpt}"

# "no" (default) - the ROOT hierarchy (${POOL_NAME}/ROOT and every boot
# environment under it, current and future) is created unencrypted, as
# always. "yes" makes ${POOL_NAME}/ROOT itself the ZFS "encryption root"
# (encryption=aes-256-gcm, keyformat=passphrase, keylocation=prompt) -
# every dataset created under it, including ${ROOT_DATASET} (this
# install's own boot environment) AND every future boot environment
# menu.py's own "Clone a snapshot into a new boot environment" creates
# later, inherits that SAME encryption root and key automatically (ZFS
# clones always share their origin snapshot's encryption root - there is
# no per-BE re-encryption or separate passphrase to manage). One
# passphrase, entered once at boot (see init/boot-dataset.sh's and
# menu.py's own ensure_key_loaded() - both already fully support this,
# unmodified, via the standard encryptionroot/keystatus/keylocation ZFS
# properties), unlocks the whole ROOT hierarchy every time, present and
# future BEs alike. ${POOL_NAME}/home, ${POOL_NAME}/var, and
# ${POOL_NAME}/var/log are deliberately NOT under ${POOL_NAME}/ROOT (see
# create_zfs_datasets() below) and stay unencrypted either way - only the
# actual OS root is in scope here, not persistent user/log data.
ENCRYPT_ZROOT="${ENCRYPT_ZROOT:-no}"
# Required, and only meaningful, when ENCRYPT_ZROOT=yes. This installer
# runs fully unattended (see PUBKEY's own comment above for the same
# reasoning) - there is no interactive prompt mid-install to fall back
# on, so the passphrase has to arrive the same way every other setting
# here does: as an env var, read once by create_zfs_datasets() and piped
# to `zfs create`'s stdin (keylocation=prompt reads from stdin when it
# isn't a real tty - the same mechanism boot-dataset.sh's own `zfs
# load-key` relies on later, at every boot). Never put on a command
# line (would be visible in `ps` on this multi-user rescue system) and
# never logged.
ZROOT_PASSPHRASE="${ZROOT_PASSPHRASE:-}"

# Per-machine alpine-zfsboot rescue/network settings, persisted to the
# ESP (/EFI/alpine-zfsboot/ - see write_alpine_zfsboot_esp_config()
# below) rather than baked into the .EFI binary itself: EXTRA_CMDLINE
# (see alpine-zfsboot's own build.sh) is build-time only, and this
# project ships ONE generic .EFI shared across an entire fleet, not a
# per-machine artifact - a compiled-in key would mean rebuilding and
# redeploying every image just to rotate one compromised rescue key.
# Most of these are uppercase mirrors of the exact alpine-zfsboot.*
# cmdline keys /init itself parses (see that file's own
# apply_zfsboot_kv()) - same names, same vocabulary, one spelling to
# keep in sync across both repos. All optional; nothing here is
# required for a plain, non-rescue install.
#
# ALPINE_ZFSBOOT_SSH_KEY is the one exception to the cmdline-mirror
# rule above - it has no alpine-zfsboot.* cmdline equivalent at all.
# Takes a RAW pubkey line (or several, newline-separated, exactly like
# PUBKEY above) and this installer writes it verbatim as
# /EFI/alpine-zfsboot/authorized_keys - one BARE key per line, no
# base64, no invented config-key representation, but also NOT full
# OpenSSH authorized_keys syntax: /init only ever accepts a line that
# starts directly with a known key type, so operator-supplied options
# (from=, restrict, expiry-time=, ...) would be rejected outright, not
# silently honored - alpine-zfsboot stays the sole owner of what
# restrictions apply (see rescue-ssh.sh's own header comment for why:
# an earlier version of this DID have a
# alpine-zfsboot.ssh_key=<base64 pubkey> cmdline/config key, removed in
# favor of this plain file once a real hardware test motivated it).
# write_alpine_zfsboot_esp_config() also generates this machine's own
# persistent /EFI/alpine-zfsboot/ssh_host_ed25519_key alongside it,
# whenever this variable is set.
ALPINE_ZFSBOOT_SSH_KEY="${ALPINE_ZFSBOOT_SSH_KEY:-}"
ALPINE_ZFSBOOT_NET="${ALPINE_ZFSBOOT_NET:-}"
ALPINE_ZFSBOOT_IPV4="${ALPINE_ZFSBOOT_IPV4:-}"
ALPINE_ZFSBOOT_IPV4_ADDRESS="${ALPINE_ZFSBOOT_IPV4_ADDRESS:-}"
ALPINE_ZFSBOOT_IPV4_GATEWAY="${ALPINE_ZFSBOOT_IPV4_GATEWAY:-}"
ALPINE_ZFSBOOT_IPV6="${ALPINE_ZFSBOOT_IPV6:-}"
ALPINE_ZFSBOOT_IPV6_ADDRESS="${ALPINE_ZFSBOOT_IPV6_ADDRESS:-}"
ALPINE_ZFSBOOT_IPV6_GATEWAY="${ALPINE_ZFSBOOT_IPV6_GATEWAY:-}"
ALPINE_ZFSBOOT_SSH_LISTEN="${ALPINE_ZFSBOOT_SSH_LISTEN:-}"
ALPINE_ZFSBOOT_SSH_PORT="${ALPINE_ZFSBOOT_SSH_PORT:-}"
ALPINE_ZFSBOOT_SSH_ALLOW="${ALPINE_ZFSBOOT_SSH_ALLOW:-}"

# alpine-zfsboot artifacts - defaults point at alpine-zfsboot's own real
# GitHub release now (v0.1.0 shipped). releases/latest/download/... is
# deliberately what both repos use, not a pinned version tag: asset
# filenames are arch-based and unversioned by design (see the
# alpine-zfsboot repo's own release.yml comment), so this URL never needs
# to change again as new releases ship - a bad build just needs a new
# release, not a script change here. Override any of these to point at a
# specific version/mirror instead, or a local *_FILE path to skip
# downloading entirely.
#
# UEFI: one self-contained .EFI (kernel+initramfs+cmdline all bundled in -
# see alpine-zfsboot's own build.sh - nothing else to fetch).
ALPINE_ZFSBOOT_EFI_X86_64_URL="${ALPINE_ZFSBOOT_EFI_X86_64_URL:-https://github.com/unidoc/alpine-zfsboot/releases/latest/download/alpine-zfsboot-x86_64.EFI}"
ALPINE_ZFSBOOT_EFI_AARCH64_URL="${ALPINE_ZFSBOOT_EFI_AARCH64_URL:-https://github.com/unidoc/alpine-zfsboot/releases/latest/download/alpine-zfsboot-aarch64.EFI}"
ALPINE_ZFSBOOT_EFI_URL="${ALPINE_ZFSBOOT_EFI_URL:-}"
ALPINE_ZFSBOOT_EFI_FILE="${ALPINE_ZFSBOOT_EFI_FILE:-}"

# BIOS mode (x86_64 only): stage1 (the protective-MBR boot sector), stage2
# (real GPT-parsing + Linux boot-protocol code), and the boot blob (kernel +
# initramfs + cmdline, packed by alpine-zfsboot's own build.sh). See this
# file's own disk-layout comment above for how each of these actually gets
# placed on disk.
ALPINE_ZFSBOOT_BIOS_STAGE1_URL="${ALPINE_ZFSBOOT_BIOS_STAGE1_URL:-https://github.com/unidoc/alpine-zfsboot/releases/latest/download/alpine-zfsboot-x86_64-bios-stage1.bin}"
ALPINE_ZFSBOOT_BIOS_STAGE2_URL="${ALPINE_ZFSBOOT_BIOS_STAGE2_URL:-https://github.com/unidoc/alpine-zfsboot/releases/latest/download/alpine-zfsboot-x86_64-bios-stage2.bin}"
ALPINE_ZFSBOOT_BIOS_BOOTBLOB_URL="${ALPINE_ZFSBOOT_BIOS_BOOTBLOB_URL:-https://github.com/unidoc/alpine-zfsboot/releases/latest/download/alpine-zfsboot-x86_64-bios-bootblob.img}"
ALPINE_ZFSBOOT_BIOS_STAGE1_FILE="${ALPINE_ZFSBOOT_BIOS_STAGE1_FILE:-}"
ALPINE_ZFSBOOT_BIOS_STAGE2_FILE="${ALPINE_ZFSBOOT_BIOS_STAGE2_FILE:-}"
ALPINE_ZFSBOOT_BIOS_BOOTBLOB_FILE="${ALPINE_ZFSBOOT_BIOS_BOOTBLOB_FILE:-}"

# Checked the same way the Alpine rootfs itself is (fetch_rootfs()); a
# missing/unreachable checksums file only skips verification with a
# warning, it never fails the install outright, since a custom
# ALPINE_ZFSBOOT_*_URL pointing somewhere this project doesn't control has no
# entry to check against either way.
ALPINE_ZFSBOOT_CHECKSUMS_URL="${ALPINE_ZFSBOOT_CHECKSUMS_URL:-https://github.com/unidoc/alpine-zfsboot/releases/latest/download/SHA256SUMS}"

ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"

# alpine-zfsboot's own "boot blob" partition type GUID (bios/gpt.h in that
# repo) - a real, freshly generated random UUID specific to this project,
# not the standard "BIOS boot partition" type code (that one's used below
# too, for the SEPARATE stage1/stage2 partition - see
# ALPINE_ZFSBOOT_BIOS_BOOT_GUID).
ALPINE_ZFSBOOT_BOOTBLOB_GUID="f5bd658b-eee4-402f-be5b-d939c082b649"
# The standard GPT "BIOS boot partition" type code - alpine-zfsboot's
# stage1/stage2 don't NEED this specific type code (stage1 finds this
# partition by fixed LBA, never by GPT type lookup at all - see this
# file's own disk-layout comment), but using the same well-known type here
# rather than inventing another new one means any GPT tool that already
# recognizes it (gdisk, parted, ...) shows this partition's purpose
# correctly instead of as a bare unknown GUID.
ALPINE_ZFSBOOT_BIOS_BOOT_GUID="21686148-6449-6E6F-744E-656564454649"
# The two msdos/MBR-mode equivalents of the two GUIDs just above - only
# used when DISK_LAYOUT=msdos. ALPINE_ZFSBOOT_BOOTBLOB_MBR_TYPE MUST match
# bios/mbr.h's own ZFSBOOT_BOOTBLOB_MBR_TYPE exactly (0x2E) - that's the
# one real, load-bearing invariant here: stage2's own mbr_find_partition()
# call (see bios/stage2_main.c) scans the disk's MBR partition table for
# exactly this type byte to find the boot-blob, the MBR equivalent of
# ALPINE_ZFSBOOT_BOOTBLOB_GUID above for GPT. ALPINE_ZFSBOOT_STAGE2_MBR_TYPE,
# by contrast, is NOT read by any code at all (same as
# ALPINE_ZFSBOOT_BIOS_BOOT_GUID above, which stage1.S also never looks
# up - it just reads a fixed LBA) - it exists purely so the stage2
# partition shows up as a real, typed, visible entry in the msdos
# partition table (`fdisk -l`, `sfdisk -d`, ...) instead of occupying an
# implicit, tool-invisible gap that only this project's own code and
# documentation would know about. Picked from the same kind of
# unassigned-by-convention byte range as the bootblob's own 0x2E (see
# that file's own comment for why: not one of the many already-assigned
# classic MBR type codes like 0x83 Linux/0x82 swap/0xEE GPT-protective).
ALPINE_ZFSBOOT_STAGE2_MBR_TYPE="2D"
ALPINE_ZFSBOOT_BOOTBLOB_MBR_TYPE="2E"
# STAGE2_LBA/STAGE2_SECTORS: must match stage1.S's own hardcoded constants
# in the alpine-zfsboot repo EXACTLY - these are not independently
# discovered at install time, they're a build-time invariant baked into the
# stage1 binary this script is about to write onto the disk's own boot
# sector. If a future alpine-zfsboot release ever changes either constant,
# this script has to be updated to match, not the other way around.
ALPINE_ZFSBOOT_STAGE2_LBA=34
ALPINE_ZFSBOOT_STAGE2_SECTORS=64

# Populated by resolve_alpine_version() / partition_disk() /
# format_boot_partition() / create_swap() / select_zfsboot_artifacts() as
# the install proceeds.
ROOTFS_FILE=""
ROOTFS_URL=""
ROOTFS_SHA256_URL=""
EFI_PARTITION=""
BIOS_BOOT_PARTITION=""
BOOTBLOB_PARTITION=""
SWAP_PARTITION=""
ZFS_PARTITION=""
EFI_FALLBACK_NAME=""
KERNEL_FLAVOR=""
KERNEL_PACKAGE=""
ZFS_KMOD_PACKAGE=""
efi_uuid=""
swap_uuid=""
WORKDIR=""
BOOTBLOB_SECTORS=""

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
# (sgdisk in particular, seen missing on a real alpine-rescue boot even
# though this is a ZFS-focused rescue image) - install it automatically
# rather than making the operator do it by hand on every single run.
# Best-effort only: if apk isn't available, there's no network, or the
# package genuinely doesn't provide the command, the command -v recheck
# in require_command() below still catches it and dies with a clear
# message either way.
apk_package_for_command() {
    case "$1" in
        # Alpine packages this as plain "sgdisk", not "gptfdisk" (the
        # upstream project/Debian package name) - got this wrong once
        # already, don't reintroduce it.
        sgdisk) echo "sgdisk" ;;
        mkfs.vfat) echo "dosfstools" ;;
        zfs|zpool|zgenhostid) echo "zfs" ;;
        # Confirmed missing on a real rescue boot: getent isn't part of
        # musl itself (unlike glibc, where it's built in) and BusyBox has
        # no getent applet at all - musl-utils is the actual Alpine
        # package that ships /usr/bin/getent.
        getent) echo "musl-utils" ;;
        # Confirmed missing too, one at a time, on the same real rescue
        # boot - Alpine splits util-linux into many small individual
        # packages rather than one big one, and BusyBox doesn't replicate
        # any of these (its own blkid/mount/etc. applets, where they exist
        # at all, are minimal stand-ins, not what this script actually
        # needs). Listed here together so a rescue image missing more than
        # one of them (this one was missing all four) gets fixed in one
        # `apk add`, not four separate trial-and-error rounds.
        lsblk) echo "lsblk" ;;
        wipefs) echo "wipefs" ;;
        blkid) echo "blkid" ;;
        mountpoint|mkswap|blockdev) echo "util-linux-misc" ;;
        # sfdisk is its OWN separate Alpine package (confirmed against
        # pkgs.alpinelinux.org's contents search) - it is NOT part of
        # util-linux-misc like mountpoint/mkswap/blockdev above, despite
        # all four being util-linux tools. Got the util-linux-misc naming
        # wrong for sgdisk once already (see that comment above); don't
        # let the same "just lump it in" mistake happen here too.
        sfdisk) echo "sfdisk" ;;
        partprobe) echo "parted" ;;
        # dropbearkey ships in the plain "dropbear" package (confirmed
        # against real Alpine 3.24 dropbear-*.apk contents, same package
        # build.sh itself bundles into the rescue initramfs - see its own
        # comment) - NOT assumed present just because this installer runs
        # inside an alpine-zfsboot rescue environment: a stock Alpine
        # rescue/netboot image (openssh, not dropbear) running this same
        # installer script would otherwise die with "dropbearkey: not
        # found" at the very last install step, after partitioning/pool
        # creation/chroot install have all already happened.
        dropbearkey) echo "dropbear" ;;
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
# if the checksums file can't be fetched (or a custom ALPINE_ZFSBOOT_CHECKSUMS_URL
# points somewhere this project doesn't control) or has no entry for this
# basename. A checksum entry that IS found but doesn't match is always
# fatal: that means either a corrupted download or a compromised
# artifact, and this file is about to become the system's bootloader.
verify_zfsboot_checksum() {
    local file="$1" name="$2" sums_file expected_hash actual_hash

    if [ -z "${ALPINE_ZFSBOOT_CHECKSUMS_URL}" ]; then
        log "ALPINE_ZFSBOOT_CHECKSUMS_URL is not set - skipping checksum verification for ${name}"
        return 0
    fi

    sums_file="$(mktemp)"
    if ! curl --fail --silent --location --output "${sums_file}" "${ALPINE_ZFSBOOT_CHECKSUMS_URL}" 2>/dev/null; then
        log "Could not fetch SHA256SUMS - skipping checksum verification for ${name}"
        rm -f "${sums_file}"
        return 0
    fi

    # Comparing hashes directly, not `sha256sum -c` against the sums file -
    # see this project's own earlier finding (still applies here): the file
    # actually saved on disk is renamed to whatever this script expects
    # locally, which may not match the original release asset name recorded
    # in the sums file, so `sha256sum -c` would look for the wrong filename
    # and always report "No such file or directory".
    expected_hash="$(grep "  ${name}\$" "${sums_file}" | awk '{print $1}')"
    if [ -z "${expected_hash}" ]; then
        log "No checksum entry for ${name} in SHA256SUMS - skipping verification"
        rm -f "${sums_file}"
        return 0
    fi
    rm -f "${sums_file}"

    actual_hash="$(sha256sum "${file}" | awk '{print $1}')"
    [ "${expected_hash}" = "${actual_hash}" ] ||
        die "Checksum mismatch for ${name} - the downloaded alpine-zfsboot artifact does not match what this repo published. Refusing to install a boot image that doesn't match its own checksum."
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
#
# $ALPINE_ZFSBOOT_ACTIVE_TTY (exported by alpine-zfsboot's own /init,
# inherited into whatever shell it's running the installer from) is
# checked FIRST when present, not the cmdline grep below - this
# project's own cmdline always lists BOTH console=tty0 and
# console=ttyAMA*/ttyS* together, by design (see build.sh's own
# CONSOLE_CMDLINE comment), so a plain "is ttyAMA on the cmdline" grep
# is structurally always-true on any alpine-zfsboot-booted rescue
# system regardless of which console the operator is actually watching
# - confirmed the hard way on a real Hetzner CAX install (VGA operator,
# still detected USE_SERIAL=yes). ALPINE_ZFSBOOT_ACTIVE_TTY is the same
# value select_console() already resolved for exactly this question -
# reuse it instead of re-deriving a wrong answer independently. The
# cmdline-grep fallback stays for the non-alpine-zfsboot rescue case
# (a stock Alpine ISO, no ALPINE_ZFSBOOT_ACTIVE_TTY set at all) this
# heuristic was presumably written for originally.
detect_serial() {
    local cmdline serial_dev
    case "${ALPINE_ZFSBOOT_ACTIVE_TTY:-}" in
        tty0) return 1 ;;
        ttyAMA*|ttyS*) return 0 ;;
    esac
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

    case "${DISK_LAYOUT}" in
        gpt|msdos)
            ;;
        *)
            die "Unsupported DISK_LAYOUT: ${DISK_LAYOUT}. Supported values: gpt and msdos."
            ;;
    esac
    if [ "${DISK_LAYOUT}" = "msdos" ] && [ "${USE_UEFI}" = "yes" ]; then
        die "DISK_LAYOUT=msdos is only valid together with USE_UEFI=no - UEFI firmware needs a GPT+ESP layout, there is no msdos/MBR UEFI path in this project. Set USE_UEFI=no explicitly (or boot this rescue system in legacy/CSM mode so USE_UEFI=auto picks it up on its own)."
    fi

    case "${ENCRYPT_ZROOT}" in
        yes|no) ;;
        *) die "Unsupported ENCRYPT_ZROOT: ${ENCRYPT_ZROOT}. Supported values: yes and no." ;;
    esac
    if [ "${ENCRYPT_ZROOT}" = "yes" ]; then
        [ -n "${ZROOT_PASSPHRASE}" ] ||
            die "ENCRYPT_ZROOT=yes requires ZROOT_PASSPHRASE to be set - this installer runs fully unattended, there is no interactive passphrase prompt mid-install. Export ZROOT_PASSPHRASE=\"...\" and re-run."
        # ZFS itself enforces this minimum for keyformat=passphrase and
        # would fail zfs create with its own cryptic error deep inside
        # create_zfs_datasets() otherwise - caught here instead, at the
        # same validation stage every other misconfiguration in this
        # function is caught at.
        [ "${#ZROOT_PASSPHRASE}" -ge 8 ] ||
            die "ZROOT_PASSPHRASE is too short (${#ZROOT_PASSPHRASE} characters) - ZFS requires at least 8 characters for keyformat=passphrase."
    fi

    if [ -n "${ALPINE_ZFSBOOT_SSH_KEY}" ]; then
        local zfsboot_key_line zfsboot_found_key=0
        while IFS= read -r zfsboot_key_line; do
            [ -z "${zfsboot_key_line}" ] && continue
            looks_like_pubkey "${zfsboot_key_line}" ||
                die "ALPINE_ZFSBOOT_SSH_KEY does not look like an SSH public key line: '${zfsboot_key_line}'. Expected something starting with ssh-ed25519, ssh-rsa, ecdsa-sha2-*, or sk-*."
            zfsboot_found_key=1
        done <<EOF
${ALPINE_ZFSBOOT_SSH_KEY}
EOF
        [ "${zfsboot_found_key}" -eq 1 ] ||
            die "ALPINE_ZFSBOOT_SSH_KEY is set but contains no actual key line (blank/whitespace only)."
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
        *) die "Unsupported USE_SERIAL: ${USE_SERIAL}. Supported values: auto, yes, and no." ;;
    esac

    if [ "${USE_UEFI}" = "yes" ]; then
        [ -d /sys/firmware/efi ] || die "The rescue system was not booted in UEFI mode."
    fi

    # mount specifically, forced unconditionally here rather than left to
    # require_command()'s own reactive "only install if genuinely missing"
    # logic below: confirmed a real, silent gap on an actual run -
    # BusyBox's own `mount` applet already satisfies `command -v mount`
    # (it's not ABSENT, just far more limited than real util-linux mount:
    # no libblkid-based filesystem auto-detection at all), so
    # require_command() never even tries to replace it, and a later plain
    # `mount SOURCE TARGET` with no explicit -t failed with a misleading
    # "No such file or directory" instead of anything indicating a
    # filesystem-detection problem. apk installing the real "mount"
    # package over BusyBox's own applet symlink at the same path is a
    # normal, supported Alpine operation, not a hack.
    if command -v apk >/dev/null 2>&1; then
        ensure_apk_updated
        apk add --quiet mount >/dev/null 2>&1 || true
    fi

    # blkid: the IDENTICAL class of gap as mount just above, confirmed
    # the hard way on a real install - BusyBox's own `blkid` applet
    # (checked directly against its upstream source: util-linux/blkid.c)
    # takes NO options at all - `-s`, `-o`, `-t` are silently treated as
    # bogus device names and ignored, and it always prints the FULL
    # "/dev/X: LABEL=... UUID=... TYPE=..." line regardless. `command -v
    # blkid` is satisfied by this long before require_command() ever
    # runs, so `efi_uuid="$(blkid -s UUID -o value "$EFI_PARTITION")"`
    # silently captured that whole line instead of a bare UUID - written
    # straight into /etc/fstab as a single, unparseable field
    # ("UUID=/dev/sdb1: LABEL=... /boot/efi vfat ..."). apk installing
    # the real util-linux blkid over BusyBox's own applet symlink at the
    # same path, same as mount above - not a workaround around BusyBox,
    # replacing it with the real tool.
    if command -v apk >/dev/null 2>&1; then
        ensure_apk_updated
        apk add --quiet blkid >/dev/null 2>&1 || true
    fi

    for command in \
        awk base64 blkid chroot curl getent grep install lsblk mkfs.vfat mktemp \
        modprobe mount mountpoint mkswap od partprobe sha256sum sgdisk tar \
        tr umount wipefs zfs zgenhostid zpool
    do
        require_command "${command}"
    done
    if [ "${DISK_LAYOUT}" = "msdos" ]; then
        require_command "sfdisk"
        require_command "blockdev"
    fi
    # Only required when actually needed - a plain, non-rescue install
    # (ALPINE_ZFSBOOT_SSH_KEY unset) must not fail or auto-install a
    # package just because this ONE optional feature wasn't requested,
    # same posture as the DISK_LAYOUT-gated pair above.
    if [ -n "${ALPINE_ZFSBOOT_SSH_KEY}" ]; then
        require_command "dropbearkey"
    fi

    getent hosts dl-cdn.alpinelinux.org >/dev/null 2>&1 ||
        die "Unable to resolve dl-cdn.alpinelinux.org."

    modprobe zfs
    grep -qw zfs /proc/filesystems ||
        die "The ZFS kernel module is not available."

    WORKDIR="$(mktemp -d)"
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

# Resolves EFI_FALLBACK_NAME always, and whichever of ALPINE_ZFSBOOT_EFI_URL /
# ALPINE_ZFSBOOT_BIOS_*_URL this install actually needs, from the arch-specific
# defaults above - unless already overridden (a custom ALPINE_ZFSBOOT_EFI_URL, or
# any of the ALPINE_ZFSBOOT_*_FILE local-path overrides).
select_zfsboot_artifacts() {
    case "${ARCH}" in
        x86_64)
            EFI_FALLBACK_NAME="BOOTX64.EFI"
            ;;
        aarch64)
            EFI_FALLBACK_NAME="BOOTAA64.EFI"
            ;;
    esac

    if [ "${USE_UEFI}" = "yes" ]; then
        if [ -n "${ALPINE_ZFSBOOT_EFI_URL}" ] || [ -n "${ALPINE_ZFSBOOT_EFI_FILE}" ]; then
            return 0
        fi
        if [ "${ARCH}" = "x86_64" ]; then
            ALPINE_ZFSBOOT_EFI_URL="${ALPINE_ZFSBOOT_EFI_X86_64_URL}"
        else
            ALPINE_ZFSBOOT_EFI_URL="${ALPINE_ZFSBOOT_EFI_AARCH64_URL}"
        fi
    fi
    # BIOS mode's three URLs already have their own x86_64-only defaults
    # above (USE_UEFI=no is refused on aarch64 in validate_environment(),
    # so there's no aarch64 BIOS variant to resolve here) - nothing further
    # to resolve for that case.
}

# Downloads (or copies, for a *_FILE override) whichever alpine-zfsboot
# artifacts this install actually needs into WORKDIR, and verifies each
# against ALPINE_ZFSBOOT_CHECKSUMS_URL if set. Deliberately done BEFORE
# partition_disk(): in BIOS mode, the boot-blob partition has to be sized
# from the real downloaded bootblob file's own byte size (see
# compute_bootblob_sectors()), so that file has to already exist locally
# before partitioning can happen at all.
fetch_zfsboot_artifacts() {
    log "Fetching alpine-zfsboot boot artifacts"

    if [ "${USE_UEFI}" = "yes" ]; then
        if [ -n "${ALPINE_ZFSBOOT_EFI_FILE}" ]; then
            [ -f "${ALPINE_ZFSBOOT_EFI_FILE}" ] ||
                die "Missing alpine-zfsboot EFI file: ${ALPINE_ZFSBOOT_EFI_FILE}"
            cp "${ALPINE_ZFSBOOT_EFI_FILE}" "${WORKDIR}/alpine-zfsboot.EFI"
        else
            curl --fail --location --output "${WORKDIR}/alpine-zfsboot.EFI" "${ALPINE_ZFSBOOT_EFI_URL}"
            verify_zfsboot_checksum "${WORKDIR}/alpine-zfsboot.EFI" "$(basename "${ALPINE_ZFSBOOT_EFI_URL}")"
        fi
        return 0
    fi

    if [ -n "${ALPINE_ZFSBOOT_BIOS_STAGE1_FILE}" ]; then
        [ -f "${ALPINE_ZFSBOOT_BIOS_STAGE1_FILE}" ] ||
            die "Missing alpine-zfsboot BIOS stage1 file: ${ALPINE_ZFSBOOT_BIOS_STAGE1_FILE}"
        cp "${ALPINE_ZFSBOOT_BIOS_STAGE1_FILE}" "${WORKDIR}/stage1.bin"
    else
        curl --fail --location --output "${WORKDIR}/stage1.bin" "${ALPINE_ZFSBOOT_BIOS_STAGE1_URL}"
        verify_zfsboot_checksum "${WORKDIR}/stage1.bin" "$(basename "${ALPINE_ZFSBOOT_BIOS_STAGE1_URL}")"
    fi
    # 512 bytes exactly, 0xAA55 at the last two - a real, load-bearing
    # sanity check, not decoration: this file is about to be dd'd onto the
    # disk's own boot sector, and a wrong-sized/malformed file here would
    # otherwise fail silently (dd itself doesn't know or care what a valid
    # boot sector looks like).
    [ "$(stat -c%s "${WORKDIR}/stage1.bin" 2>/dev/null || wc -c < "${WORKDIR}/stage1.bin")" -eq 512 ] ||
        die "stage1.bin is not exactly 512 bytes - refusing to write it as a boot sector."

    if [ -n "${ALPINE_ZFSBOOT_BIOS_STAGE2_FILE}" ]; then
        [ -f "${ALPINE_ZFSBOOT_BIOS_STAGE2_FILE}" ] ||
            die "Missing alpine-zfsboot BIOS stage2 file: ${ALPINE_ZFSBOOT_BIOS_STAGE2_FILE}"
        cp "${ALPINE_ZFSBOOT_BIOS_STAGE2_FILE}" "${WORKDIR}/stage2.bin"
    else
        curl --fail --location --output "${WORKDIR}/stage2.bin" "${ALPINE_ZFSBOOT_BIOS_STAGE2_URL}"
        verify_zfsboot_checksum "${WORKDIR}/stage2.bin" "$(basename "${ALPINE_ZFSBOOT_BIOS_STAGE2_URL}")"
    fi
    local stage2_size
    stage2_size="$(stat -c%s "${WORKDIR}/stage2.bin" 2>/dev/null || wc -c < "${WORKDIR}/stage2.bin")"
    [ "${stage2_size}" -le $((ALPINE_ZFSBOOT_STAGE2_SECTORS * 512)) ] ||
        die "stage2.bin is ${stage2_size} bytes, exceeds the ${ALPINE_ZFSBOOT_STAGE2_SECTORS}-sector budget stage1 reads (see ALPINE_ZFSBOOT_STAGE2_SECTORS) - this script and the alpine-zfsboot build it came from have drifted apart."

    if [ -n "${ALPINE_ZFSBOOT_BIOS_BOOTBLOB_FILE}" ]; then
        [ -f "${ALPINE_ZFSBOOT_BIOS_BOOTBLOB_FILE}" ] ||
            die "Missing alpine-zfsboot BIOS boot-blob file: ${ALPINE_ZFSBOOT_BIOS_BOOTBLOB_FILE}"
        cp "${ALPINE_ZFSBOOT_BIOS_BOOTBLOB_FILE}" "${WORKDIR}/bootblob.img"
    else
        curl --fail --location --output "${WORKDIR}/bootblob.img" "${ALPINE_ZFSBOOT_BIOS_BOOTBLOB_URL}"
        verify_zfsboot_checksum "${WORKDIR}/bootblob.img" "$(basename "${ALPINE_ZFSBOOT_BIOS_BOOTBLOB_URL}")"
    fi

    compute_bootblob_sectors
}

# Sets BOOTBLOB_SECTORS from the real downloaded bootblob.img size, rounded
# up to whole 512-byte sectors, plus a fixed margin. Oversizing the
# partition is always safe (stage2 checks the blob's own header-declared
# sizes against what the partition claims to hold, not the other way
# around - see the alpine-zfsboot repo's own stage2_main.c) - this margin
# exists purely so a small, well-understood rounding slip in this script's
# own arithmetic can never under-size the partition, not because the exact
# byte count is actually in doubt.
compute_bootblob_sectors() {
    local bootblob_bytes bootblob_min_sectors margin_sectors
    bootblob_bytes="$(stat -c%s "${WORKDIR}/bootblob.img" 2>/dev/null || wc -c < "${WORKDIR}/bootblob.img")"
    bootblob_min_sectors=$(( (bootblob_bytes + 511) / 512 ))
    margin_sectors=2048 # 1 MiB of headroom
    BOOTBLOB_SECTORS=$((bootblob_min_sectors + margin_sectors))
    log "boot-blob is ${bootblob_bytes} bytes (${bootblob_min_sectors} sectors) - partition will be ${BOOTBLOB_SECTORS} sectors"
}

partition_disk() {
    log "Installation target"
    lsblk "${SYSDRIVE}"
    log "Destroying all data on ${SYSDRIVE}"

    mkdir -p "${MOUNT_LOCATION}"

    if mountpoint -q "${MOUNT_LOCATION}" 2>/dev/null; then
        umount -R "${MOUNT_LOCATION}" || true
    fi

    # grep -c, not -q - see cleanup()'s own identical comment.
    if [ "$(zpool list -H -o name 2>/dev/null | grep -cx "${POOL_NAME}")" -gt 0 ]; then
        zpool export "${POOL_NAME}"
    fi

    zpool labelclear -f "${SYSDRIVE}" 2>/dev/null || true
    wipefs -a "${SYSDRIVE}"
    # Always zap any existing GPT structures first, even when writing an
    # msdos table below - not decoration: stage2's own GPT-then-MBR
    # auto-detection (see bios/stage2_main.c) only FALLS BACK to MBR when
    # gpt_read_header() finds no valid GPT header at all. A disk that
    # previously had a GPT layout still has an intact backup GPT header
    # near the end of the disk after wipefs -a alone (util-linux's GPT
    # prober does not reliably clear it on every version), and sfdisk
    # below only touches the MBR at LBA 0 - so a stale backup header could
    # make stage2 find a "valid" (but wrong/stale) GPT and die() instead
    # of ever trying MBR. sgdisk --zap-all is safe to run unconditionally:
    # on a disk with no GPT at all it just reports "0 bytes of GPT data
    # found" and exits 0. sgdisk is already an unconditionally-required
    # command (see the require_command list below), so this needs no new
    # dependency.
    sgdisk --zap-all "${SYSDRIVE}"

    if [ "${DISK_LAYOUT}" = "gpt" ]; then
        log "Creating GPT partitions"
        local -a sgdisk_args
        local next_partnum=1

        if [ "${USE_UEFI}" = "yes" ]; then
            EFI_PARTITION="$(partition_path "${SYSDRIVE}" "${next_partnum}")"
            sgdisk_args=( -n "${next_partnum}:1MiB:+512MiB" -t "${next_partnum}:EF00" -c "${next_partnum}:EFI" )
            next_partnum=$((next_partnum + 1))
        else
            # -a 1 (alignment = 1 sector) is load-bearing for this ONE
            # partition, not decoration: sgdisk's own default 2048-sector
            # alignment would otherwise silently move an explicit "start at
            # LBA 34" request to the next aligned boundary (LBA 2048) instead
            # - confirmed against sgdisk's own documented behavior, not
            # guessed - which would completely break stage1's fixed, hardcoded
            # LBA-34 read (see this file's own disk-layout comment). Restored
            # to a sane, performance-friendly alignment immediately afterward
            # (-a 2048) for every partition created after this one - sgdisk
            # processes its own arguments in the order given, so this ordering
            # is what makes both things true at once: partition 1 lands
            # exactly where stage1 expects it, and the boot-blob/swap/ZFS
            # partitions after it still get normal, SSD/4Kn-friendly alignment.
            BIOS_BOOT_PARTITION="$(partition_path "${SYSDRIVE}" "${next_partnum}")"
            sgdisk_args=(
                -a 1
                -n "${next_partnum}:${ALPINE_ZFSBOOT_STAGE2_LBA}:+${ALPINE_ZFSBOOT_STAGE2_SECTORS}"
                -t "${next_partnum}:${ALPINE_ZFSBOOT_BIOS_BOOT_GUID}"
                -c "${next_partnum}:alpine-zfsboot-stage2"
                -a 2048
            )
            next_partnum=$((next_partnum + 1))

            BOOTBLOB_PARTITION="$(partition_path "${SYSDRIVE}" "${next_partnum}")"
            sgdisk_args+=(
                -n "${next_partnum}:0:+${BOOTBLOB_SECTORS}"
                -t "${next_partnum}:${ALPINE_ZFSBOOT_BOOTBLOB_GUID}"
                -c "${next_partnum}:alpine-zfsboot-bootblob"
            )
            next_partnum=$((next_partnum + 1))
        fi

        SWAP_PARTITION="$(partition_path "${SYSDRIVE}" "${next_partnum}")"
        if [ "${SWAP_SIZE_GIB}" -gt 0 ]; then
            sgdisk_args+=( -n "${next_partnum}:0:+${SWAP_SIZE_GIB}GiB" -t "${next_partnum}:8200" -c "${next_partnum}:SWAP" )
        else
            sgdisk_args+=( -n "${next_partnum}:0:+1MiB" -t "${next_partnum}:8200" -c "${next_partnum}:SWAP" )
        fi
        next_partnum=$((next_partnum + 1))

        ZFS_PARTITION="$(partition_path "${SYSDRIVE}" "${next_partnum}")"
        sgdisk_args+=( -n "${next_partnum}:0:-10MiB" -t "${next_partnum}:BF00" -c "${next_partnum}:ZFS" )

        sgdisk "${sgdisk_args[@]}" "${SYSDRIVE}"
    else
        # msdos/MBR layout - see DISK_LAYOUT's own comment and this
        # file's disk-layout comment at the top. Only reached with
        # USE_UEFI=no (validated in validate_environment()), so there is
        # no EFI_PARTITION branch to consider here at all - exactly 4
        # primary partitions, every position computed explicitly in
        # whole sectors rather than trusted to sfdisk's own default
        # placement/alignment heuristics: this project's own stage1.S
        # has a hard, build-time LBA=34 invariant for partition 1
        # regardless of partitioning scheme (see ALPINE_ZFSBOOT_STAGE2_LBA's
        # own comment), and everything computed here has to agree with
        # that exactly, not approximately.
        log "Creating msdos/MBR partitions"
        local disk_sectors stage2_end bootblob_start bootblob_end
        local swap_start swap_end swap_sectors zfs_start zfs_sectors reserve_sectors

        # blockdev --getsz always reports in 512-byte units (documented
        # behavior, independent of the device's own logical sector
        # size), matching every LBA this whole project already assumes
        # is 512 bytes throughout (DISK_SECTOR_SIZE in the alpine-zfsboot
        # repo's bios/disk.h, ALPINE_ZFSBOOT_STAGE2_LBA itself, the GPT
        # branch's own sgdisk math) - not a new assumption introduced
        # here, the same one this whole install already depends on. A
        # real 4Kn-native (non-512e) disk would break this the same way
        # it would already break the GPT branch above; out of scope for
        # either.
        disk_sectors="$(blockdev --getsz "${SYSDRIVE}")"
        stage2_end=$((ALPINE_ZFSBOOT_STAGE2_LBA + ALPINE_ZFSBOOT_STAGE2_SECTORS - 1))

        # 2048 sectors (1MiB) - the same standard alignment the GPT
        # branch's own `-a 2048` re-establishes for everything after its
        # own fixed-LBA first partition. LBAs stage2_end+1..2047 are left
        # unpartitioned (the "MBR gap"), same as the GPT branch leaves
        # LBA 1-33 unpartitioned ahead of its own fixed-LBA partition 1.
        bootblob_start=2048
        # A real check, not decoration: with today's fixed
        # ALPINE_ZFSBOOT_STAGE2_LBA/SECTORS (34/64) this can never
        # actually trip, but it's the one thing that WOULD silently
        # overlap partition 1 and 2 if either constant ever grew past
        # this hardcoded 2048-sector gap without this line also being
        # updated - caught here, at partition-table-write time, instead
        # of as a corrupted boot-blob discovered only much later at
        # actual boot.
        [ "${bootblob_start}" -gt "${stage2_end}" ] ||
            die "ALPINE_ZFSBOOT_STAGE2_SECTORS has grown too large for the fixed ${bootblob_start}-sector bootblob_start gap (stage2 now ends at LBA ${stage2_end}) - raise bootblob_start above stage2_end in this script and re-run."
        bootblob_end=$((bootblob_start + BOOTBLOB_SECTORS - 1))

        swap_start=$(( ( (bootblob_end + 1) + 2047 ) / 2048 * 2048 ))
        if [ "${SWAP_SIZE_GIB}" -gt 0 ]; then
            swap_sectors=$((SWAP_SIZE_GIB * 1024 * 1024 * 1024 / 512))
        else
            # Same "+1MiB" unused placeholder the GPT branch creates when
            # swap is skipped - keeps partition numbering (and this
            # script's own SWAP_PARTITION/ZFS_PARTITION variables) stable
            # either way rather than branching the partition COUNT on
            # SWAP_SIZE_GIB too.
            swap_sectors=2048
        fi
        swap_end=$((swap_start + swap_sectors - 1))

        zfs_start=$(( ( (swap_end + 1) + 2047 ) / 2048 * 2048 ))
        # 10MiB reserved at the very end of the disk - the msdos/MBR
        # table itself needs nothing there (unlike GPT's own backup
        # header, which is what the GPT branch's own "-10MiB" is
        # actually protecting), kept purely as a safety margin against
        # this arithmetic being off by a sector or two, not because
        # anything specific lives there.
        reserve_sectors=$((10 * 1024 * 1024 / 512))
        zfs_sectors=$((disk_sectors - zfs_start - reserve_sectors))
        [ "${zfs_sectors}" -gt 0 ] ||
            die "SYSDRIVE is too small for this msdos layout (disk has ${disk_sectors} sectors, but bootblob+swap already consume up through LBA ${zfs_start} - the ZFS partition would end up with ${zfs_sectors} sectors). Use a larger disk or a smaller SWAP_SIZE_GIB."

        BIOS_BOOT_PARTITION="$(partition_path "${SYSDRIVE}" 1)"
        BOOTBLOB_PARTITION="$(partition_path "${SYSDRIVE}" 2)"
        SWAP_PARTITION="$(partition_path "${SYSDRIVE}" 3)"
        ZFS_PARTITION="$(partition_path "${SYSDRIVE}" 4)"

        # "bootable" on partition 1 - not needed for stage1 itself (it
        # sits at LBA 0 and gets control from BIOS/SeaBIOS regardless of
        # any partition's active flag), but some real-world BIOSes refuse
        # to boot an MBR disk with no active partition at all. Confirmed
        # via a real sfdisk run that this script syntax produces the
        # expected active/"Boot *" flag on partition 1 and nothing else -
        # cheap insurance against exactly that firmware quirk, matching
        # this project's own bar for not leaving known contingencies
        # unhandled when the fix is this small.
        sfdisk "${SYSDRIVE}" <<EOF
label: dos
unit: sectors

start=${ALPINE_ZFSBOOT_STAGE2_LBA}, size=${ALPINE_ZFSBOOT_STAGE2_SECTORS}, type=${ALPINE_ZFSBOOT_STAGE2_MBR_TYPE}, bootable
start=${bootblob_start}, size=${BOOTBLOB_SECTORS}, type=${ALPINE_ZFSBOOT_BOOTBLOB_MBR_TYPE}
start=${swap_start}, size=${swap_sectors}, type=82
start=${zfs_start}, size=${zfs_sectors}, type=83
EOF
    fi

    partprobe "${SYSDRIVE}" || true
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true
    command -v mdev >/dev/null 2>&1 && mdev -s || true

    if [ -n "${EFI_PARTITION}" ]; then
        wait_for_device "${EFI_PARTITION}"
    fi
    if [ -n "${BIOS_BOOT_PARTITION}" ]; then
        wait_for_device "${BIOS_BOOT_PARTITION}"
        wait_for_device "${BOOTBLOB_PARTITION}"
    fi
    wait_for_device "${SWAP_PARTITION}"
    wait_for_device "${ZFS_PARTITION}"
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
    # openzfs-2.4, not openzfs-2.2-linux (an earlier version of this
    # script's own choice) - two separate real problems with that value,
    # confirmed on a real run ("could not read/parse feature file(s):
    # openzfs-2.2-linux"): (1) OpenZFS dropped the "-linux" suffix from
    # this naming convention starting at 2.2 - the real file is named
    # "openzfs-2.2", not "openzfs-2.2-linux", so that value was never
    # valid to begin with, in any environment; (2) this rescue
    # environment's own zfs userland is whatever version alpine-zfsboot's
    # own build pinned (Alpine 3.24 -> OpenZFS 2.4.4 today) - since that
    # same rescue environment is also what will need to `zpool import`
    # this exact pool for any FUTURE rescue access, matching the
    # compatibility level to what it actually supports (rather than an
    # arbitrarily older, more conservative one) is the right target, not
    # a guess at broader cross-tool compatibility this project has no
    # actual need for.
    zpool create -f \
        -o compatibility=openzfs-2.4 \
        -o ashift=12 \
        -o autotrim=off \
        -O acltype=posixacl \
        -O atime=off \
        -O compression=lz4 \
        -O normalization=formD \
        -O xattr=sa \
        -m none \
        "${POOL_NAME}" "${ZFS_PARTITION}"

    # ENCRYPT_ZROOT=yes makes THIS dataset the encryption root - see that
    # variable's own top-of-file comment for why here specifically (not
    # ${ROOT_DATASET}): every boot environment lives under this one
    # container, current and future, so establishing encryption here
    # once means every one of them inherits the same key automatically,
    # with no per-BE re-encryption ever needed. ${POOL_NAME}/home,
    # ${POOL_NAME}/var, and ${POOL_NAME}/var/log below are siblings of
    # ${POOL_NAME}/ROOT, not children of it - they never inherit this
    # and stay unencrypted regardless, exactly as intended.
    if [ "${ENCRYPT_ZROOT}" = "yes" ]; then
        # keylocation=prompt normally means an interactive terminal
        # prompt - here stdin is a pipe, not a tty, so zfs reads the
        # passphrase from it directly instead (the same non-interactive
        # mechanism init/boot-dataset.sh's own `zfs load-key` relies on
        # at every subsequent boot - confirmed identical property values
        # either way: encryptionroot/keystatus/keylocation are set the
        # same way whether the key was supplied via a real prompt or
        # piped stdin at create time). Piped, never a command-line
        # argument - `ps` on this rescue system must never show it.
        printf '%s' "${ZROOT_PASSPHRASE}" | zfs create \
            -o mountpoint=none -o canmount=off \
            -o encryption=aes-256-gcm -o keyformat=passphrase -o keylocation=prompt \
            "${POOL_NAME}/ROOT"
    else
        zfs create -o mountpoint=none -o canmount=off "${POOL_NAME}/ROOT"
    fi
    zfs create -o mountpoint=/ -o canmount=noauto "${ROOT_DATASET}"
    zfs create -o mountpoint=/home "${POOL_NAME}/home"
    zfs create -o mountpoint=/var "${POOL_NAME}/var"
    zfs create -o mountpoint=/var/log "${POOL_NAME}/var/log"
    zpool set bootfs="${ROOT_DATASET}" "${POOL_NAME}"

    # Armed by default (opt-out per-boot via alpine-zfsboot.bootcheck=off,
    # not an install-time choice) - alpine-zfsboot's own failed-boot
    # detection (see boot-dataset.sh/init's own design comments in the
    # alpine-zfsboot repo). Safe to default on specifically because
    # arming is CONTENT-derived at increment time, not just property-
    # derived: a BE without the confirm service actually registered
    # (write_chroot_install_script() below installs and enables it)
    # never has its counter advanced at all, regardless of what this
    # property says - so there is no failure mode where a healthy
    # install without the service somehow refuses to auto-boot.
    zfs set org.alpinezfsboot:bootcheck=armed:0 "${ROOT_DATASET}"

    # No console= needs persisting here at all: alpine-zfsboot's own
    # boot-dataset.sh derives the target kernel's console= automatically
    # from $ALPINE_ZFSBOOT_ACTIVE_TTY at boot time
    # (see that script's own comment in the alpine-zfsboot repo), whatever
    # console the operator is actually using that boot. net.ifnames=0 is
    # still worth persisting explicitly though - predictable eth0-style
    # interface naming is a real, independent preference, nothing to do
    # with which bootloader is in use.
    zfs set org.alpinezfsboot:commandline="net.ifnames=0" "${POOL_NAME}/ROOT"
}

import_pool() {
    log "Importing pool under ${MOUNT_LOCATION}"
    zpool export "${POOL_NAME}"
    zpool import -N -R "${MOUNT_LOCATION}" "${POOL_NAME}"
    # create_zfs_datasets()'s own `zfs create` (piped-stdin passphrase)
    # loads the key as a side effect - but the export/import cycle just
    # above drops it again (exporting a pool discards its in-memory key
    # state), and a fresh import never reloads it on its own. Without
    # this, the zfs mount below fails with "encryption key not loaded" -
    # confirmed the hard way on a real install. Target is
    # ${POOL_NAME}/ROOT (the encryption root every boot environment
    # inherits from - see create_zfs_datasets()'s own comment), not
    # ${ROOT_DATASET} - same property the whole clone-inheritance design
    # rests on. Piped via stdin, never a command-line argument, same
    # ps-visibility reason as the create call above.
    if [ "${ENCRYPT_ZROOT}" = "yes" ]; then
        printf '%s' "${ZROOT_PASSPHRASE}" | zfs load-key "${POOL_NAME}/ROOT"
    fi
    zfs mount "${ROOT_DATASET}"
    zfs mount "${POOL_NAME}/home"
    zfs mount "${POOL_NAME}/var"
    zfs mount "${POOL_NAME}/var/log"
}

fetch_rootfs() {
    log "Downloading Alpine ${ALPINE_VERSION} root filesystem"

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
    # pkg.unidoc.io alongside the stock Alpine mirrors - lets
    # write_chroot_install_script() below `apk add alpine-zfsboot`
    # (cmd/tool, this project's own install-time check/update helper -
    # see unidoc-aports' own alpine-zfsboot package) the same way it
    # installs any other package, no separate fetch/install mechanism
    # needed. ${ALPINE_BRANCH} is already in exactly the format
    # pkg.unidoc.io's own URL scheme expects (e.g. "v3.24" - confirmed
    # against unidoc-aports' own README), the same variable the two
    # stock mirror lines below already use.
    cat > "${MOUNT_LOCATION}/etc/apk/repositories" <<EOF
${ALPINE_MIRROR}/${ALPINE_BRANCH}/main
${ALPINE_MIRROR}/${ALPINE_BRANCH}/community
https://pkg.unidoc.io/${ALPINE_BRANCH}/main
EOF
    mkdir -p "${MOUNT_LOCATION}/etc/apk/keys"
    curl --fail --location \
        --output "${MOUNT_LOCATION}/etc/apk/keys/unidoc-aports.rsa.pub" \
        https://pkg.unidoc.io/keys/unidoc-aports.rsa.pub

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
    if [ "${USE_UEFI}" != "yes" ]; then
        log "Skipping EFI System Partition (legacy BIOS mode has no filesystem-based boot code at all - see this file's own disk-layout comment)"
        return 0
    fi
    log "Formatting EFI System Partition"
    # NOT partprobe here - confirmed a real, unavoidable failure mode on
    # a real run: by this point create_zpool()/import_pool() already have
    # the pool's own datasets mounted from a DIFFERENT partition on this
    # SAME disk (${ZFS_PARTITION}), so a full partition-table re-read
    # (what partprobe actually does) correctly refuses with "Resource
    # busy" - this isn't a transient failure to retry around, it's the
    # kernel correctly protecting an already-mounted disk, and it will
    # fail here every single time from now until this pool is exported.
    # udevadm settle (waits for already-queued udev events to finish
    # processing, needs no exclusive disk access) is the right tool
    # instead - used twice: once before mkfs.vfat in case anything is
    # still settling from partition_disk()'s own earlier work, and once
    # after, to let mkfs.vfat's own write to the partition (a real udev
    # "change" event - writing a new filesystem superblock) fully settle
    # before this function tries to mount what it just formatted.
    # Confirmed the hard way that skipping the SECOND wait specifically
    # is what let `mount` intermittently fail with "No such file or
    # directory" immediately after a successful mkfs.vfat.
    #
    # udevadm itself is NOT guaranteed to exist here though - confirmed
    # directly against the alpine-zfsboot repo this rescue shell comes
    # from: its own /init uses ONLY BusyBox's mdev, never real udev/
    # eudev, and nothing in its build bundles udevadm at all. `mdev -s`
    # (a one-shot /sys rescan, not a "wait for pending events" the way
    # udevadm settle is, but the best BusyBox-only equivalent available)
    # as a real fallback here - the SAME two-tool pattern
    # partition_disk() above already uses for exactly this reason,
    # mirrored here rather than silently doing nothing if udevadm is
    # missing (an earlier version of this fix only tried udevadm,
    # silently skipping if it wasn't present - which would have made the
    # fix inert in this exact rescue environment). wait_for_device()'s
    # own retry loop below is the real backstop either way, regardless
    # of which (if either) of these actually did anything.
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle
    elif command -v mdev >/dev/null 2>&1; then
        mdev -s
    fi
    wait_for_device "${EFI_PARTITION}"

    mkfs.vfat -F32 -n EFI "${EFI_PARTITION}"
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle
    elif command -v mdev >/dev/null 2>&1; then
        mdev -s
    fi
    wait_for_device "${EFI_PARTITION}"
    efi_uuid="$(blkid -s UUID -o value "${EFI_PARTITION}")"

    mkdir -p "${MOUNT_LOCATION}/boot/efi"
    # -t vfat explicitly, not left to auto-detection, and the module
    # loaded first rather than assumed already present - confirmed a
    # real failure mode on this exact rescue shell even with BOTH
    # endpoints verified to genuinely exist (the source device present,
    # the target directory just created): this rescue environment's
    # `mount` is BusyBox's own applet, not a real util-linux mount - it
    # has no libblkid-based filesystem probing to fall back on, so a
    # bare `mount SOURCE TARGET` with no -t depends entirely on the vfat
    # module already being loaded and doesn't identify the type any
    # other way. `modprobe` failing is not itself fatal here (the module
    # could already be built in rather than a separate .ko, in which
    # case there's nothing to load and modprobe says so) - the `mount
    # -t vfat` call right after is what actually has to succeed.
    modprobe vfat 2>/dev/null || true
    mount -t vfat "${EFI_PARTITION}" "${MOUNT_LOCATION}/boot/efi"
}

write_fstab() {
    : > "${MOUNT_LOCATION}/etc/fstab"
    if [ "${USE_UEFI}" = "yes" ]; then
        printf 'UUID=%s /boot/efi vfat defaults,noauto,noatime 0 2\n' "${efi_uuid}" >> "${MOUNT_LOCATION}/etc/fstab"
    fi
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

# alpine-zfsboot in the list below is cmd/tool - the install-time
# check/update helper for the .EFI this same install just wrote. From
# pkg.unidoc.io, not a stock Alpine package - write_base_config()
# already added that repo and its signing key above, before this
# chroot script ever runs.
apk add \
    alpine-base \
    acpid \
    alpine-zfsboot \
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

# alpine-zfsboot's own failed-boot detection ("bootcheck" - see boot-
# dataset.sh/init's own design comments in the alpine-zfsboot repo for
# the full mechanism) - this is the TARGET side's own acknowledgement
# that a boot genuinely reached real multi-user readiness, not just
# "the kernel started" or "root mounted". `after *` (confirmed against
# real OpenRC source, not assumed) makes this service start only after
# every other service already scheduled in the SAME runlevel has - it
# MUST be unquoted (a quoted "*" is a silent no-op, becoming a literal
# dependency name that never resolves) and must NOT carry
# `keyword -timeout` (that keyword makes anything waiting on this
# specific service block up to 60s - an accident waiting to happen if
# copied from a different service's own keyword set, not needed here).
# `default` is confirmed the correct, genuinely-last runlevel on
# Alpine specifically (Alpine's own rc patches always walk
# sysinit -> boot -> default in that fixed order, each level's
# services fully started before the next begins).
#
# Reads which dataset is mounted at / directly (not hardcoded) so this
# same script works correctly regardless of which boot environment is
# actually running. Deliberately does NOT distinguish local/inherited/
# received property source here (unlike the decision points in /init
# and boot-dataset.sh, which must) - this side's only job is "if the
# EFFECTIVE value looks armed, reset it to a fresh local armed:0",
# which is correct regardless of where that effective value came from.
# Always eend 0 - this service must never fail the runlevel, even if
# the zfs command itself fails for some reason.
#
# The nested heredoc below is intentionally single-quoted ('INNER') so
# ITS OWN $ references reach the actual installed file literally, to
# be interpreted only when this script really runs at a real target
# boot - the backslash-escaped \$ throughout is what stops the OUTER,
# unquoted heredoc this whole chroot-install-script.sh is itself
# written with (see write_chroot_install_script()'s own EOF above)
# from expanding them prematurely at INSTALL time instead.
cat > /etc/init.d/alpine-zfsboot-bootcheck <<'INNER'
#!/sbin/openrc-run
description="Confirm this boot reached the default runlevel, for alpine-zfsboot's own failed-boot detection"
depend() {
    after *
}
start() {
    ebegin "alpine-zfsboot: confirming successful boot"
    ds=\$(awk '\$2 == "/" && \$3 == "zfs" { print \$1 }' /proc/mounts)
    if [ -n "\$ds" ]; then
        value=\$(zfs get -H -o value org.alpinezfsboot:bootcheck "\$ds" 2>/dev/null)
        case "\$value" in
            armed:*) zfs set org.alpinezfsboot:bootcheck=armed:0 "\$ds" 2>/dev/null ;;
        esac
    fi
    # Last Boot Diagnostics: reaching this service at all (after * -
    # last in the runlevel) means the boot is confirmed good, so any
    # efi-pstore evidence still sitting around is from an attempt that
    # is now superseded - erase it, or a stale panic from days or
    # reboots ago would keep getting shown to an operator as if it were
    # from the boot they just did. Unconditional, independent of the
    # bootcheck property above - evidence goes stale on any confirmed
    # boot, armed or not. modprobe here too, not just relying on
    # /etc/modules having already loaded it earlier in boot - best-
    # effort/fail-open like everything else in this service: this
    # platform may be legacy BIOS (no EFI variables, no backend, module
    # load fails harmlessly), may already have it loaded, or the mount
    # may simply fail - none of that is an error worth failing the
    # runlevel over. dmesg-efi-* (efi-pstore's own record naming, NOT
    # dmesg-ramoops-* - ramoops was rejected for this project, see
    # boot-dataset.sh's own attempt-record comment for why).
    modprobe efi_pstore pstore_disable=0 2>/dev/null
    mkdir -p /sys/fs/pstore 2>/dev/null
    mount -t pstore pstore /sys/fs/pstore 2>/dev/null
    rm -f /sys/fs/pstore/dmesg-efi-* 2>/dev/null
    eend 0
}
INNER
chmod 755 /etc/init.d/alpine-zfsboot-bootcheck

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
rc-update add alpine-zfsboot-bootcheck default

echo button >> /etc/modules

# Last Boot Diagnostics - OpenRC's own stock service logger
# (rc_logger="YES" in /etc/rc.conf, default rc_log_path=/var/log/rc.log)
# writes every service's start/stop output there, including the exact
# "* ERROR: X failed to start" lines an OpenRC/userspace startup failure
# produces - no custom capture code needed at all, and it lives on this
# BE's own real ZFS filesystem, so alpine-zfsboot reads it on the next
# rescue boot the same way it already reads /boot for kernels (mount
# read-only, look, unmount). This is the primary Last Boot Diagnostics
# evidence source for this project, not a "nice extra" - see
# menu.py's own freshness check against org.alpinezfsboot:attempt_time
# (see boot-dataset.sh) before trusting it as belonging to the failed
# attempt rather than an old success. Handles both shapes rather than
# assuming one: uncomments in place if the stock /etc/rc.conf already
# has a commented rc_logger= line (Alpine's openrc package has shipped
# one for a long time, but this hasn't been re-verified against the
# exact target image this installer uses), appends a fresh line
# otherwise - correct either way, no assumption load-bearing.
if grep -q '^[#]*rc_logger=' /etc/rc.conf 2>/dev/null; then
    sed -i 's/^[#]*rc_logger=.*/rc_logger="YES"/' /etc/rc.conf
else
    echo 'rc_logger="YES"' >> /etc/rc.conf
fi

# Last Boot Diagnostics, kernel panic/oops evidence - UEFI only: EFI
# variables (firmware-owned NVRAM) don't exist under legacy BIOS boot at
# all. efi_pstore captures a panic/oops with NO physical-RAM-address
# reservation of any kind - see this project's own research on why
# ramoops itself was rejected here instead (reserve_mem= is documented
# by the kernel itself as "best effort", and its fixed memmap= fallback
# is x86-only, useless on the validated aarch64 Hetzner CAX hardware).
# Ships disabled by default on Alpine's own kernel
# (CONFIG_EFI_VARS_PSTORE_DEFAULT_DISABLE=y) - pstore_disable=0 turns it
# on. Loaded on every boot via /etc/modules (same mechanism as the
# button module above) so a REAL panic on this machine's own future
# boot actually gets captured into NVRAM - alpine-zfsboot's own rescue
# side only ever reads this back later, it never writes it itself.
# NOT YET CONFIRMED WORKING on real hardware (EFI variable persistence
# across a real reboot, not just a clean shutdown, is unverified from
# here) - do not call kernel-crash evidence "supported" until that's
# been proven end to end on real CAX/physical UEFI hardware.
if [ "${USE_UEFI}" != "no" ]; then
    echo efi_pstore >> /etc/modules
    mkdir -p /etc/modprobe.d
    echo 'options efi_pstore pstore_disable=0' > /etc/modprobe.d/efi-pstore.conf
fi

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

rm -f /chroot-install-script.sh
EOF

    chmod 0755 "${MOUNT_LOCATION}/chroot-install-script.sh"
}

run_chroot_install() {
    log "Installing Alpine packages"
    chroot "${MOUNT_LOCATION}" /bin/sh /chroot-install-script.sh
}

# UEFI mode: alpine-zfsboot's own .EFI is entirely self-contained (kernel +
# initramfs + cmdline all bundled into one PE/COFF file by its own build.sh
# - see that repo) - just copy it onto the ESP at the standard removable-
# media fallback path, no separate kernel/initramfs files or NVRAM boot
# entry needed at all. A backup copy under a fixed name too - cheap
# insurance if the primary copy is ever damaged in place.
install_alpine_zfsboot_uefi() {
    mkdir -p "${MOUNT_LOCATION}/boot/efi/EFI/BOOT"
    cp "${WORKDIR}/alpine-zfsboot.EFI" \
       "${MOUNT_LOCATION}/boot/efi/EFI/BOOT/${EFI_FALLBACK_NAME}"
    cp "${WORKDIR}/alpine-zfsboot.EFI" \
       "${MOUNT_LOCATION}/boot/efi/EFI/BOOT/${EFI_FALLBACK_NAME}.backup"
    write_alpine_zfsboot_esp_config
}

# Per-machine alpine-zfsboot settings (rescue ssh_key, static network,
# ...), read by /init at every boot and merged into its own cmdline
# parsing - cmdline always wins over this file (see init/init's own
# comment on why: a bad persisted setting must stay overridable for one
# boot, never a permanent lock-out). Nothing written for a setting that
# was never set here - an empty `alpine-zfsboot.net=` line would parse
# as a real (if useless) override, not "no opinion", so absent keys
# have to stay genuinely absent, not present-with-an-empty-value.
#
# Plain data, one `key=value` per line - /init deliberately does NOT
# source this file as a script, only ever matches it against the same
# whitelist of alpine-zfsboot.* keys /proc/cmdline itself is parsed
# against, so its content can never execute regardless of what it
# contains. Written unencrypted onto a FAT partition (the ESP has no
# other option) - network settings and (via the two sibling files this
# function also writes below) public key material and this machine's
# own SSH host PRIVATE key. That private key being on an unencrypted,
# pre-boot-readable partition is an accepted, deliberate tradeoff (it
# must be readable before anything else on this machine is unlocked),
# not an oversight - but it means this ESP is no longer "nothing secret
# here", and physical/firmware-level access to it is equivalent to
# extracting this machine's rescue SSH host identity. NEVER
# ZROOT_PASSPHRASE or anything else secret beyond that goes here.
write_alpine_zfsboot_esp_config() {
    local config_file="${MOUNT_LOCATION}/boot/efi/EFI/alpine-zfsboot/config"
    local authorized_keys_file="${MOUNT_LOCATION}/boot/efi/EFI/alpine-zfsboot/authorized_keys"
    local host_key_file="${MOUNT_LOCATION}/boot/efi/EFI/alpine-zfsboot/ssh_host_ed25519_key"
    # ${config_file%/*}, not `dirname` - confirmed the hard way earlier
    # THIS SAME SESSION that dirname isn't a safe assumption on a
    # minimal/rescue Alpine environment (alpine-zfsboot's own /init hit
    # "dirname: not found"); this rescue system is fuller than that
    # initramfs but there's no reason to re-risk the identical class of
    # bug one file over.
    mkdir -p "${config_file%/*}"
    : > "${config_file}"
    if [ -n "${ALPINE_ZFSBOOT_SSH_KEY}" ]; then
        # One bare key per line, written verbatim - no base64, no
        # alpine-zfsboot.* config key at all, but also NOT full OpenSSH
        # authorized_keys syntax (see this variable's own declaration
        # comment above for why operator options are deliberately
        # rejected, not honored). Earlier version of this mechanism
        # wrote alpine-zfsboot.ssh_key=<base64 pubkey> into config_file
        # itself; replaced (not kept alongside) once a real hardware
        # test motivated the two-file layout - see rescue-ssh.sh's own
        # header comment for the full reasoning.
        # ALPINE_ZFSBOOT_SSH_KEY may hold several newline-separated
        # lines (see its own declaration comment/validate_environment()'s
        # loop) - printf here preserves that as-is, one line per key.
        printf '%s\n' "${ALPINE_ZFSBOOT_SSH_KEY}" > "${authorized_keys_file}"
        # chmod here is best-effort, not the real protection - vfat has
        # no real unix permission bits (whatever a kernel driver reports
        # back is synthesized from the mount's own dmask/fmask/uid/gid
        # options, not this file's own metadata), so the actual boundary
        # protecting this ESP's content is who can get physical/mount
        # access to the partition at all, not this chmod call.
        chmod 0600 "${authorized_keys_file}"

        # Generated fresh on every install run (this function always
        # truncates/rewrites config_file the same way, for the same
        # reason: "installation time" is exactly when this project's own
        # author asked for a new identity to be minted - a genuine
        # reinstall onto the same disk deliberately gets a new
        # fingerprint, not a preserved one, matching a real machine
        # getting re-imaged). dropbearkey's own native key format, NOT
        # ssh-keygen/PEM - guaranteed compatible with the bundled
        # dropbear binary that will actually load it later (see
        # rescue-ssh.sh's own `dropbear -r` invocation), with no
        # PEM-vs-dropbear-format compatibility question to even ask.
        # rm -f first: dropbearkey refuses to overwrite an existing key
        # file outright ("Failed moving key file to hostkey2: File
        # exists", confirmed against the real binary) rather than
        # regenerating it - currently unreachable in practice (the ESP is
        # always freshly `mkfs.vfat`'d earlier in this same install), but
        # this function's own "fresh every install run" claim above
        # should be true by construction, not true only because nothing
        # else in this script happens to preserve the ESP today.
        rm -f "${host_key_file}"
        dropbearkey -t ed25519 -f "${host_key_file}" >/dev/null
        chmod 0600 "${host_key_file}"
    fi
    if [ -n "${ALPINE_ZFSBOOT_NET}" ]; then
        printf 'alpine-zfsboot.net=%s\n' "${ALPINE_ZFSBOOT_NET}" >> "${config_file}"
    fi
    if [ -n "${ALPINE_ZFSBOOT_IPV4}" ]; then
        printf 'alpine-zfsboot.ipv4=%s\n' "${ALPINE_ZFSBOOT_IPV4}" >> "${config_file}"
    fi
    if [ -n "${ALPINE_ZFSBOOT_IPV4_ADDRESS}" ]; then
        printf 'alpine-zfsboot.ipv4.address=%s\n' "${ALPINE_ZFSBOOT_IPV4_ADDRESS}" >> "${config_file}"
    fi
    if [ -n "${ALPINE_ZFSBOOT_IPV4_GATEWAY}" ]; then
        printf 'alpine-zfsboot.ipv4.gateway=%s\n' "${ALPINE_ZFSBOOT_IPV4_GATEWAY}" >> "${config_file}"
    fi
    if [ -n "${ALPINE_ZFSBOOT_IPV6}" ]; then
        printf 'alpine-zfsboot.ipv6=%s\n' "${ALPINE_ZFSBOOT_IPV6}" >> "${config_file}"
    fi
    if [ -n "${ALPINE_ZFSBOOT_IPV6_ADDRESS}" ]; then
        printf 'alpine-zfsboot.ipv6.address=%s\n' "${ALPINE_ZFSBOOT_IPV6_ADDRESS}" >> "${config_file}"
    fi
    if [ -n "${ALPINE_ZFSBOOT_IPV6_GATEWAY}" ]; then
        printf 'alpine-zfsboot.ipv6.gateway=%s\n' "${ALPINE_ZFSBOOT_IPV6_GATEWAY}" >> "${config_file}"
    fi
    if [ -n "${ALPINE_ZFSBOOT_SSH_LISTEN}" ]; then
        printf 'alpine-zfsboot.ssh.listen=%s\n' "${ALPINE_ZFSBOOT_SSH_LISTEN}" >> "${config_file}"
    fi
    if [ -n "${ALPINE_ZFSBOOT_SSH_PORT}" ]; then
        printf 'alpine-zfsboot.ssh.port=%s\n' "${ALPINE_ZFSBOOT_SSH_PORT}" >> "${config_file}"
    fi
    if [ -n "${ALPINE_ZFSBOOT_SSH_ALLOW}" ]; then
        printf 'alpine-zfsboot.ssh.allow=%s\n' "${ALPINE_ZFSBOOT_SSH_ALLOW}" >> "${config_file}"
    fi
    return 0
}

# BIOS mode: writes stage1 onto the disk's own protective-MBR boot sector
# (LBA 0), and stage2 + the boot blob onto the two dedicated partitions
# partition_disk() already created for them at the right position/size.
#
# Only the first 446 bytes of LBA 0 are ever touched, never the whole 512-
# byte sector - bytes 446-509 are the REAL partition table entry
# partition_disk() already wrote there, and bytes 510-511 are the 0xAA55
# boot signature it also already wrote correctly. Which tool wrote that
# table depends on DISK_LAYOUT: sgdisk's own protective-MBR GPT partition
# entry for DISK_LAYOUT=gpt (the default), or sfdisk's own real primary
# partition table for DISK_LAYOUT=msdos - either way stage1.bin's own copy
# of bytes 446-511 is just zero padding, since stage1.bin was built with no
# knowledge of this specific disk's actual partition layout (see the
# alpine-zfsboot repo's bios/stage1.S for the authoritative version of this
# same warning). Overwriting either would leave the disk with a broken
# partition table - every partitioning tool, and BIOS firmware itself,
# cares about both of those, unlike stage1's own now-overwritten code
# region.
install_alpine_zfsboot_bios() {
    # bs=446 count=1 - ONE single 446-byte write, not 446 separate
    # single-byte ones (an earlier version of this line used `bs=1
    # count=446`, which really did write successfully by dd's own exit
    # status every time, yet a REAL run's own read-back still didn't
    # match past the first ~64 bytes: confirmed directly via a hex dump
    # of both sides on a real failure - bytes 0-63 matched exactly,
    # stage1.bin's actual content past its ~56 bytes of real code is
    # all zero out to the 446-byte mark, and the disk's own read-back
    # diverged from that somewhere past byte 64. 446 separate 1-byte
    # write() calls to a raw block device is not the standard, well-
    # established way to write boot-sector code (every real-world MBR
    # installer uses one bs=446 write) for exactly this reason - it's
    # 446 separate opportunities for a sub-sector read-modify-write
    # cycle (what the block layer does under the hood for a write
    # smaller than the device's own logical/physical sector size) to
    # not fully land, instead of one atomic operation.
    dd if="${WORKDIR}/stage1.bin" of="${SYSDRIVE}" bs=446 count=1 conv=notrunc status=none

    dd if="${WORKDIR}/stage2.bin" of="${BIOS_BOOT_PARTITION}" bs=512 conv=notrunc status=none

    dd if="${WORKDIR}/bootblob.img" of="${BOOTBLOB_PARTITION}" bs=1M conv=notrunc status=none

    # Without this, the in-kernel block-device cache can still be holding
    # stale/partial data for these raw-written partitions - harmless once
    # the disk is actually rebooted into firmware, but a real, confirmable
    # gap for anything in THIS script that might try to re-read what was
    # just written (verify_installation() below does exactly that).
    sync
    blockdev --rereadpt "${SYSDRIVE}" 2>/dev/null || true
}

install_alpine_zfsboot() {
    log "Installing alpine-zfsboot"
    if [ "${USE_UEFI}" = "yes" ]; then
        install_alpine_zfsboot_uefi
    else
        install_alpine_zfsboot_bios
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
            die "Missing alpine-zfsboot EFI executable."
    else
        # A real byte-for-byte comparison, not just "does dd claim
        # success" - dd's own exit status says nothing about whether the
        # target device actually accepted every byte (a partition too
        # small, or a device that silently truncates writes, wouldn't
        # necessarily make dd itself fail).
        #
        # On a mismatch, this dumps BOTH sides (expected vs. actual, hex)
        # directly into THIS run's own log before dying - a real gap
        # this used to have: a bare "was not written correctly" message
        # gave no way to tell "wrote nothing at all" (all-zero disk
        # content) from "wrote something, but wrong" from "read back
        # stale/cached content" after the fact, since WORKDIR (holding
        # the one-and-only local copy of the expected bytes) is gone by
        # the time anyone can look - cleanup() removes it on the way out
        # via the EXIT trap, on this exact failure path included. Neither
        # ad-hoc investigation (re-deriving a path to compare against,
        # asking the operator to hunt for one) shouldn't be necessary to
        # diagnose the NEXT time this trips - this run's own log is
        # self-contained instead.
        check_disk_write() {
            local expected_file="$1" actual_device="$2" expected_bytes="$3" label="$4"
            local tmp_expected tmp_actual cmp_out offset window_start

            # Plain temp files, NOT process substitution (`<(...)`) -
            # an earlier version of this used two `<(...)` per cmp call,
            # confirmed a real, reproducible bug: `cmp` itself failing
            # with "/dev/fd/NN: No such file or directory" - bash's
            # process-substitution fds are not guaranteed to survive
            # being read twice in a row across two SEPARATE cmp
            # invocations (one plain `cmp -s`, then another wrapped in
            # `$(...)` for its own text output) the way a real
            # regular file trivially does. This diagnostic exists to
            # explain a real mismatch, not to add a second, different
            # failure mode on top of it.
            tmp_expected="$(mktemp)"
            tmp_actual="$(mktemp)"
            head -c "${expected_bytes}" "${expected_file}" > "${tmp_expected}"
            head -c "${expected_bytes}" "${actual_device}" > "${tmp_actual}"

            if cmp -s "${tmp_expected}" "${tmp_actual}"; then
                rm -f "${tmp_expected}" "${tmp_actual}"
                return 0
            fi

            # A fixed-size preview from the very START of the range
            # isn't enough (a real, confirmed miss: an earlier version
            # of this dumped only the first 64 bytes, which matched
            # exactly on a real failure whose actual divergence was
            # further in - looked like a false alarm until stage1.bin
            # was rebuilt locally and dumped in full by hand). `cmp`
            # itself (no -s) reports the exact byte offset of the first
            # real difference - a window AROUND that offset, not the
            # whole range, since expected_bytes can be tens of millions
            # for the boot-blob, where a full hex dump would flood this
            # log for no benefit.
            cmp_out="$(cmp "${tmp_expected}" "${tmp_actual}" 2>&1 || true)"
            echo "MISMATCH: ${label} - ${cmp_out}" >&2
            offset="$(printf '%s' "${cmp_out}" | sed -n 's/.*byte \([0-9][0-9]*\).*/\1/p')"
            if [ -n "${offset}" ]; then
                window_start=$(( offset > 32 ? offset - 32 : 0 ))
                echo "MISMATCH: ${label} - expected, 64 bytes starting at offset ${window_start} (differing byte is ${offset}):" >&2
                od -An -tx1 -v -j "${window_start}" -N 64 "${tmp_expected}" >&2
                echo "MISMATCH: ${label} - actual, 64 bytes starting at offset ${window_start}:" >&2
                od -An -tx1 -v -j "${window_start}" -N 64 "${tmp_actual}" >&2
            fi
            rm -f "${tmp_expected}" "${tmp_actual}"
            return 1
        }

        check_disk_write "${WORKDIR}/stage1.bin" "${SYSDRIVE}" 446 "stage1" ||
            die "stage1 was not written to ${SYSDRIVE} correctly (see the hex dump just above)."
        check_disk_write "${WORKDIR}/stage2.bin" "${BIOS_BOOT_PARTITION}" \
            "$(stat -c%s "${WORKDIR}/stage2.bin" 2>/dev/null || wc -c < "${WORKDIR}/stage2.bin")" "stage2" ||
            die "stage2 was not written to ${BIOS_BOOT_PARTITION} correctly (see the hex dump just above)."
        check_disk_write "${WORKDIR}/bootblob.img" "${BOOTBLOB_PARTITION}" \
            "$(stat -c%s "${WORKDIR}/bootblob.img" 2>/dev/null || wc -c < "${WORKDIR}/bootblob.img")" "boot-blob" ||
            die "boot-blob was not written to ${BOOTBLOB_PARTITION} correctly (see the hex dump just above)."
    fi

    test -f "${MOUNT_LOCATION}/etc/hostid" ||
        die "Missing /etc/hostid."

    if [ "${SWAP_SIZE_GIB}" -gt 0 ]; then
        # grep -c, not -q - see cleanup()'s own identical comment.
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
        boot_summary="alpine-zfsboot is installed at EFI/BOOT/${EFI_FALLBACK_NAME}."
    else
        boot_summary="alpine-zfsboot boots directly via its own stage1/stage2 code (no other bootloader involved)."
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
    select_zfsboot_artifacts
    fetch_zfsboot_artifacts
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
    install_alpine_zfsboot
    verify_installation
    print_summary

    trap - EXIT
    cleanup
}

main "$@"
