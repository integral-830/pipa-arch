FROM menci/archlinuxarm:base-devel

# Initialize keyring and install dependencies for image creation.
# Docker CI/most desktop Docker installs lack the kernel features pacman uses
# for sandboxing, so DisableSandbox must live inside [options] or pacman
# will silently ignore the option when set elsewhere.
#
# Keyring bootstrap order matters: `pacman-key --populate archlinuxarm`
# needs archlinuxarm-keyring's .gpg file already on disk, but that package
# can only be installed *by* pacman, which normally won't install anything
# without a populated keyring to verify it against. Break the chicken-and-
# egg problem by temporarily setting SigLevel=Never just for the keyring
# install, then restore signature enforcement before installing anything
# else.
RUN pacman-key --init && \
    sed -i 's/^SigLevel.*/SigLevel = Never/' /etc/pacman.conf && \
    sed -i '/^CheckSpace$/s/^/#/' /etc/pacman.conf && \
    sed -i '/^DisableSandbox$/d' /etc/pacman.conf && \
    sed -i '/^\[options\]$/a DisableSandbox' /etc/pacman.conf && \
    sed -i '/^ParallelDownloads/d' /etc/pacman.conf && \
    sed -i '/^\[options\]$/a ParallelDownloads = 50' /etc/pacman.conf && \
    pacman -Sy --noconfirm archlinuxarm-keyring && \
    pacman-key --populate archlinuxarm && \
    sed -i 's/^SigLevel.*/SigLevel = Required DatabaseOptional/' /etc/pacman.conf && \
    pacman -Su --noconfirm && \
    pacman -S --noconfirm \
    git wget rsync \
    arch-install-scripts e2fsprogs dosfstools mtools zip unzip \
    bc bison flex cpio kmod python tar xz meson ninja cmake \
    glib2 libgudev polkit libqmi protobuf-c dracut android-tools grub

WORKDIR /build

# Copy the entire builder directory into the container
COPY . /build/

# Make scripts executable
RUN chmod +x ./*.sh

CMD []
ENTRYPOINT ["/bin/bash", "./build-image.sh"]
