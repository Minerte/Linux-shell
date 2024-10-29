#!/bin/bash

# Parameters for Gentoo stage file URL and version
STAGE_VERSION="20241020T170324Z"
STAGE_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE_VERSION}/stage3-amd64-hardened-openrc-${STAGE_VERSION}.tar.xz"
STAGE_ASC_URL="${STAGE_URL}.asc"
CRYPT_NAME="cryptroot"

# Ensure the script is run as root
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root!"
  exit 1
fi

# List available disks
function list_disks() {
    echo "Available disks:"
    lsblk -d -n -o NAME,SIZE | awk '{print "/dev/" $1 " - " $2}'
}

# Validate block device
function validate_block_device() {
    local device="$1"
    if [[ ! -b "$device" ]]; then
        echo "Error: $device is not a valid block device."
        exit 1
    fi
}

# Find UUID of a given partition
function find_uuid() {
    local partition="$1"
    validate_block_device "$partition"
    blkid -s UUID -o value "$partition" || { echo "Failed to get UUID."; exit 1; }
}

# Format and partition disk
function setup_partitions() {
    local sel_disk="$1"
    local boot_size="$2"

    read -r -p "You are about to format the selected disk: $sel_disk. Are you sure? (y/n) " confirm
    if [[ "$confirm" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi

    echo "Formatting disk $sel_disk and creating partitions..."
    parted --script "$sel_disk" mklabel gpt \
        mkpart primary fat32 0% "${boot_size}G" \
        mkpart primary btrfs "${boot_size}G" 100% \
        set 1 boot on || { echo "Partitioning failed."; exit 1; }

    mkfs.vfat -F 32 "${sel_disk}1" || { echo "Failed to format boot partition."; exit 1; }

    echo "Setting up disk encryption for root partition."
    cryptsetup luksFormat -s 512 -c aes-xts-plain64 "${sel_disk}2" || { echo "Encryption setup failed."; exit 1; }
    cryptsetup luksOpen "${sel_disk}2" $CRYPT_NAME || { echo "Failed to open encrypted partition."; exit 1; }

    mkfs.btrfs -L BTROOT /dev/mapper/$CRYPT_NAME || { echo "Failed to format encrypted root partition."; exit 1; }
    mount -t btrfs -o defaults,noatime,compress=lzo /dev/mapper/$CRYPT_NAME /mnt/root || { echo "Failed to mount root."; exit 1; }

    btrfs subvolume create /mnt/root/activeroot || exit
    btrfs subvolume create /mnt/root/home || exit

    mkdir -p /mnt/gentoo/efi /mnt/gentoo/home || exit
    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=activeroot /dev/mapper/$CRYPT_NAME /mnt/gentoo || exit
    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=home /dev/mapper/$CRYPT_NAME /mnt/gentoo/home || exit

    mount "${sel_disk}1" /mnt/gentoo/efi || { echo "Failed to mount EFI partition."; exit 1; }
    echo "Disk $sel_disk configured with boot (EFI), encrypted root, and home partitions."
}

# Download and verify Gentoo stage file
function download_and_verify_stagefile() {
    echo "Downloading and verifying Gentoo stage file..."
    wget -q "$STAGE_URL" -O stage3.tar.xz || { echo "Failed to download stage file."; exit 1; }
    wget -q "$STAGE_ASC_URL" -O stage3.tar.xz.asc || { echo "Failed to download signature file."; exit 1; }

    gpg --import /usr/share/openpgp-keys/gentoo-release.asc || { echo "Failed to import GPG keys."; exit 1; }
    gpg --verify stage3.tar.xz.asc || { echo "GPG verification failed."; exit 1; }

    tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo || { echo "Failed to extract stage file."; exit 1; }
    echo "Gentoo stage file setup complete."
    sleep 5
    echo "Will change basic config"
    sed -i "s/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g" ./etc/locale.gen
    sed -i "s/clock=\"UTC\"/clock=\"local\"/g" ./etc/conf.d/hwclock
    sed -i "s/keymap=\"us\"/keymaps=\"sv-latin1\"/g" ./etc/conf.d/keymaps

    echo 'LANG="en_US.UTF-8"' >> ./etc/locale.conf
    echo 'LC_COLLATE="C.UTF-8"' >> ./etc/locale.conf
    echo "Europe/Stockholm" > ./etc/timezone
    echo "Gentoo stage file setup and basic config complete."
}

# Configure system settings and fstab
function configure_system() {
    local sel_disk="$1"
    local efi_uuid
    efi_uuid=$(find_uuid "${sel_disk}1")
    local root_uuid
    # shellcheck disable=SC2034
    root_uuid=$(find_uuid "${sel_disk}2")

    echo "Configuring system files and fstab..."
    # shellcheck disable=SC2129
    echo "LABEL=BTROOT  /       btrfs   defaults,noatime,compress=lzo,subvol=activeroot 0 0" >> /mnt/gentoo/etc/fstab
    echo "LABEL=BTROOT  /home   btrfs   defaults,noatime,compress=lzo,subvol=home       0 0" >> /mnt/gentoo/etc/fstab
    echo "UUID=$efi_uuid    /efi    vfat    umask=077   0 2" >> /mnt/gentoo/etc/fstab
}

# Set up Portage and copy configuration
function configure_portage() {
    echo "Setting up Portage..."
    mkdir -p /mnt/gentoo/etc/portage/repos.conf
    cp /usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
    cp /etc/resolv.conf /mnt/gentoo/etc/

    # Copy custom portage configuration files
    mkdir /mnt/gentoo/etc/portage/env
    cp cp ~/root/Linux-bash-shell/Gentoo/portage/env/no-lto /mnt/gentoo/etc/portage/env/
    cp ~/root/Linux-bash-shell/Gentoo/portage/make.conf /mnt/gentoo/etc/portage/
    cp ~/root/Linux-bash-shell/Gentoo/portage/package.env /mnt/gentoo/etc/portage/
    # Copy custom portage for package.use
    cp ~/root/Linux-bash-shell/Gentoo/portage/Kernel /mnt/gentoo/etc/portage/package.use/
    cp ~/root/Linux-bash-shell/Gentoo/portage/Lua /mnt/gentoo/etc/portage/package.use/
    cp ~/root/Linux-bash-shell/Gentoo/portage/Network /mnt/gentoo/etc/portage/package.use/
    cp ~/root/Linux-bash-shell/Gentoo/portage/Rust /mnt/gentoo/etc/portage/package.use/
    cp ~/root/Linux-bash-shell/Gentoo/portage/app-alternatives /mnt/gentoo/etc/portage/package.use/
    cp ~/root/Linux-bash-shell/Gentoo/portage/system-core /mnt/gentoo/etc/portage/package.use/
    # Copy custom portage for package.accept_keywords
    cp ~/root/Linux-bash-shell/Gentoo/portage/tui /mnt/gentoo/etc/portage/package.accept_keywords/
    echo "Portage configuration complete."
}

# Set up chroot environment
function setup_chroot() {
    echo "Setting up chroot environment..."
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-slave /mnt/gentoo/run

    chroot /mnt/gentoo /bin/bash
    # shellcheck disable=SC1091
    source /etc/profile
    export PS1="(chroot) ${PS1}"

    emerge-webrsync
    emerge --sync --quiet
    emerge --config sys-libs/timezone-data

    locale-gen
    # shellcheck disable=SC1091
    env-update && source /etc/profile && export PS1="(chroot) ${PS1}"
}

# Configure and install kernel
function configure_kernel() {
    echo "Configuring and installing kernel..."
    eselect kernel set 1
    genkernel --luks --btrfs --keymap --oldconfig --save-config --menuconfig --install all
}

# Install and configure GRUB
function configure_grub() {
    echo "Installing and configuring GRUB..."
    grub-install --target=x86_64-efi --efi-directory=/efi || { echo "GRUB installation failed."; exit 1; }
    grub-mkconfig -o /boot/grub/grub.cfg || { echo "Failed to generate GRUB configuration."; exit 1; }
}

# Main execution
list_disks
read -r -p "Enter the disk you want to format (e.g., /dev/sdb): " selected_disk
validate_block_device "$selected_disk"

read -r -p "Enter the size of the boot partition in GB (e.g., 1 for 1GB): " boot_size
if [[ -z "$boot_size" || ! "$boot_size" =~ ^[0-9]+$ ]]; then
    echo "Invalid boot partition size. Must be a number."
    exit 1
fi

setup_partitions "$selected_disk" "$boot_size"
download_and_verify_stagefile
configure_system "$selected_disk"
configure_portage
setup_chroot

echo "Gentoo setup script completed. Please chroot into /mnt/gentoo to complete the installation."
