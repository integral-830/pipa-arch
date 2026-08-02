# Vanilla Arch Linux ARM for Xiaomi Pad 6 (Pipa)

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
