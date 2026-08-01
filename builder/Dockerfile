FROM menci/archlinuxarm:base-devel

# Initialize keyring and install dependencies for image creation.
# Docker CI/most desktop Docker installs lack the kernel features pacman uses
# for sandboxing, so DisableSandbox must live inside [options] or pacman
# will silently ignore the option when set elsewhere.
RUN pacman-key --init && \
    pacman-key --populate archlinuxarm && \
    sed -i '/^CheckSpace$/s/^/#/' /etc/pacman.conf && \
    sed -i '/^DisableSandbox$/d' /etc/pacman.conf && \
    sed -i '/^\[options\]$/a DisableSandbox' /etc/pacman.conf && \
    sed -i '/^ParallelDownloads/d' /etc/pacman.conf && \
    sed -i '/^\[options\]$/a ParallelDownloads = 50' /etc/pacman.conf && \
    pacman -Sy --noconfirm archlinuxarm-keyring && \
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
RUN chmod +x *.sh

CMD []
ENTRYPOINT ["/bin/bash", "./build-image.sh"]
