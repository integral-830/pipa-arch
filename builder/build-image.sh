#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-image.sh [plasma|gnome|base]

Build a vanilla Arch Linux ARM image for the Xiaomi Pad 6 (Pipa).

Modes:
  plasma  KDE Plasma desktop image
  gnome   GNOME desktop image
  base    No desktop environment, console-only image

Environment variables:
  PIPA_PKGS_REPO_URL     pipa-pkgs pacman repo URL (kernel/system packages)
                          default: https://thespider2.github.io/pipa-pkgs/repo/
  PIPA_ALARM_REPO_URL    pipa-alarm pacman repo URL (extra/optional packages)
                          default: https://maakiopus.github.io/pipa-alarm/repo/
  PIPA_INCLUDE_SENSORS   Include sensor packages (default: 1)
  PIPA_INCLUDE_EXTRAS    Try to install box64/gamescope/wine-aarch64/etc from
                          pipa-alarm when available (default: 1)
  PIPA_DEFAULT_USER      Username created at build time (default: pipa)
  PIPA_DEFAULT_PASSWORD  Password for that user and for root
                          (default: pipa -- change this after first boot!)
  PIPA_DEFAULT_HOSTNAME  Hostname baked into the image (default: pipa)
  BUILD_GIT_REV          Git revision stamped into build metadata

The image is zero-touch: the user account, hostname, and filesystem mounts
(/etc/fstab by label) are all set up at build time inside the chroot, and
the image boots directly to a DE login/autologin -- no first-boot wizard.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "You must be root to run this script." >&2
    exit 1
fi

DE_NAME="${1:-plasma}"
DATE=$(date +%Y%m%d)
ROOTFS_DIR="rootfs"
IMAGE_DIR="images"
IMAGE_MNT="mnt_image"
ESP_MNT="mnt_esp"
BOOT_MNT="mnt_boot"
IMAGE_NAME="archlinux-pipa-${DE_NAME}-${DATE}"
ROOTFS_LABEL="arch-pipa"
BOOT_LABEL="boot"
ESP_LABEL="ARCHPIPAESP"
TARGET_KERNEL_CMDLINE="root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 console=ttyS0 earlycon quiet splash"
PACMAN_CONF="$(pwd)/pacman-pipa.conf"
EFI_TEMPLATE_DIR="$(pwd)/efi-template"
VBMETA_IMG="$(pwd)/vbmeta.img"

# --- Package sources -------------------------------------------------------
# PKGBUILDs-pipa (maakiopus) is the original upstream package source tree
# these packages trace back to. It is not consumed directly here (it has no
# published binary repo of its own); it is kept as a source fallback -- see
# scripts/build-from-source.sh -- for anything missing from the two binary
# repos below.
#
# pipa-pkgs (thespider2) is the actively-maintained repo and is used for the
# kernel + core hardware-enablement stack via its pipa-metapkg meta-package.
#
# pipa-alarm (maakiopus) is used for a short list of "extra" user-facing
# packages (box64, gamescope, wine-aarch64, ...) that pipa-pkgs itself
# doesn't build locally and instead sources from pipa-alarm upstream.
PIPA_PKGS_REPO_NAME="pipa-pkgs"
PIPA_ALARM_REPO_NAME="pipa-alarm"
PIPA_PKGS_REPO_URL="${PIPA_PKGS_REPO_URL:-https://thespider2.github.io/pipa-pkgs/repo/}"
PIPA_ALARM_REPO_URL="${PIPA_ALARM_REPO_URL:-https://maakiopus.github.io/pipa-alarm/repo/}"
SILICIUM_URL="https://github.com/onesaladleaf/Mu-Silicium/releases/download/v3.5-pocketblue/Mu-pipa.img"
SILICIUM_SHA256="ea3e1e123beea7ee5394295bdfee75054711d4734e9403831fda7f037fc900b6"
PIPA_INCLUDE_SENSORS="${PIPA_INCLUDE_SENSORS:-1}"
PIPA_INCLUDE_EXTRAS="${PIPA_INCLUDE_EXTRAS:-1}"
# Zero-touch first boot: this account is created and logged in automatically
# -- there is no first-boot wizard. Change the password after first boot.
PIPA_DEFAULT_USER="${PIPA_DEFAULT_USER:-pipa}"
PIPA_DEFAULT_PASSWORD="${PIPA_DEFAULT_PASSWORD:-pipa}"
PIPA_DEFAULT_HOSTNAME="${PIPA_DEFAULT_HOSTNAME:-pipa}"
ESP_SIZE_MB=128
BOOT_SIZE_MB=1024

# pipa-metapkg (from pipa-pkgs) depends on the full kernel/hardware stack:
# linux-pipa, xiaomi-pipa-firmware, qbootctl, pipa-dracut, pipa-grub-config,
# pipa-sound-conf, swclock-offset, bootmac, bluez-git, pipa-sensors, libssc,
# libcamera(+ipa/tools/gst/pipewire), qrtr, tqftpserv, pd-mapper,
# wireless-regdb, tuned(+ppd), ath10k-shutdown, make-dynpart-mappings,
# qca-swiss-army-knife, usb-network. Pulling the meta-package instead of
# hand-listing each one lets pacman's own dependency resolution stay correct
# as pipa-pkgs updates versions.
PIPA_META_PACKAGES=(pipa-metapkg)
PIPA_CORE_PACKAGES=(
    linux-pipa
    pipa-kernel-flasher-hook
)
if [ "$PIPA_INCLUDE_SENSORS" = "1" ]; then
    PIPA_CORE_PACKAGES+=(hexagonrpc iio-sensor-proxy)
fi

# "Various important newer packages" pulled from maakiopus/pipa-alarm.
# These match exactly what pipa-pkgs itself lists as upstream-only
# (config/packages.upstream.txt): no local PKGBUILD in pipa-pkgs, sourced
# from pipa-alarm's published repo instead. Installed best-effort, since
# pipa-alarm's GitHub Pages host has been intermittently unavailable.
PIPA_ALARM_EXTRA_PACKAGES=(
    box64
    gamescope
    mangohud-git
    mkbootimg-pipa
    widevine
    wine-aarch64
)

cleanup() {
    if mountpoint -q "$ROOTFS_DIR/boot" 2>/dev/null; then
        umount "$ROOTFS_DIR/boot"
    fi
    if mountpoint -q "$IMAGE_MNT" 2>/dev/null; then
        umount "$IMAGE_MNT"
    fi
    if mountpoint -q "$ESP_MNT" 2>/dev/null; then
        umount "$ESP_MNT"
    fi
    if mountpoint -q "$BOOT_MNT" 2>/dev/null; then
        umount "$BOOT_MNT"
    fi
    rm -f "$PACMAN_CONF"
}
trap cleanup EXIT

mkdir -p "$IMAGE_DIR/$IMAGE_NAME" "$IMAGE_MNT" "$ESP_MNT" "$BOOT_MNT"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

first_existing_file() {
    local candidate
    for candidate in "$@"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

qualify() {
    local repo="$1"; shift
    local pkg
    for pkg in "$@"; do
        printf '%s/%s\n' "$repo" "$pkg"
    done
}

assert_required_rootfs_files() {
    local file_path
    for file_path in "$@"; do
        if [ ! -f "$ROOTFS_DIR/$file_path" ]; then
            echo "Missing required file in target rootfs: /$file_path" >&2
            exit 1
        fi
    done
}

assert_required_rootfs_libssc() {
    if ! first_existing_file \
        "$ROOTFS_DIR/usr/lib/libssc.so.0" \
        "$ROOTFS_DIR/usr/lib/libssc.so.2" \
        >/dev/null; then
        echo "Missing libssc shared library in target rootfs (expected libssc.so.0 or libssc.so.2)" >&2
        exit 1
    fi
}

write_placeholder_initramfs() {
    local initramfs_path="$1"
    python - "$initramfs_path" <<'PY'
import gzip
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_bytes(gzip.compress(b"pipa placeholder initramfs\n"))
PY
}

write_uefi_csv() {
    local csv_path="$1"
    local entry_image="$2"
    local title="$3"
    local description="$4"
    python - "$csv_path" "$entry_image" "$title" "$description" <<'PY'
import pathlib
import sys

csv_path, entry_image, title, description = sys.argv[1:5]
text = f"{entry_image},{title},,{description}\r\n"
pathlib.Path(csv_path).write_bytes(b"\xff\xfe" + text.encode("utf-16le"))
PY
}

if [ ! -f "$EFI_TEMPLATE_DIR/EFI/BOOT/BOOTAA64.EFI" ] || [ ! -f "$EFI_TEMPLATE_DIR/EFI/archlinux/grubaa64.efi" ]; then
    echo "Missing EFI template files in $EFI_TEMPLATE_DIR" >&2
    echo "(shimaa64.efi/grubaa64.efi are signed binaries reused from an existing" >&2
    echo "working Pipa UEFI chain -- see README.md for where to source them.)" >&2
    exit 1
fi

if [ ! -f "$VBMETA_IMG" ]; then
    echo "Missing vbmeta image: $VBMETA_IMG" >&2
    exit 1
fi

echo "### Preparing pacman configuration..."
cp /etc/pacman.conf "$PACMAN_CONF"
sed -i '/^DisableSandbox$/d' "$PACMAN_CONF"
sed -i '/^\[options\]$/a DisableSandbox' "$PACMAN_CONF"
# This same conf is copied verbatim to $ROOTFS_DIR/etc/pacman.conf below, so
# setting ParallelDownloads here covers both the pacstrap step and the
# resulting image's own pacman.conf ("everywhere pacman runs").
sed -i '/^ParallelDownloads/d' "$PACMAN_CONF"
sed -i '/^\[options\]$/a ParallelDownloads = 50' "$PACMAN_CONF"
cat <<EOF >> "$PACMAN_CONF"

[$PIPA_PKGS_REPO_NAME]
SigLevel = Optional TrustAll
Server = $PIPA_PKGS_REPO_URL

[$PIPA_ALARM_REPO_NAME]
SigLevel = Optional TrustAll
Server = $PIPA_ALARM_REPO_URL
EOF

# Vanilla Arch Linux ARM base -- no third-party distro branding/keyring/
# mirrorlist packages. archlinuxarm-keyring + the image's default
# /etc/pacman.d/mirrorlist (already baked into the base-devel image) are
# all that's needed for [core]/[extra].
BASE_PACKAGES=(
    base base-devel sudo nano vim git wget rsync openssh
    networkmanager iwd mesa
    linux-firmware
    archlinuxarm-keyring
    alsa-ucm-conf alsa-utils
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
    upower modemmanager xdg-user-dirs
    iptables noto-fonts
    dracut
    fish fastfetch
    grub
    tuned tuned-ppd
)

mapfile -t QUALIFIED_PIPA_META_PACKAGES < <(qualify "$PIPA_PKGS_REPO_NAME" "${PIPA_META_PACKAGES[@]}")
mapfile -t QUALIFIED_PIPA_CORE_PACKAGES < <(qualify "$PIPA_PKGS_REPO_NAME" "${PIPA_CORE_PACKAGES[@]}")

case "$DE_NAME" in
    plasma)
        DESKTOP_PACKAGES=(
            plasma-meta plasma-workspace sddm sddm-kcm qt6-virtualkeyboard plasma-keyboard
            xdg-desktop-portal-kde firefox flatpak
            kdeconnect discover konsole dolphin ark filelight
            gwenview okular spectacle elisa kate kcalc
            plasma-browser-integration plasma-systemmonitor
            qt6-multimedia-ffmpeg
        )
        DISPLAY_MANAGER="sddm"
        ;;
    gnome)
        DESKTOP_PACKAGES=(
            gnome-shell gnome-session gnome-control-center gnome-console
            nautilus eog evince file-roller gnome-text-editor gnome-tweaks
            gdm xdg-desktop-portal-gnome
            firefox flatpak
        )
        DISPLAY_MANAGER="gdm"
        ;;
    base)
        DESKTOP_PACKAGES=()
        DISPLAY_MANAGER=""
        ;;
    *)
        echo "Unsupported image type: $DE_NAME (expected plasma, gnome, or base)" >&2
        exit 1
        ;;
esac

echo "### Seeding kernel cmdline for package hooks..."
install -d "$ROOTFS_DIR/etc" "$ROOTFS_DIR/boot"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$ROOTFS_DIR/etc/cmdline"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$ROOTFS_DIR/boot/cmdline.txt"
write_placeholder_initramfs "$ROOTFS_DIR/boot/initramfs.img"

echo "### Bootstrapping rootfs with pacstrap..."
pacstrap -C "$PACMAN_CONF" -KGM "$ROOTFS_DIR" \
    "${BASE_PACKAGES[@]}" \
    "${QUALIFIED_PIPA_META_PACKAGES[@]}" \
    "${QUALIFIED_PIPA_CORE_PACKAGES[@]}" \
    "${DESKTOP_PACKAGES[@]}"

if [ "$PIPA_INCLUDE_EXTRAS" = "1" ]; then
    echo "### Installing optional pipa-alarm extras when available..."
    OPTIONAL_INSTALL=()
    for pkg in "${PIPA_ALARM_EXTRA_PACKAGES[@]}"; do
        # pacstrap already synced every repo in $PACMAN_CONF -- including
        # pipa-alarm -- into $ROOTFS_DIR's own dbpath above. Without
        # -r "$ROOTFS_DIR" here, this queries the *host's* dbpath instead,
        # which has no pipa-alarm.db at all (that repo only exists in this
        # ad-hoc conf, not the base image's own /etc/pacman.conf), so every
        # package here would be reported "not found" and skipped
        # unconditionally, regardless of what pipa-alarm actually publishes.
        if pacman -C "$PACMAN_CONF" -r "$ROOTFS_DIR" -Si "${PIPA_ALARM_REPO_NAME}/${pkg}" >/dev/null 2>&1; then
            OPTIONAL_INSTALL+=("${PIPA_ALARM_REPO_NAME}/${pkg}")
        else
            echo "Skipping optional package (not currently in pipa-alarm repo): $pkg"
        fi
    done
    if [ "${#OPTIONAL_INSTALL[@]}" -gt 0 ]; then
        pacman -C "$PACMAN_CONF" -Sy --noconfirm --needed -r "$ROOTFS_DIR" "${OPTIONAL_INSTALL[@]}"
    fi
fi

echo "### Writing target pacman configuration..."
cp "$PACMAN_CONF" "$ROOTFS_DIR/etc/pacman.conf"

echo "### Validating repo-provided Pipa audio configuration..."
assert_required_rootfs_files \
    "usr/local/bin/pipa-refresh-grub-config" \
    "usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi Pad 6.conf" \
    "usr/share/alsa/ucm2/conf.d/sm8250/sm8250.conf" \
    "usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi-Pad6-pipa-M82.conf" \
    "usr/share/alsa/ucm2/Qualcomm/sm8250/HiFi_pipa.conf" \
    "usr/share/wireplumber/wireplumber.conf.d/51-pipa.conf" \
    "usr/local/bin/pipa-audio-init" \
    "usr/lib/systemd/system/pipa-audio-init.service"

if [ "$PIPA_INCLUDE_SENSORS" = "1" ]; then
    echo "### Validating repo-provided Pipa sensor configuration..."
    assert_required_rootfs_libssc
    assert_required_rootfs_files \
        "usr/lib/udev/rules.d/81-libssc-xiaomi-pipa.rules" \
        "usr/local/bin/pipa-prepare-sensor-persist" \
        "usr/share/hexagonrpcd/hexagonrpcd-sdsp.conf" \
        "usr/share/hexagonrpcd/hexagonrpcd-adsp-sensorspd.conf" \
        "usr/lib/systemd/system/pipa-sensors-persist.service" \
        "usr/lib/systemd/system-sleep/pipa-sensors-resume" \
        "usr/lib/systemd/system/iio-sensor-proxy.service.d/10-pipa-audio.conf" \
        "usr/lib/systemd/system/pipa-audio-init.service.d/10-sensors.conf"
fi

echo "### Creating default user account (zero-touch, no first-boot wizard)..."
if arch-chroot "$ROOTFS_DIR" id "$PIPA_DEFAULT_USER" >/dev/null 2>&1; then
    echo "User '$PIPA_DEFAULT_USER' already exists in rootfs, skipping useradd."
else
    arch-chroot "$ROOTFS_DIR" useradd -m -G wheel,video,audio,input,storage -s /usr/bin/fish "$PIPA_DEFAULT_USER"
fi
printf 'root:%s\n%s:%s\n' "$PIPA_DEFAULT_PASSWORD" "$PIPA_DEFAULT_USER" "$PIPA_DEFAULT_PASSWORD" \
    | arch-chroot "$ROOTFS_DIR" chpasswd

printf '%s\n' "$PIPA_DEFAULT_HOSTNAME" > "$ROOTFS_DIR/etc/hostname"
cat > "$ROOTFS_DIR/etc/hosts" <<EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 $PIPA_DEFAULT_HOSTNAME.localdomain $PIPA_DEFAULT_HOSTNAME
EOF

if [ "$DE_NAME" = "plasma" ]; then
    SESSION_FILE="$(first_existing_file \
        "$ROOTFS_DIR/usr/share/wayland-sessions/plasma.desktop" \
        "$ROOTFS_DIR/usr/share/xsessions/plasma.desktop" \
    )"
    SESSION_NAME="$(basename "$SESSION_FILE")"

    echo "### Configuring sddm autologin straight into Plasma..."
    install -Dm644 /dev/stdin "$ROOTFS_DIR/etc/sddm.conf.d/10-autologin.conf" <<EOF
[Autologin]
User=$PIPA_DEFAULT_USER
Session=$SESSION_NAME
Relogin=false
EOF
elif [ "$DE_NAME" = "gnome" ]; then
    SESSION_FILE="$(first_existing_file \
        "$ROOTFS_DIR/usr/share/wayland-sessions/gnome.desktop" \
        "$ROOTFS_DIR/usr/share/xsessions/gnome.desktop" \
        "$ROOTFS_DIR/usr/share/xsessions/gnome-xorg.desktop" \
    )"
    SESSION_NAME="$(basename "$SESSION_FILE" .desktop)"

    echo "### Configuring gdm autologin straight into GNOME..."
    install -Dm644 /dev/stdin "$ROOTFS_DIR/etc/gdm/custom.conf.d/10-autologin.conf" <<EOF
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=$PIPA_DEFAULT_USER
DefaultSession=$SESSION_NAME
EOF
else
    echo "### Configuring tty autologin (base/console image)..."
    install -d "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d"
    install -Dm644 /dev/stdin "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $PIPA_DEFAULT_USER --noclear %I \$TERM
EOF
fi

# /etc/fstab (written further below, once labels are finalized) mounts /
# and /boot by filesystem LABEL, so both are auto-mounted at boot with no
# manual step -- nothing further needed here.

echo "### Validating critical firmware payloads..."
assert_required_rootfs_files \
    "usr/lib/firmware/qcom/a650_sqe.fw" \
    "usr/lib/firmware/qcom/a650_gmu.bin" \
    "usr/lib/firmware/qca/htbtfw20.tlv" \
    "usr/lib/firmware/ath11k/QCA6390/hw2.0/amss.bin" \
    "usr/lib/firmware/ath11k/QCA6390/hw2.0/board-2.bin" \
    "usr/lib/firmware/ath11k/QCA6390/hw2.0/m3.bin"

KERNEL_VER=$(find "$ROOTFS_DIR/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n 1)
KERNEL_IMAGE="$(first_existing_file \
    "$ROOTFS_DIR/boot/Image.gz" \
    "$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VER" \
)"
KERNEL_IMAGE_UNCOMPRESSED="$(first_existing_file \
    "$ROOTFS_DIR/boot/Image" \
    "$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VER.uncompressed" \
    || true \
)"
INITRAMFS_IMAGE="$(first_existing_file \
    "$ROOTFS_DIR/boot/initramfs-$KERNEL_VER.img" \
    "$ROOTFS_DIR/boot/initramfs.img" \
)"
DTB_IMAGE="$(first_existing_file \
    "$ROOTFS_DIR/boot/dtbs/qcom/sm8250-xiaomi-pipa.dtb" \
    "$ROOTFS_DIR/usr/lib/modules/$KERNEL_VER/devicetree/sm8250-xiaomi-pipa.dtb" \
)"

if [ -z "${KERNEL_IMAGE:-}" ] || [ ! -f "$KERNEL_IMAGE" ]; then
    echo "Kernel image was not found in the target rootfs for $KERNEL_VER" >&2
    exit 1
fi
if [ -z "${DTB_IMAGE:-}" ] || [ ! -f "$DTB_IMAGE" ]; then
    echo "Device tree was not found in the target rootfs for $KERNEL_VER" >&2
    exit 1
fi

echo "### Preparing locale/console configuration..."
echo 'LANG=C.UTF-8' > "$ROOTFS_DIR/etc/locale.conf"
echo 'KEYMAP=us' > "$ROOTFS_DIR/etc/vconsole.conf"

echo "### Generating initramfs..."
if ! arch-chroot "$ROOTFS_DIR" sh -c 'command -v dracut >/dev/null'; then
    echo "dracut is required in the target rootfs but was not found" >&2
    exit 1
fi
assert_required_rootfs_files "usr/lib/dracut/dracut.conf.d/10-pipa.conf"
arch-chroot "$ROOTFS_DIR" dracut --force --kver "$KERNEL_VER" "/boot/initramfs-$KERNEL_VER.img"

INITRAMFS_IMAGE="$(first_existing_file \
    "$ROOTFS_DIR/boot/initramfs-$KERNEL_VER.img" \
    "$ROOTFS_DIR/boot/initramfs.img" \
)"
if [ ! -f "$INITRAMFS_IMAGE" ]; then
    echo "Initramfs image was not generated for $KERNEL_VER" >&2
    exit 1
fi
if [ "$(stat -c '%s' "$INITRAMFS_IMAGE")" -lt 1048576 ]; then
    echo "Initramfs image for $KERNEL_VER is unexpectedly small: $INITRAMFS_IMAGE" >&2
    exit 1
fi
if [ "$INITRAMFS_IMAGE" != "$ROOTFS_DIR/boot/initramfs.img" ]; then
    cp "$INITRAMFS_IMAGE" "$ROOTFS_DIR/boot/initramfs.img"
fi
if [ "$(stat -c '%s' "$ROOTFS_DIR/boot/initramfs.img")" -lt 1048576 ]; then
    echo "Canonical /boot/initramfs.img is unexpectedly small after copy" >&2
    exit 1
fi

echo "### Setting up /etc/cmdline..."
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$ROOTFS_DIR/etc/cmdline"

echo "### Setting up /etc/fstab..."
cat > "$ROOTFS_DIR/etc/fstab" <<EOF
LABEL=$ROOTFS_LABEL / ext4 defaults,x-systemd.growfs 0 1
LABEL=$BOOT_LABEL /boot ext4 defaults 0 2
EOF

# --- Automatic service enablement, done entirely while chrooted ------------
echo "### Enabling system services (chroot)..."
if [ -n "$DISPLAY_MANAGER" ]; then
    arch-chroot "$ROOTFS_DIR" systemctl enable "$DISPLAY_MANAGER"
fi
arch-chroot "$ROOTFS_DIR" systemctl enable NetworkManager sshd bluetooth systemd-resolved systemd-timesyncd
arch-chroot "$ROOTFS_DIR" systemctl enable tuned tuned-ppd || true
arch-chroot "$ROOTFS_DIR" systemctl enable bootmac-bluetooth || true
arch-chroot "$ROOTFS_DIR" systemctl enable pd-mapper rmtfs tqftpserv || true
if [ "$PIPA_INCLUDE_SENSORS" = "1" ]; then
    arch-chroot "$ROOTFS_DIR" systemctl enable \
        pipa-sensors-persist \
        hexagonrpcd-sdsp \
        hexagonrpcd-adsp-sensorspd \
        iio-sensor-proxy \
        pipa-audio-init || true
else
    arch-chroot "$ROOTFS_DIR" systemctl enable pipa-audio-init || true
fi
arch-chroot "$ROOTFS_DIR" systemctl mask hexagonrpcd-adsp-rootpd.service || true

echo "### Configuring virtual keyboard defaults (Plasma)..."
if [ "$DE_NAME" = "plasma" ]; then
    install -d "$ROOTFS_DIR/etc/environment.d"
    cat > "$ROOTFS_DIR/etc/environment.d/90-plasma-keyboard.conf" <<EOF
KWIN_IM_SHOW_ALWAYS=1
PLASMA_KEYBOARD_USE_QT_LAYOUTS=1
EOF
    arch-chroot "$ROOTFS_DIR" env PIPA_DEFAULT_USER="$PIPA_DEFAULT_USER" sh -eu <<'EOF'
desktop_file=""
for candidate in \
    /usr/share/applications/org.kde.plasma.keyboard.desktop \
    /usr/share/applications/org.kde.plasma-keyboard.desktop \
    /usr/share/applications/plasma-keyboard.desktop
do
    if [ -f "$candidate" ]; then
        desktop_file="$candidate"
        break
    fi
done
if [ -z "$desktop_file" ]; then
    desktop_file="$(grep -rl '^X-KDE-Wayland-VirtualKeyboard=true' /usr/share/applications 2>/dev/null | grep 'plasma' | head -n 1 || true)"
fi
for config_root in /root /etc/skel "/home/$PIPA_DEFAULT_USER"; do
    install -d "$config_root/.config"
    cat > "$config_root/.config/kwinrc" <<CONFIG
[Wayland]
InputMethod=$desktop_file
CONFIG
done
chown -R "$PIPA_DEFAULT_USER:$PIPA_DEFAULT_USER" "/home/$PIPA_DEFAULT_USER/.config"
EOF
fi

echo "### Configuring fish shell defaults..."
for config_root in /root /etc/skel; do
    install -d "$ROOTFS_DIR$config_root/.config/fish"
    cat > "$ROOTFS_DIR$config_root/.config/fish/config.fish" <<'EOF'
if status is-interactive
    if test "$SHLVL" = 1
        if command -q fastfetch
            fastfetch
        end
    end
end
EOF
done
install -d "$ROOTFS_DIR/home/$PIPA_DEFAULT_USER/.config/fish"
cp "$ROOTFS_DIR/etc/skel/.config/fish/config.fish" "$ROOTFS_DIR/home/$PIPA_DEFAULT_USER/.config/fish/config.fish"
arch-chroot "$ROOTFS_DIR" chown -R "$PIPA_DEFAULT_USER:$PIPA_DEFAULT_USER" "/home/$PIPA_DEFAULT_USER/.config"
arch-chroot "$ROOTFS_DIR" usermod -s /usr/bin/fish root
arch-chroot "$ROOTFS_DIR" usermod -s /usr/bin/fish "$PIPA_DEFAULT_USER"
arch-chroot "$ROOTFS_DIR" useradd -D -s /usr/bin/fish

echo "### Configuring sudo..."
echo "%wheel ALL=(ALL:ALL) ALL" > "$ROOTFS_DIR/etc/sudoers.d/wheel"
chmod 0440 "$ROOTFS_DIR/etc/sudoers.d/wheel"

echo "### Fetching Mu-Silicium boot image..."
wget -O "$IMAGE_DIR/$IMAGE_NAME/silicium.img" "$SILICIUM_URL"
echo "$SILICIUM_SHA256  $IMAGE_DIR/$IMAGE_NAME/silicium.img" | sha256sum -c -

echo "### Installing GRUB redirect on rootfs..."
install -d "$ROOTFS_DIR/boot/efi" "$ROOTFS_DIR/boot/grub"
cat > "$ROOTFS_DIR/boot/grub/grub.cfg" <<EOF
search --no-floppy --label --set=boot $BOOT_LABEL
set prefix=(\$boot)/grub2
configfile (\$boot)/grub2/grub.cfg
EOF

echo "### Creating dedicated boot image..."
truncate -s "${BOOT_SIZE_MB}M" "$IMAGE_DIR/$IMAGE_NAME/archlinux_boot.raw"
mkfs.ext4 -F -L "$BOOT_LABEL" -O ^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file "$IMAGE_DIR/$IMAGE_NAME/archlinux_boot.raw"
mount -o loop "$IMAGE_DIR/$IMAGE_NAME/archlinux_boot.raw" "$BOOT_MNT"
cp "$KERNEL_IMAGE" "$BOOT_MNT/Image.gz"
if [ -n "${KERNEL_IMAGE_UNCOMPRESSED:-}" ] && [ -f "$KERNEL_IMAGE_UNCOMPRESSED" ]; then
    cp "$KERNEL_IMAGE_UNCOMPRESSED" "$BOOT_MNT/Image"
fi
cp "$INITRAMFS_IMAGE" "$BOOT_MNT/initramfs-$KERNEL_VER.img"
install -d "$BOOT_MNT/dtbs/qcom" "$BOOT_MNT/grub2" "$BOOT_MNT/efi"
if [ -f "$ROOTFS_DIR/boot/System.map-$KERNEL_VER" ]; then
    cp "$ROOTFS_DIR/boot/System.map-$KERNEL_VER" "$BOOT_MNT/"
fi
if [ -f "$ROOTFS_DIR/boot/config-$KERNEL_VER" ]; then
    cp "$ROOTFS_DIR/boot/config-$KERNEL_VER" "$BOOT_MNT/"
fi
shopt -s nullglob
dtb_candidates=("$ROOTFS_DIR"/boot/dtbs/qcom/sm8250-xiaomi-pipa*.dtb)
shopt -u nullglob
if [ "${#dtb_candidates[@]}" -gt 0 ]; then
    cp "${dtb_candidates[@]}" "$BOOT_MNT/dtbs/qcom/"
else
    cp "$DTB_IMAGE" "$BOOT_MNT/dtbs/qcom/"
fi
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$BOOT_MNT/cmdline.txt"
mount --move "$BOOT_MNT" "$ROOTFS_DIR/boot"
arch-chroot "$ROOTFS_DIR" env \
    PIPA_INITRAMFS_SOURCE="/boot/initramfs-$KERNEL_VER.img" \
    /usr/local/bin/pipa-refresh-grub-config
if [ ! -f "$ROOTFS_DIR/boot/grub2/grub.cfg" ]; then
    echo "pipa-grub-config did not generate /boot/grub2/grub.cfg" >&2
    exit 1
fi
umount "$ROOTFS_DIR/boot"

echo "### Creating EFI system partition image..."
truncate -s "${ESP_SIZE_MB}M" "$IMAGE_DIR/$IMAGE_NAME/archlinux_esp.raw"
mkfs.fat -F 16 -n "$ESP_LABEL" "$IMAGE_DIR/$IMAGE_NAME/archlinux_esp.raw"
mount -o loop "$IMAGE_DIR/$IMAGE_NAME/archlinux_esp.raw" "$ESP_MNT"
# FAT cannot store Unix ownership, so avoid archive mode here.
cp -r "$EFI_TEMPLATE_DIR/EFI" "$ESP_MNT/"
# The fedora-signed shim is reused as a generic fallback boot entry, since
# it's one of the few third-party UEFI-CA-signed shims and is what the
# existing pocketblue/Mu-Silicium boot chain on this device recognizes.
mkdir -p "$ESP_MNT/EFI/fedora"
cp -r "$ESP_MNT/EFI/archlinux/." "$ESP_MNT/EFI/fedora/"
for shim_vendor in archlinux fedora; do
cat > "$ESP_MNT/EFI/$shim_vendor/grub.cfg" <<EOF
if [ -e (md/md-boot) ]; then
  set prefix=md/md-boot
else
  if [ -f \${config_directory}/bootuuid.cfg ]; then
    source \${config_directory}/bootuuid.cfg
  fi
  if [ -n "\${BOOT_UUID}" ]; then
    search --fs-uuid "\${BOOT_UUID}" --set prefix --no-floppy
  else
    search --label $BOOT_LABEL --set prefix --no-floppy
  fi
fi
if [ -d (\$prefix)/grub2 ]; then
  set prefix=(\$prefix)/grub2
  configfile \$prefix/grub.cfg
else
  set prefix=(\$prefix)/boot/grub2
  configfile \$prefix/grub.cfg
fi
boot
EOF
cat > "$ESP_MNT/EFI/$shim_vendor/bootuuid.cfg" <<EOF
set BOOT_UUID=""
EOF
done
write_uefi_csv \
    "$ESP_MNT/EFI/fedora/BOOTAA64.CSV" \
    "shimaa64.efi" \
    "Fedora" \
    "This is the boot entry for Fedora"
write_uefi_csv \
    "$ESP_MNT/EFI/archlinux/BOOTAA64.CSV" \
    "shimaa64.efi" \
    "Arch Linux" \
    "This is the boot entry for Arch Linux"
umount "$ESP_MNT"

echo "### Creating root filesystem image..."
SIZE=$(du -sBM "$ROOTFS_DIR" | awk '{print $1}' | tr -d 'M')
SIZE=$((SIZE + (SIZE / 8) + 512))
truncate -s "${SIZE}M" "$IMAGE_DIR/$IMAGE_NAME/archlinux_rootfs.raw"
MKE2FS_DEVICE_PHYS_SECTSIZE=4096 MKE2FS_DEVICE_SECTSIZE=4096 \
    mkfs.ext4 -L "$ROOTFS_LABEL" "$IMAGE_DIR/$IMAGE_NAME/archlinux_rootfs.raw"
mount -o loop "$IMAGE_DIR/$IMAGE_NAME/archlinux_rootfs.raw" "$IMAGE_MNT"
rsync -aHAX --exclude '/tmp/*' --exclude '/boot/efi' --exclude '/efi' "$ROOTFS_DIR/" "$IMAGE_MNT/"
umount "$IMAGE_MNT"

echo "### Copying vbmeta image..."
cp "$VBMETA_IMG" "$IMAGE_DIR/$IMAGE_NAME/vbmeta.img"

echo "### Writing fastboot helper script..."
cat > "$IMAGE_DIR/$IMAGE_NAME/flash.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

announce() { printf '### %s\n' "$1"; }

announce "Xiaomi Pad 6 single-boot flasher"
announce "This mode flashes the Arch Linux rootfs to userdata."
announce "Android userdata will be overwritten."
echo

ERASE_DTBO="${ERASE_DTBO:-}"
FLASH_VBMETA="${FLASH_VBMETA:-}"

choose_yes_no() {
    local prompt="$1" default_answer="$2" answer
    while true; do
        read -r -p "$prompt [$default_answer]: " answer
        [ -z "$answer" ] && answer="$default_answer"
        case "$answer" in
            y|Y|yes|YES) printf 'yes\n'; return 0 ;;
            n|N|no|NO) printf 'no\n'; return 0 ;;
        esac
        echo "Please answer yes or no."
    done
}

announce "Verifying connected device"
fastboot getvar product 2>&1 | grep pipa

[ -z "$ERASE_DTBO" ] && ERASE_DTBO="$(choose_yes_no 'Erase dtbo_ab before flashing?' 'no')"
[ -z "$FLASH_VBMETA" ] && FLASH_VBMETA="$(choose_yes_no 'Flash vbmeta.img to vbmeta_ab?' 'no')"

announce "Flash plan"
echo "Erase dtbo_ab         -> $ERASE_DTBO"
echo "Flash vbmeta_ab       -> $FLASH_VBMETA"
echo "Mu-Silicium boot      -> boot_ab"
echo "Arch Linux EFI image  -> rawdump"
echo "Arch Linux boot       -> cust"
echo "Arch Linux rootfs     -> userdata"
echo

read -r -p "Proceed with flashing? [Y/n]: " CONFIRM_FLASH
case "${CONFIRM_FLASH:-Y}" in
    y|Y|yes|YES|"") ;;
    *) echo "Aborted."; exit 0 ;;
esac

[ "$ERASE_DTBO" = "yes" ] && { announce "Erasing dtbo_ab"; fastboot erase dtbo_ab; }
[ "$FLASH_VBMETA" = "yes" ] && { announce "Flashing vbmeta_ab"; fastboot flash vbmeta_ab vbmeta.img; }

announce "Flashing Mu-Silicium boot image to boot_ab"
fastboot flash boot_ab silicium.img

announce "Flashing Arch Linux EFI image to rawdump"
fastboot flash rawdump archlinux_esp.raw

announce "Flashing Arch Linux boot image to cust"
fastboot flash cust archlinux_boot.raw

announce "Flashing Arch Linux rootfs image to userdata"
fastboot flash userdata archlinux_rootfs.raw

announce "Rebooting device"
fastboot reboot
EOF
chmod +x "$IMAGE_DIR/$IMAGE_NAME/flash.sh"

echo "### Writing multiboot flash helper script..."
cat > "$IMAGE_DIR/$IMAGE_NAME/flash-multiboot.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

announce() { printf '### %s\n' "$1"; }

choose_from_menu() {
    local prompt="$1" default_index="$2"
    shift 2
    local options=("$@") answer index
    echo "$prompt" >&2
    for index in "${!options[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "${options[$index]}" >&2
    done
    while true; do
        read -r -p "Select an option [$default_index]: " answer
        [ -z "$answer" ] && answer="$default_index"
        if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#options[@]}" ]; then
            printf '%s\n' "${options[$((answer - 1))]}"
            return 0
        fi
        echo "Invalid selection: $answer" >&2
    done
}

prompt_with_default() {
    local prompt="$1" default_value="$2" value
    read -r -p "$prompt [$default_value]: " value
    [ -z "$value" ] && value="$default_value"
    printf '%s\n' "$value"
}

announce "Xiaomi Pad 6 multiboot flasher"
announce "This mode flashes Arch Linux rootfs to a dedicated partition such as linux."
announce "It does not use userdata unless you explicitly choose that partition."
echo

BOOT_SLOT_TARGET="${BOOT_SLOT_TARGET:-}"
ROOTFS_PARTITION="${ROOTFS_PARTITION:-}"
ERASE_DTBO="${ERASE_DTBO:-}"
FLASH_VBMETA="${FLASH_VBMETA:-}"
ESP_PARTITION="rawdump"
BOOT_PARTITION="cust"

[ -z "$BOOT_SLOT_TARGET" ] && BOOT_SLOT_TARGET="$(choose_from_menu 'Choose the boot slot target:' 3 'boot_a' 'boot_b' 'boot_ab')"
[ -z "$ROOTFS_PARTITION" ] && ROOTFS_PARTITION="$(prompt_with_default 'Dedicated root filesystem partition name' 'linux')"
[ -z "$ERASE_DTBO" ] && ERASE_DTBO="$(choose_from_menu 'Erase dtbo_ab before flashing?' 1 'no' 'yes')"
[ -z "$FLASH_VBMETA" ] && FLASH_VBMETA="$(choose_from_menu 'Flash vbmeta.img to vbmeta_ab?' 1 'no' 'yes')"

if [[ ! "$ROOTFS_PARTITION" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid root filesystem partition name: $ROOTFS_PARTITION" >&2
    exit 1
fi

announce "Verifying connected device"
fastboot getvar product 2>&1 | grep pipa

[ "$ERASE_DTBO" = "yes" ] && { announce "Erasing dtbo_ab"; fastboot erase dtbo_ab; }

announce "Flash plan"
echo "Flash vbmeta_ab       -> $FLASH_VBMETA"
echo "Arch Linux EFI image  -> $ESP_PARTITION"
echo "Arch Linux boot       -> $BOOT_PARTITION"
echo "Arch Linux rootfs     -> $ROOTFS_PARTITION"
echo "Erase dtbo_ab         -> $ERASE_DTBO"
echo

read -r -p "Proceed with flashing? [Y/n]: " CONFIRM_FLASH
case "${CONFIRM_FLASH:-Y}" in
    y|Y|yes|YES|"") ;;
    *) echo "Aborted."; exit 0 ;;
esac

[ "$FLASH_VBMETA" = "yes" ] && { announce "Flashing vbmeta_ab"; fastboot flash vbmeta_ab vbmeta.img; }

announce "Flashing Mu-Silicium boot image to $BOOT_SLOT_TARGET"
fastboot flash "$BOOT_SLOT_TARGET" silicium.img

announce "Flashing Arch Linux EFI image to $ESP_PARTITION"
fastboot flash "$ESP_PARTITION" archlinux_esp.raw

announce "Flashing Arch Linux boot image to $BOOT_PARTITION"
fastboot flash "$BOOT_PARTITION" archlinux_boot.raw

announce "Flashing Arch Linux rootfs image to $ROOTFS_PARTITION"
fastboot flash "$ROOTFS_PARTITION" archlinux_rootfs.raw

announce "Rebooting device"
fastboot reboot
EOF
chmod +x "$IMAGE_DIR/$IMAGE_NAME/flash-multiboot.sh"

echo "### Writing build metadata..."
BUILD_GIT_REV="${BUILD_GIT_REV:-unknown}"
cat > "$IMAGE_DIR/$IMAGE_NAME/BUILDINFO.txt" <<EOF
Arch Linux Pipa Image Build
============================
Image type:      $DE_NAME
Build date:       $DATE
Git revision:     $BUILD_GIT_REV
Kernel:           $KERNEL_VER
pipa-pkgs repo:   $PIPA_PKGS_REPO_URL
pipa-alarm repo:  $PIPA_ALARM_REPO_URL
Sensors:          $PIPA_INCLUDE_SENSORS
Alarm extras:     $PIPA_INCLUDE_EXTRAS
Rootfs label:     $ROOTFS_LABEL
Boot label:       $BOOT_LABEL
ESP label:        $ESP_LABEL
Silicium URL:     $SILICIUM_URL
EOF

echo "### Generating checksums..."
(
    cd "$IMAGE_DIR/$IMAGE_NAME"
    sha256sum -- * | tee SHA256SUMS
)

echo "### Compressing image..."
pushd "$IMAGE_DIR/$IMAGE_NAME" > /dev/null
zip -r "../$IMAGE_NAME.zip" .
popd > /dev/null

echo "### Done! Image available at $IMAGE_DIR/$IMAGE_NAME.zip"
