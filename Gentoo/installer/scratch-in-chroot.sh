#!/bin/bash

# Ensure the script run as root
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root!"
    exit 1
fi

# List available disks
function list_disks() {
    echo "Available disks:"
    lsblk -d -n -o NAME,SIZE,UUID,LABEL | awk '{print "/dev/" $1 " - " $2}'
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

function chroot_first () {

    local sel_disk_boot=$"1"
    echo "Setting upp chroot"
    source /etc/profile 
    export PS1="(chroot) ${PS1}"
    sleep 3

    mount "${sel_disk_boot}1" /efi || { echo "Failed to mount boot disk to /efi"; exit 1; }
    sleep 3
    echo "Now we are gone sync with the mirrors"
    sleep 5
    emerge --webrsync  || { echo "Failed to webrsync"; exit 1; }
    sleep 3
    emerge --sync --quiet  || { echo "Failed to --sync --quiet"; exit 1; }
    sleep 3
    emerge --config sys-libs/timezone-data || { echo "Failed to emerge --config timezone-data"; exit 1; }
    locale-gen
    env-update && source /etc/profile && export PS1="(chroot) ${PS1}"
}

function emerge_cpuid2cpuflags_and_emptytree () {

    # Adds cpuflag to make.conf
    echo "emerge cpuid2cpuflags"
    emerge --ask app-portage/cpuid2cpuflags
    sleep 5
    echo "Adding flag to make.conf"
    CPU_FLAGS=$(cpuid2cpuflags | cut -d' ' -f2-)
    if grep -q "^CPU_FLAGS_X86=" /etc/portage/make.conf; then
        sed -i "s/^CPU_FLAGS_X86=.*/CPU_FLAGS_X86=\"${CPU_FLAGS}\"/" /etc/portage/make.conf  || { echo "could not add CPU_FLAGS_X86= and cpuflags to make.conf"; exit 1; }
    else
        echo "CPU_FLAGS_X86=\"${CPU_FLAGS}\"" >> /etc/portage/make.conf || { echo "could not add cpuflags to make.conf"; exit 1; }
    fi
    sleep 5
    echo "re-compiling existing package"
    sleep 5
    emerge --emptytree -a -1 @installed  || { echo "Dont want to re-compile check dependency and flags"; exit 1; }
    sleep 10
    echo "Cpuflags added and recompile apps"
    echo "Completted succesfully"
    sleep 5

    emerge --ask dev-lang/rust || { echo "Rust dont want to compile check dependency and flags"; exit 1; }
    sleep 5
    echo "enable system-bootstrap in /etc/portage/package.use/Rust"
    sed -i 's/\(#\)system-bootstrap/\1/' /etc/portage/package.use/Rust
}

function core_package () {

    echo "emerging core packages!"
    emerge --ask sys-kernel/gentoo-source sys-kernel/genkernel sys-kernel/installkernel sys-kernel/linux-firmware \
    sys-fs/cryptsetup sys-fs/btrfs-progs sys-apps/sysvinint sys-auth/seatd sys-apps/dbus sys-apps/pciutils \
    sys-process/cronie net-misc/chrony net-misc/networkmanager app-admin/sysklogd app-shells/bash-completion \
    dev-vcs/git sys-apps/mlocate sys-block/io-scheduler-udev-rules sys-boot/efibootmgr || { echo "Could not merge! check dependency and flags"; exit 1; }

    echo "Core packages installed succesfully!"
    mkdir -p /efi/EFI/Gentoo

}

function config_system () {
    echo "Will now be editing config"

}
# Needs to do before kernel setup
function dracut_update () {

    local sel_disk="$1"
    local sel_disk_boot="$2"
    echo "will be updating dracut"
    echo "and extracting generated initramfs image to be build with the kernel"
}

function kernel () {
    echo "This will start a session that user can edit the kernel"
    echo "the flags use in the config is:"
    echo "--luks --gpg --btrfs --keymap --oldconfig --save-config --menuconfig --install all"

}

chroot_first
emerge_cpuid2cpuflags_and_emptytree
