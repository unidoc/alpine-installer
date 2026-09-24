# alpine-installer

Two self-contained shell scripts that install Alpine Linux onto a disk from
any Linux rescue environment - no images to burn, no network install server
to run. Point them at a disk, give them an SSH key, and they do the rest.

**We recommend `alpine-install-zfs.sh`.** It's what we run in production -
every UniDoc [Incus](https://github.com/unidoc/unidoc-aports) host is
installed this way - specifically for the boot-environment rollback ZFS
gives you: a bad upgrade or a bad config change is one
[alpine-zfsboot](https://github.com/unidoc/alpine-zfsboot) menu selection
away from undone, which a plain ext4 root just can't offer. Reach for
`alpine-install-normal.sh` only when you specifically need LVM, a
non-standard partition layout, or want to avoid ZFS's operational model
(licensing questions, unfamiliarity, a target that doesn't suit it).

```sh
wget https://raw.githubusercontent.com/unidoc/alpine-installer/master/alpine-install-zfs.sh
chmod +x alpine-install-zfs.sh
PUBKEY="ssh-ed25519 AAAA... you@host" SYSDRIVE="/dev/sda" ./alpine-install-zfs.sh
```

or, for a plain (non-ZFS) install:

```sh
wget https://raw.githubusercontent.com/unidoc/alpine-installer/master/alpine-install-normal.sh
chmod +x alpine-install-normal.sh
PUBKEY="ssh-ed25519 AAAA... you@host" SYSDRIVE="/dev/sda" ./alpine-install-normal.sh
```

**These scripts destroy all data on `SYSDRIVE` without a confirmation
prompt.** Read them before you run them against anything you care about -
they're plain, commented bash, not a black box.

**Run them as `./script.sh` (after `chmod +x`), not `sh script.sh`.**
Both scripts use real bash features (arrays, in particular) and start
with `#!/bin/bash` - `./script.sh` always honors that shebang and picks
bash automatically, no matter what your login shell is. Typing
`sh script.sh` instead explicitly runs BusyBox ash on a lot of rescue
environments (including `alpine-rescue`) - ash ignores the shebang
entirely and fails with a confusing `syntax error: unexpected "("`, and
it's an easy typo to make worse (`sh bash script.sh` isn't `bash
script.sh`, it's `sh` trying to open a file literally named `bash`). If
you'd rather not `chmod +x`, `bash script.sh` also works - just not
plain `sh`.

**Quote every `VAR="value"`, always - including plain words like
`SYSDRIVE="/dev/sda"` or `USE_SERIAL="no"`.** They don't strictly need
quotes on their own, but once you're adding several variables to one
command line it's easy to put one `VAR="value"` *inside* another one's
quotes by mistake - `PUBKEY="...key... USE_SERIAL="no" ...comment"`
looks reasonable but the second `"` there just closes and reopens
`PUBKEY`'s own quoting (bash doesn't nest double quotes), silently
merging `USE_SERIAL="no"` into the PUBKEY value instead of setting it as
its own variable. Quoting everything, every time, means there's only
one pattern to follow instead of a rule about which variables "need"
it - each `VAR="value"` stays visually self-contained and the mistake
above becomes obvious instead of silent.

## Which one do I want?

| | `alpine-install-zfs.sh` | `alpine-install-normal.sh` |
|---|---|---|
| Recommended | **Yes** - our own default, including for Incus hosts | Only when you have a specific reason to avoid ZFS |
| Root filesystem | ZFS, boots via [alpine-zfsboot](https://github.com/unidoc/alpine-zfsboot) | ext4 (optionally on LVM), boots via GRUB |
| Layout | One opinionated pool/dataset shape - not configurable | Swap on/off, LVM on/off, or bring your own partitioning (`SKIP_PARTITIONING=yes`) |
| Snapshots/rollback | Yes (that's the point of ZFS here) | No |
| Best for | Production installs, especially Incus/virtualization hosts | LVM, a custom partition layout, or deliberately avoiding ZFS |

They're kept as two separate scripts on purpose - ZFS's opinionated layout
and the flexible non-ZFS one don't belong forced into one code path.

## Credentials: no defaults, ever

`PUBKEY` is **required**. Both scripts refuse to run at all if it isn't
set - there is no fallback key baked in anywhere, and there never will be.
Set it to one or more `ssh-ed25519`/`ssh-rsa`/`ecdsa-sha2-*` lines
(newline-separated for more than one):

```sh
export PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... me@laptop"
```

Root's **password** is left empty - not set to anything, not locked
either. That specific choice matters:

- An empty password field in `/etc/shadow` means "no password required"
  ([`shadow(5)`](https://man7.org/linux/man-pages/man5/shadow.5.html)) -
  so whoever has real physical or KVM console access can log in as root
  with no password at all, and run `passwd` there to set a real one.
- `sshd` is configured with `PermitEmptyPasswords no` (OpenSSH's own
  compiled-in default, set explicitly here so it doesn't quietly depend
  on staying that way) - so that same empty password is refused outright
  over SSH. The only way in over the network, until someone sets a
  password at the console, is your `PUBKEY`.

This is the same locked-until-console-`passwd` idea behind
[SystemRescue](https://www.system-rescue.org/)/Finnix-style rescue images
(and the one [`alpine-rescue`](https://github.com/unidoc/alpine-rescue)
already uses) - adapted for a persistent install rather than a live boot.
A live rescue image can get away with never touching `/etc/shadow` at all
because it auto-logs into the console without ever checking a password;
a real install's console runs a normal login prompt, so these scripts
have to clear the password field explicitly (`passwd -d root`) to get the
same "console: yes, network: no" behavior.

## Alpine version

Neither script hardcodes a version. Leave `ALPINE_VERSION` unset and they
look up whatever [`latest-stable`](https://dl-cdn.alpinelinux.org/alpine/latest-stable/)
actually is at run time; set `ALPINE_VERSION=3.24.1` (or similar) yourself
to pin a specific release instead.

## Configuration

Every knob is an environment variable with a sane default - export what
you need to override, run the script, nothing to edit. Both scripts:

| Variable | Default | Meaning |
|---|---|---|
| `PUBKEY` | *(required)* | SSH public key(s) for root |
| `SYSDRIVE` | `/dev/sda` | Disk to install onto - **destroyed** |
| `SYSHOSTNAME` | `alpine` | Hostname |
| `ALPINE_VERSION` | *(auto-detected)* | Pin a specific Alpine release |
| `USE_UEFI` | `auto` | `auto`/`yes`/`no` - detects `/sys/firmware/efi` |
| `USE_SERIAL` | `auto` | `auto`/`yes`/`no` - `auto` checks the rescue system's own kernel command line for `console=ttyS0`/`console=ttyAMA0` (see `detect_serial()`) rather than the live tty, since an SSH session into the rescue system says nothing about what will actually be available to reach alpine-zfsboot's own menu after reboot |
| `SWAP_SIZE_GIB` | `2` (zfs) / `0` (normal) | Swap partition size; `0` disables it |
| `VIRT` | `auto` | `auto`/`yes`/`no` - `yes` installs `linux-virt`, `no` installs `linux-lts`. `auto` guesses from a CPUID hypervisor flag, an ARM hypervisor device-tree node, and DMI vendor strings (see `detect_virt()`) - a heuristic, not a certainty; force it if you already know |

`alpine-install-zfs.sh` also has `POOL_NAME` (documented inline above its
declaration in the script) and the variables below - see "alpine-zfsboot
artifacts" for the `ALPINE_ZFSBOOT_EFI_*`/`ALPINE_ZFSBOOT_BIOS_*` boot
artifact overrides.

| Variable | Default | Meaning |
|---|---|---|
| `DISK_LAYOUT` | `gpt` | `gpt`/`msdos` - legacy BIOS mode's disk-partitioning scheme (`USE_UEFI=no` only; there is no msdos+UEFI path, UEFI firmware needs GPT+ESP). Both are real, first-class layouts - alpine-zfsboot's own boot code auto-detects which is on disk at boot time |
| `ENCRYPT_ZROOT` | `no` | `yes` makes the ZFS `ROOT` container itself the encryption root (`aes-256-gcm`, one passphrase) - every boot environment, current and future, inherits it automatically. Requires `ZROOT_PASSPHRASE` |
| `ZROOT_PASSPHRASE` | *(empty)* | Required when `ENCRYPT_ZROOT=yes`. Never put this on a command line - export it |

**Per-machine rescue SSH/network settings** - available on every layout
(UEFI, legacy BIOS/GPT, and legacy BIOS/msdos alike: alpine-zfsboot's own
unified storage architecture means every install carries the same
canonical FAT/ESP partition, not just UEFI ones). Written to
`/EFI/ALPINE/` on that partition for alpine-zfsboot's own `/init`
to read at every boot, regardless of which firmware path got the kernel
running - all optional, nothing here is required for a plain, non-rescue
install:

| Variable | Meaning |
|---|---|
| `ALPINE_ZFSBOOT_SSH_KEY` | One or more (newline-separated) raw SSH public key lines, written verbatim as `authorized_keys` for alpine-zfsboot's own rescue SSH. Setting this is what actually turns rescue SSH on - everything below is meaningless without it |
| `ALPINE_ZFSBOOT_NET` | `dhcp`/`static` - default network mode for both families (per-family below overrides it) |
| `ALPINE_ZFSBOOT_IPV4` / `ALPINE_ZFSBOOT_IPV6` | `off`/`dhcp`/`static` - per-family override |
| `ALPINE_ZFSBOOT_IPV4_ADDRESS` / `ALPINE_ZFSBOOT_IPV6_ADDRESS` | Static address (CIDR) for that family |
| `ALPINE_ZFSBOOT_IPV4_GATEWAY` / `ALPINE_ZFSBOOT_IPV6_GATEWAY` | Static gateway for that family |
| `ALPINE_ZFSBOOT_SSH_LISTEN` | Bind address override for rescue SSH |
| `ALPINE_ZFSBOOT_SSH_PORT` | Port override for rescue SSH |
| `ALPINE_ZFSBOOT_SSH_ALLOW` | Source-CIDR allowlist for rescue SSH (default-deny otherwise) |

`alpine-install-normal.sh` also has:

| Variable | Default | Meaning |
|---|---|---|
| `USE_LVM` | `no` | Put root on an LVM logical volume (`vg0/root`) instead of a raw partition |
| `LVM_VG_NAME` / `LVM_LV_NAME` | `vg0` / `root` | Names for the above |
| `SKIP_PARTITIONING` | `no` | Partition the disk yourself first, then point `ROOT_PARTITION` (and `EFI_PARTITION`/`SWAP_PARTITION` if applicable) at the result - the script does everything from formatting onward |

`USE_LVM` and `SKIP_PARTITIONING` are the two levers this repo offers for
"I want a different partition layout" - a full custom-partitioning DSL
felt like solving a problem nobody has when "just partition it yourself
and hand the script the device path" already works.

## alpine-zfsboot artifacts

`alpine-install-zfs.sh` needs alpine-zfsboot's own boot artifacts -
[alpine-zfsboot](https://github.com/unidoc/alpine-zfsboot) publishes and
builds these itself now (a separate project with its own release
pipeline), not something this repo builds or hosts. Every default below
resolves against `releases/latest/download/...` on that repo - asset
filenames are arch-based and unversioned by design there, so a new
alpine-zfsboot release just works with no change needed here.

UEFI mode fetches one file - alpine-zfsboot's own self-contained `.EFI`
(kernel+initramfs+cmdline all bundled):

| Variable | Default |
|---|---|
| `ALPINE_ZFSBOOT_EFI_X86_64_URL` | `alpine-zfsboot-x86_64.EFI` from the latest release |
| `ALPINE_ZFSBOOT_EFI_AARCH64_URL` | `alpine-zfsboot-aarch64.EFI` from the latest release |
| `ALPINE_ZFSBOOT_EFI_URL` / `ALPINE_ZFSBOOT_EFI_FILE` | Override the resolved URL, or point at a local file instead (skips downloading) |

Legacy BIOS mode (x86_64 only) fetches five: `stage1` (the
protective-MBR boot sector), `stage2` (GPT/MBR-parsing + a minimal
read-only FAT32 reader + Linux boot-protocol code), and the same loose
`kernel`/`initrd`/`cmdline` files UEFI mode's own `.EFI` already bundles -
copied onto the canonical FAT/ESP partition as ordinary files
(`EFI/ALPINE/{KERNEL,INITRD,CMDLINE}`), not packed into a separate format:

| Variable | Default |
|---|---|
| `ALPINE_ZFSBOOT_BIOS_STAGE1_URL` | `alpine-zfsboot-x86_64-bios-stage1.bin` |
| `ALPINE_ZFSBOOT_BIOS_STAGE2_URL` | `alpine-zfsboot-x86_64-bios-stage2.bin` |
| `ALPINE_ZFSBOOT_BIOS_KERNEL_URL` | `alpine-zfsboot-x86_64-vmlinuz` |
| `ALPINE_ZFSBOOT_BIOS_INITRD_URL` | `alpine-zfsboot-x86_64-initramfs.img` |
| `ALPINE_ZFSBOOT_BIOS_CMDLINE_URL` | `alpine-zfsboot-x86_64-cmdline.txt` |
| `ALPINE_ZFSBOOT_BIOS_STAGE1_FILE` / `_STAGE2_FILE` / `_KERNEL_FILE` / `_INITRD_FILE` / `_CMDLINE_FILE` | Same local-file overrides as `_EFI_FILE` above, one per artifact |

`ALPINE_ZFSBOOT_CHECKSUMS_URL` defaults to that same release's own
`SHA256SUMS` - every downloaded artifact is checked against it
(`verify_zfsboot_checksum()`); a custom `*_URL` pointing somewhere this
project doesn't control just skips verification with a warning, since
there's no entry to check it against either way.

Every default `*_URL` above (never a custom one you've set) is also
pinned to ONE resolved release tag before anything is fetched
(`pin_zfsboot_release_urls()`, called from `fetch_zfsboot_artifacts()`)
- a single GitHub API lookup shared across every artifact this run
actually needs, rather than each one independently resolving
`releases/latest/download/...` on its own. Without this, a new
alpine-zfsboot release published mid-install could - in principle -
have left different artifacts (and the checksums file itself) coming
from two different releases, each individually checksum-verified but
never cross-checked against each other. A local `*_FILE` override
never touches the network at all and is unaffected.

One more thing this script depends on, regardless of firmware:
`alpine-zfsboot` itself (`cmd/tool` in that repo) - the CLI that now owns
writing/verifying every boot artifact above. This installer no longer
implements stage1/stage2/EFI-loader/FAT-payload/config writing itself; it
runs `alpine-zfsboot install` (`dd` at a fixed LBA is that command's own
implementation detail now, not something this script - or an
administrator - does by hand).

Unlike every other artifact above, this is **not** fetched from GitHub at
install time - it's a required system command, exactly like `sgdisk` or
`dropbear` (see `apk_package_for_command()`/`require_command()`): install
it ahead of time with `apk add alpine-zfsboot` (already packaged in
`unidoc-aports`), and this script just calls it by name. If it's genuinely
missing, `require_command()`'s own `apk add` fallback installs it
automatically, same as any other required command.

Once installed, the same binary is the ongoing management interface for
that machine's own alpine-zfsboot boot environment - `alpine-zfsboot
status`/`verify`/`update`, run directly on the target, firmware detected
automatically (see that repo's own README).

## What these scripts don't do

- Ask you anything interactively. Everything is an env var; there's no
  wizard, no confirmation prompt before the disk gets wiped.
- Support multi-disk arrays or network installs. (`alpine-install-zfs.sh`
  does support ZFS-native root encryption - see `ENCRYPT_ZROOT` above;
  `alpine-install-normal.sh` has no encryption option at all.)
- Manage anything after the first boot - once Alpine is up, it's just
  Alpine.
