# alpine-installer

Two self-contained shell scripts that install Alpine Linux onto a disk from
any Linux rescue environment - no images to burn, no network install server
to run. Point them at a disk, give them an SSH key, and they do the rest.

**We recommend `alpine-install-zfs.sh`.** It's what we run in production -
every UniDoc [Incus](https://github.com/unidoc/unidoc-aports) host is
installed this way - specifically for the boot-environment rollback ZFS
gives you: a bad upgrade or a bad config change is one `zfsbootmenu` boot
away from undone, which a plain ext4 root just can't offer. Reach for
`alpine-install-normal.sh` only when you specifically need LVM, a
non-standard partition layout, or want to avoid ZFS's operational model
(licensing questions, unfamiliarity, a target that doesn't suit it).

```sh
wget https://raw.githubusercontent.com/unidoc/alpine-installer/master/alpine-install-zfs.sh
PUBKEY="ssh-ed25519 AAAA... you@host" SYSDRIVE=/dev/sda sh alpine-install-zfs.sh
```

or, for a plain (non-ZFS) install:

```sh
wget https://raw.githubusercontent.com/unidoc/alpine-installer/master/alpine-install-normal.sh
PUBKEY="ssh-ed25519 AAAA... you@host" SYSDRIVE=/dev/sda sh alpine-install-normal.sh
```

**These scripts destroy all data on `SYSDRIVE` without a confirmation
prompt.** Read them before you run them against anything you care about -
they're plain, commented bash, not a black box.

## Which one do I want?

| | `alpine-install-zfs.sh` | `alpine-install-normal.sh` |
|---|---|---|
| Recommended | **Yes** - our own default, including for Incus hosts | Only when you have a specific reason to avoid ZFS |
| Root filesystem | ZFS, boots via [ZFSBootMenu](https://zfsbootmenu.org) | ext4 (optionally on LVM), boots via GRUB |
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
| `USE_SERIAL` | `no` | Enable the serial console (`ttyS0`/`ttyAMA0`) |
| `SWAP_SIZE_GIB` | `2` (zfs) / `0` (normal) | Swap partition size; `0` disables it |
| `VIRT` | `auto` | `auto`/`yes`/`no` - `yes` installs `linux-virt`, `no` installs `linux-lts`. `auto` guesses from a CPUID hypervisor flag, an ARM hypervisor device-tree node, and DMI vendor strings (see `detect_virt()`) - a heuristic, not a certainty; force it if you already know |

`alpine-install-zfs.sh` also has `POOL_NAME` (documented inline above its
declaration in the script) and the `ZBM_*` overrides - see "ZFSBootMenu
artifacts" below.

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

## ZFSBootMenu artifacts

`alpine-install-zfs.sh` needs a ZFSBootMenu boot image. We build all of
them ourselves - one EFI image per arch (not split by console type), plus
the BIOS Components pair - and publish them as
[GitHub Releases](https://github.com/unidoc/alpine-installer/releases) on
this repo (`.github/workflows/build-zbm-images.yml`, manual dispatch
only - deliberately no schedule, since these get baked directly into
installed systems' boot process with no PR/review gate in between; an
automatic rebuild would silently change what
`releases/latest/download/...` resolves to for anyone installing
afterward). Not GitHub Pages, not `unidoc-aports` (these are boot
binaries, not Alpine packages, a genuinely different artifact shape).
Every case below has a working default out of the box - no override
needed:

| Case | Default source |
|---|---|
| x86_64, UEFI | Built by us - one image, both VGA and serial baked into the kernel command line |
| aarch64, UEFI | Built by us - one image, both VGA and serial baked in |
| x86_64, legacy BIOS (Components: kernel+initramfs) | Built by us |

**One image per arch, not one per console type, is a deliberate,
not-fully-verified bet.** The kernel accepts multiple `console=`
parameters and sends boot messages to all of them; ZFSBootMenu's own
docs don't say whether its interactive menu itself works on more than
one at once (only `/dev/console` - whichever `console=` was listed last
- is guaranteed). Low-stakes to find out empirically rather than
research further: if the non-primary console turns out unusable for the
actual interactive menu, that's a one-line workflow change (split back
into two builds), not a rewrite - open a PR.

Point `ZBM_EFI_URL`/`ZBM_VMLINUZ_URL`/`ZBM_INITRAMFS_URL` (or the
`_FILE` variants) at your own image instead, if you'd rather not use
ours - e.g. ZFSBootMenu's own official `https://get.zfsbootmenu.org/efi`
for a stock x86_64 UEFI VGA-only image.

- **x86_64** uses ZFSBootMenu's own official builder container
  (`ghcr.io/zbm-dev/zbm-builder`, pinned to a dated tag) - same
  mechanism as their own official release build.
- **aarch64** has no pre-built builder container (confirmed amd64-only
  by inspecting its image manifest) and no aarch64 path in upstream's
  own CI at all, so there was nothing to just reuse. Instead, the
  workflow checks out ZFSBootMenu's source (pinned to a tag, no fork
  needed - see below) and builds the builder image itself, natively, on
  a real arm64 GitHub-hosted runner (`ubuntu-24.04-arm`) - no
  cross-compilation. That distinction is load-bearing: an earlier,
  separate attempt at this exact build cross-compiled the builder image
  for arm64 from amd64 hardware via `docker buildx --platform
  linux/arm64`, which was impractically slow, because Void Linux's `zfs`
  package triggers a real DKMS/gcc compile of the OpenZFS kernel module
  and QEMU user-mode emulation makes that painful. A native arm64
  runner has no such penalty.

**No zfsbootmenu fork needed.** Both jobs apply the same fix (see next
paragraph) as one extra `dracut.conf.d` file, written fresh in CI every
run rather than maintained as a patch against a cloned/forked source
tree - it's purely additive config, not a code change to the generator,
so it survives `ZFSBOOTMENU_REF` version bumps with zero drift risk
instead of needing to be manually rebased each time upstream moves.

**The console/zfs-module fix.** Building via a container (rather than
on real target hardware) runs ZFSBootMenu's dracut module in
generic/non-hostonly mode, which hits two real bugs neither job would
work without:

1. Upstream's own `omit-drivers.conf` blanket-omits `drm` (the
   rationale - real GPU hardware rarely reinitializes after a `kexec` -
   doesn't apply here: ZBM boots directly via EFI, no kexec involved).
   On a KVM/QEMU virtual machine (`virtio_gpu`), that omission is a
   black screen, not a missing feature - the shared `drm` core is what
   brings up any console at all.
2. ZFSBootMenu's own dracut module calls `instmods -c` for zfs/spl/etc
   as its "essential modules" check, but in a generic build that check
   silently does not copy the `.ko` files into the image - no build
   error, just a ZFSBootMenu that can never import a pool.

Both are fixed by one small `force_drivers`/`omit_drivers` override
(see the workflow for the exact file). Neither bug is aarch64-specific -
they were originally found while debugging ZFSBootMenu on an aarch64 KVM
VM, but they apply identically on x86_64 KVM/virtio_gpu targets, which
is exactly what most cloud/VPS installs are.

## What these scripts don't do

- Ask you anything interactively. Everything is an env var; there's no
  wizard, no confirmation prompt before the disk gets wiped.
- Support disk encryption, multi-disk arrays, or network installs.
- Manage anything after the first boot - once Alpine is up, it's just
  Alpine.
