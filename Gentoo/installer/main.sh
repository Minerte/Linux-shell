#!/bin/bash

# Ensure the script run as root
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
    local crypt_name="cryptroot"

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
    cryptsetup luksOpen "${sel_disk}2" $crypt_name || { echo "Failed to open encrypted partition."; exit 1; }

    mkdir -p /mnt/root || { echo "Could not create directory."; exit 1; }
    mkfs.btrfs -L BTROOT /dev/mapper/$crypt_name || { echo "Failed to format encrypted root partition."; exit 1; }
    mount -t btrfs -o defaults,noatime,compress=lzo /dev/mapper/$crypt_name /mnt/root/ || { echo "Failed to mount root."; exit 1; }

    btrfs subvolume create /mnt/root/activeroot || exit
    btrfs subvolume create /mnt/root/home || exit

    mkdir -p /mnt/gentoo/home/ || { echo "Failed to create /mnt/gentoo/home/."; exit 1; }
    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=home /dev/mapper/$crypt_name /mnt/gentoo/home/ || exit
    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=activeroot /dev/mapper/$crypt_name /mnt/gentoo/ || exit

    mkdir -p /mnt/gentoo/efi/ || { echo "Failed to create /mnt/gentoo/efi."; exit 1; }
    mount "${sel_disk}1" /mnt/gentoo/efi/ || { echo "Failed to mount EFI partition."; exit 1; }

    echo "Disk $sel_disk configured with boot (EFI), encrypted root, and home partitions."
    echo "Successfully"
}

# Download and verify gentoo stage file
# And some basic system config
function download_and_verify() {
    echo "Downloading stage file"
    wget -q https://distfiles.gentoo.org/releases/amd64/autobuilds/20241103T164822Z/stage3-amd64-hardened-openrc-20241103T164822Z.tar.xz || { echo "Could not fetch stage file"; exit 1;}
    wget -q https://distfiles.gentoo.org/releases/amd64/autobuilds/20241103T164822Z/stage3-amd64-hardened-openrc-20241103T164822Z.tar.xz.asc || { echo "Could not fetch stage file.asc "; exit 1;}

    echo "Verifying downloaded stage file"
    gpg --import /usr/share/openpgp-keys/gentoo-release.asc || { echo "Failed to import GPG keys."; exit 1; }
    gpg --verify stage3-*.tar.xz.asc || { echo "GPG verification failed."; exit 1; }

    echo "Starting to extract stage file"
    echo "Extracting to directory /mnt/gentoo"
    sleep 20
    tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo || { echo "Failed to extract stage file."; exit 1; }

    echo "Will now edit locale and set keymaps to sv-latin1"
    sleep 5
    sed -i "s/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g" ./etc/locale.gen
    # If dualboot uncomment below
    # sed -i "s/clock=\"UTC\"/clock=\"local\"/g" ./etc/conf.d/hwclock
    sed -i "s/keymap=\"us\"/keymaps=\"sv-latin1\"/g" ./etc/conf.d/keymaps
    echo 'LANG="en_US.UTF-8"' >> ./etc/locale.conf
    echo 'LC_COLLATE="C.UTF-8"' >> ./etc/locale.conf
    echo "Europe/Stockholm" > ./etc/timezone

    echo "Gentoo stage file setup done"
    echo "Successfully"
}

# Edit fstab and grub
function configure_system()  {
    local sel_disk="$1"
    local efi_uuid
    local root_uuid
    efi_uuid=$(find_uuid "${sel_disk}1")
    root_uuid=$(find_uuid "${sel_disk}2")

    ### using EOF
    cat << EOF > /mnt/gentoo/etc/fstab || { echo "Failed to edit fstab with EOF"; exit 1; }
#Configuring system files and fstab...
LABEL=BTROOT    /       btrfs   defaults,noatime,compress=lzo,subvol=activeroot 0 0
LABEL=BTROOT    /home   btrfs   defaults,noatime,compress=lzo,subvol=home       0 0
UUID=$efi_uuid  /efi    vfat    umask=077   0 2
EOF
    ###  Using EOF
    cat << EOF > /mnt/gentoo/etc/default/grub || { echo "Failed to edit grub with EOF"; exit 1;}
#GRUB settings
GRUB_CMDLINE_LINUX_DEFAULT="crypt_root=UUID=$root_uuid quiet"
GRUB_DISABLE_LINUX_PARTUUID=false
GRUB_DISTBIUTOR="Gentoo"
GRUB_TIMEOUT=3
GRUB_ENABLE_CRYPTODISK=y
EOF
}

# Copy over portgae to disk
function configure_portage() {
    echo "Setting up Portage..."
    mkdir -p /mnt/gentoo/etc/portage/repos.conf
    cp /usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
    sleep 3

    # Copy custom portage configuration files
    mkdir /mnt/gentoo/etc/portage/env
    cp /root/Linux-shell-main/Gentoo/portage/env/no-lto /mnt/gentoo/etc/portage/env/
    cp /root/Linux-shell-main/Gentoo/portage/make.conf /mnt/gentoo/etc/portage/
    cp /root/Linux-shell-main/Gentoo/portage/package.env /mnt/gentoo/etc/portage/
    echo "copinging over make.conf and no-lto and env variable successully"
    sleep 3
    # Copy custom portage for package.use
    cp /root/Linux-shell-main/Gentoo/portage/Kernel /mnt/gentoo/etc/portage/package.use/
    cp /root/Linux-shell-main/Gentoo/portage/Lua /mnt/gentoo/etc/portage/package.use/
    cp /root/Linux-shell-main/Gentoo/portage/Network /mnt/gentoo/etc/portage/package.use/
    cp /root/Linux-shell-main/Gentoo/portage/Rust /mnt/gentoo/etc/portage/package.use/
    cp /root/Linux-shell-main/Gentoo/portage/app-alternatives /mnt/gentoo/etc/portage/package.use/
    cp /root/Linux-shell-main/Gentoo/portage/system-core /mnt/gentoo/etc/portage/package.use/
    echo "copinging over package.use successully"
    sleep 3
    # Copy custom portage for package.accept_keywords
    cp /root/Linux-shell-main/Gentoo/portage/tui /mnt/gentoo/etc/portage/package.accept_keywords/
    echo "copinging over package.accept_keywords successully"
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
    sleep 3
    echo "Coping over chroot.sh into chroot"
    cp /root/Linux-shell-main/Gentoo/installer/chroot.sh /mnt/gentoo/
    echo "everything is mounted and ready to chroot"
    echo "User need to run command manually"
    echo "Command: chroot /mnt/gentoo /bin/bash"
    echo "After executing command dont forget to execute chroot.sh if you want autoinstall"
}

list_disks
read -r -p "Enter the disk you want to partition and format (e.g., /dev/sda): " selected_disk
validate_block_device "$selected_disk"
read -r -p "Enter the size for the boot partition in GB (e.g., 1 for 1GB): " boot_size
if [[ -z "$boot_size" || ! "$boot_size" =~ ^[0-9]+$ ]]; then
    echo "Invalid boot size. Must be a number."
    exit 1
fi

setup_partitions "$selected_disk" "$boot_size"
download_and_verify
configure_system "$selected_disk"
configure_portage
setup_chroot
