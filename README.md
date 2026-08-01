# Vanilla Arch Linux ARM for Xiaomi Pad 6 (Pipa)

Build infrastructure for a **vanilla, un-rebranded Arch Linux ARM** image
for the Xiaomi Pad 6 ("pipa"), assembled from three source repos. The image
is **zero-touch**: the user account, hostname, and `/etc/fstab` mounts are
all set up at build time inside the chroot, `pacman` uses 50 parallel
downloads everywhere (builder container and the image's own `pacman.conf`),
and the device boots straight into an autologin'd desktop session — there
is no first-boot setup wizard.

| Repo | Role in this build |
|---|---|
| [`maakiopus/PKGBUILDs-pipa`](https://github.com/maakiopus/PKGBUILDs-pipa) | Original upstream package source tree. Used as the fallback source base (`scripts/build-from-source.sh`) for anything missing from the two binary repos below — see `AUR/comments` in each PKGBUILD for provenance. |
| [`maakiopus/pipa-alarm`](https://github.com/maakiopus/pipa-alarm) | Binary pacman repo. Supplies the "extra" user-facing packages (`box64`, `gamescope`, `mangohud-git`, `mkbootimg-pipa`, `widevine`, `wine-aarch64`) — the exact set that `pipa-pkgs` itself does not build locally and sources from here. |
| [`thespider2/pipa-pkgs`](https://github.com/thespider2/pipa-pkgs) | Actively-maintained binary pacman repo. Supplies the kernel and hardware-enablement stack via its `pipa-metapkg` meta-package (kernel, firmware, audio, sensors, GRUB helper, dracut module, etc.), plus `linux-pipa` and the kernel-flasher hook directly. |

Build-process structure (pacstrap flow, chrooted service enablement,
first-boot user setup, GRUB/EFI partition layout) is adapted from
[`aymanrgab/endeavouros-pipa`](https://github.com/aymanrgab/endeavouros-pipa),
with all EndeavourOS branding, keyring/mirrorlist packages, and `eos-*`
packages removed so the resulting image is stock Arch Linux ARM.

## ⚠️ Important — what this actually is

I (Claude) cloned and read all four repos and wrote the build system below.
I **have not run it to completion** and cannot hand you a finished `.zip`/
`.img` from this chat. Producing one requires:

- **Privileged Docker** (loop devices, `mkfs`, `mount --bind`) — this chat's
  sandbox doesn't have that.
- **Native aarch64, or qemu-user-static binfmt on x86_64** — pacstrap has to
  run `arch-chroot` binaries for the target architecture.
- **Network access to arbitrary hosts** (`thespider2.github.io`,
  `maakiopus.github.io`, `github.com/onesaladleaf/.../releases`, the Arch
  Linux ARM mirrors) — this chat's sandbox only allows a short list of
  package-registry domains (crates.io, pypi, npm, github.com itself), which
  is enough to `git clone` the four repos but not enough to actually pull
  packages/firmware/kernel sources at build time.
- **Real time and disk** — a full kernel + Plasma/GNOME pacstrap build is
  30–90+ minutes and several GB, even on capable ARM hardware.

So what's here is a **complete, ready-to-run build system** — the actual
deliverable you asked for — that you run yourself on a Linux box (ideally
arm64; x86_64 with binfmt works too, just slower). It's not a stub: every
package name, file path, and systemd unit referenced below was checked
against the real PKGBUILDs in the three repos (see the "What I verified"
section).

## Building

```bash
make builder            # build the Docker builder image (once)
make plasma              # KDE Plasma image
make gnome                # GNOME image
make base                  # console-only, no desktop
make all                    # all three
```

Requires Docker on a host that can run `--privileged` containers with loop
device access. On x86_64 you additionally need `qemu-user-static` +
`binfmt-support` registered for aarch64.

```bash
docker run --rm --privileged \
  -v "$(pwd)/images:/build/images" -v /dev:/dev \
  archlinux-pipa-builder plasma
```

Output lands in `images/<name>.zip`, containing `silicium.img`,
`archlinux_esp.raw`, `archlinux_boot.raw`, `archlinux_rootfs.raw`,
`vbmeta.img`, `flash.sh`, `flash-multiboot.sh`, `BUILDINFO.txt`,
`SHA256SUMS` — flash with `./flash.sh` after extracting.

### Build environment variables

| Variable | Default | Description |
|---|---|---|
| `PIPA_PKGS_REPO_URL` | `https://thespider2.github.io/pipa-pkgs/repo/` | Kernel/system package repo |
| `PIPA_ALARM_REPO_URL` | `https://maakiopus.github.io/pipa-alarm/repo/` | Extra-package repo |
| `PIPA_INCLUDE_SENSORS` | `1` | Set `0` to omit sensor packages |
| `PIPA_INCLUDE_EXTRAS` | `1` | Set `0` to skip box64/gamescope/wine-aarch64/etc |
| `PIPA_DEFAULT_USER` | `pipa` | Username auto-created at build time (wheel/video/audio/input/storage groups) |
| `PIPA_DEFAULT_PASSWORD` | `pipa` | Password for that user *and* root — **change it after first boot** |
| `PIPA_DEFAULT_HOSTNAME` | `pipa` | Hostname baked into the image |
| `BUILD_GIT_REV` | `unknown` | Stamped into `BUILDINFO.txt` |

No first-boot wizard runs — the account above is created and password-set
inside the chroot during the build, `/etc/fstab` mounts `/` and `/boot` by
label automatically, and the appropriate display manager
(`sddm`/`gdm`/`agetty`) is configured to autologin that user straight into
the desktop session (or a tty for the `base` image).

Both repo hosts (GitHub Pages) have had outages historically — the build
script installs the `pipa-alarm` extras with `pacman -Si` existence checks
first and continues without them if the repo is down, same pattern the
`endeavouros-pipa` build used.

## What I verified while writing this

- `pipa-metapkg` (pipa-pkgs) `depends=()` lists the full kernel/hardware
  stack, so pulling it in lets pacman's dependency resolver do the version
  matching instead of a hand-maintained package list drifting out of date.
- `linux-pipa`'s `package()` function installs `boot/Image.gz`,
  `boot/vmlinuz-$kver(.uncompressed)`, and
  `boot/dtbs/qcom/sm8250-xiaomi-pipa.dtb` — matches what `build-image.sh`
  looks for when assembling the boot partition.
- `pipa-sound-conf`, `pipa-sensors`, `pipa-grub-config`, `pipa-dracut`
  install exactly the file paths the script's `assert_required_rootfs_*`
  checks expect (`/usr/local/bin/pipa-refresh-grub-config`,
  `/usr/lib/dracut/dracut.conf.d/10-pipa.conf`, the wireplumber/hexagonrpcd
  unit-drop-ins, etc.).
- `packages.upstream.txt` in `pipa-pkgs` lists exactly
  `box64 gamescope mangohud-git mkbootimg-pipa widevine wine-aarch64` as
  "no local PKGBUILD, source from pipa-alarm upstream" — that's where the
  `PIPA_ALARM_EXTRA_PACKAGES` list in `build-image.sh` comes from.

## What changed vs. the EndeavourOS reference build

- No `endeavouros-branding` / `-keyring` / `-mirrorlist` / `-theming`, no
  `eos-*` packages, no `welcome` app, no `grub2-theme-endeavouros-classic`.
- Display manager is stock `sddm` (Plasma) / `gdm` (GNOME) instead of
  `plasmalogin`, autologging in the build-time-created `PIPA_DEFAULT_USER`
  directly — no interactive first-boot wizard like EndeavourOS's account
  creation dialog.
- Added a `base` (console-only) image type, with `agetty --autologin`
  configured on tty1 for the same default user.
- `pacman`'s `ParallelDownloads` is forced to `50` in both the builder
  container's own `pacman.conf` and the one baked into the final image.
- `PIPA_ALARM_EXTRA_PACKAGES` sourced from a second, separate repo section
  instead of being folded into the same "Pipa" repo as the kernel/system
  packages — kept deliberately separate since they come from a different
  upstream (`maakiopus` vs `thespider2`) with independent uptime.
- EFI vendor directory renamed `endeavour` → `archlinux` for the boot menu
  entry text; the underlying `shimaa64.efi`/`grubaa64.efi`/`mmaa64.efi`
  binaries are copied through unchanged (see caveat below).

## Known caveat: the EFI shim binaries

`efi-template/EFI/archlinux/{shimaa64,grubaa64,mmaa64}.efi` are the same
**pre-signed** binaries from the `endeavouros-pipa` repo, copied through
as-is. They're signed shim/GRUB binaries trusted by this device's existing
Mu-Silicium/pocketblue UEFI boot chain — I can't produce new signed
binaries, and neither can a plain `makepkg` build, so reusing a known-good
signed shim (the same trick the reference repo uses by also duplicating
into an `EFI/fedora` directory) is the only practical route. If you'd
rather use Arch's own `shim-signed`/`grub` packages instead, you'll need to
confirm they're trusted by this device's boot chain before swapping them in
— that's outside what I could verify without hardware in hand.

## Building an individual package from source

If a package is stale or missing in both binary repos:

```bash
./scripts/build-from-source.sh box64
# or against a repo you've already cloned:
./scripts/build-from-source.sh linux-pipa /path/to/PKGBUILDs-pipa
```

This clones `maakiopus/PKGBUILDs-pipa` and runs `makepkg -sf` in the given
package directory. Needs to run on aarch64 (or under binfmt) since these
build ARM64 binaries/kernels.
