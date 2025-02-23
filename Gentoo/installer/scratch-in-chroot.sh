#!/bin/bash

# Ensure the script run as root
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root!"
    exit 1
fi

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

function chroot_first() {
    echo "Setting up chroot environment..."
    local sel_disk_boot="$1"

    # shellcheck disable=SC1091
    source /etc/profile
    export PS1="(chroot) ${PS1}"

    # Mount the boot partition to /efi
    if ! mount "${sel_disk_boot}1" /efi; then
        echo "Failed to mount boot disk (${sel_disk_boot}1) to /efi"
        exit 1
    fi

    echo "Syncing with Gentoo mirrors..."
    if ! emerge --webrsync; then
        echo "Failed to run webrsync"
        exit 1
    fi

    if ! emerge --sync --quiet; then
        echo "Failed to run --sync --quiet"
        exit 1
    fi

    if ! emerge --config sys-libs/timezone-data; then
        echo "Failed to configure timezone-data"
        exit 1
    fi

    if ! locale-gen; then
        echo "Failed to generate locale"
        exit 1
    fi

    # shellcheck disable=SC1091
    env-update && source /etc/profile
    export PS1="(chroot) ${PS1}"

    echo "Chroot environment setup complete!"
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
    mkdir /efi/EFI/Gentoo

}

# Needs to do before kernel setup
function dracut_update() {
    echo "Updating dracut and preparing initramfs for kernel build..."
    local sel_disk="$1"
    local sel_disk_boot="$2"
    
    echo "Kernel command line generated:"
    # Set Dracut modules for encryption support
    add_dracutmodules+=" crypt crypt-gpg dm rootfs-block "
    kernel_cmdline=""

    # FOR SWAP
    swapuuid=$(blkid "${sel_disk}1" -o value -s UUID)
    if [ -z "$swapuuid" ]; then
        echo "No UUID found for ${sel_disk}1 (SWAP)"
    else
        kernel_cmdline+=" rd.luks.uuid=$swapuuid"
        echo "The swap UUID is set to: $swapuuid"
    fi
    # END SWAP

    # FOR ROOT
    rootlabel=$(blkid "${sel_disk}2" -o value -s LABEL)
    if [ -z "$rootlabel" ]; then
        echo "No label found for ${sel_disk}2 (ROOT)"
    else
        kernel_cmdline+=" root=LABEL=$rootlabel"
        echo "The root LABEL is set to: $rootlabel"
    fi

    rootuuid=$(blkid "${sel_disk}2" -o value -s UUID)
    if [ -z "$rootuuid" ]; then
        echo "No UUID found for ${sel_disk}2 (ROOT)"
    else
        kernel_cmdline+=" rd.luks.uuid=$rootuuid"
        echo "The root UUID is set to: $rootuuid"
    fi
    # END ROOT

    # FOR BOOT (KEYFILE)
    boot_key_uuid=$(blkid "${sel_disk_boot}2" -o value -s UUID)
    if [ -z "$boot_key_uuid" ]; then
        echo "No UUID found for ${sel_disk_boot}2 (KEYFILE STORAGE)"
    else
        kernel_cmdline+=" rd.luks.key=/swap-keyfile.gpg:UUID=$boot_key_uuid"
        kernel_cmdline+=" rd.luks.key=/luks-keyfile.gpg:UUID=$boot_key_uuid"
        echo "The keyfile storage UUID is set to: $boot_key_uuid"
    fi
    # END BOOT
    echo "$kernel_cmdline is gone go to /etc/dracut.conf"
    echo "kernel_cmdlin+=\"$kernel_cmdline\"" >> /etc/dracut.conf
    dracut -v

    echo "Extracting the initramfs"
    cd /usr/src/initramfs || { echo "failed to change directory"; exit 1; }
    echo "It's possible to use dracut to generate an initramfs image, then extract this to be built into the kernel."
    /usr/lib/dracut/skipcpio /boot/initramfs-6.1.28-gentoo-initramfs.img | zcat | cpio -ivd || { echo "could not extract"; exit 1; }
    cd || { echo "changing back to root"; exit 1; }
}

function kernel () {
    echo "This will start a session that user can edit the kernel"
    echo "the flags use in the config is:"
    echo "--luks --gpg --btrfs --keymap --oldconfig --save-config --menuconfig --install all"
    sleep 10
    genkernel --luks --gpg --btrfs --keymap --oldconfig --save-config --menuconfig --install all || { echo "Could not start/install genkernel"; exit 1; }
    sleep 10
    echo "kernel completed"
}

function config_boot() {
    echo "Configuring key to boot using /efi only"

    # Function to get UUID of a partition
    get_uuid() {
        local device="$1"
        blkid -s UUID -o value "$device" 2>/dev/null
    }

    # Get UUIDs for root and swap partitions
    ROOT_PART=$(findmnt -rn -o SOURCE --target /)
    ROOT_UUID=$(get_uuid "$ROOT_PART")

    SWAP_PART=$(findmnt -rn -o SOURCE --fstype swap)
    SWAP_UUID=$(get_uuid "$SWAP_PART")

    # Find the boot key partition dynamically (look for /efi or /boot_extended)
    BOOT_KEY_PART=$(lsblk -o NAME,MOUNTPOINT -r | awk '$2 == "/efi" || $2 == "/boot_extended" {print "/dev/"$1; exit}')
    BOOT_KEY_UUID=$(get_uuid "$BOOT_KEY_PART")

    # Dynamically find the EFI partition
    EFI_PART=$(lsblk -o NAME,MOUNTPOINT -r | awk '$2 == "/media/" {print "/dev/" $1; exit}')
    if [[ -z "$EFI_PART" ]]; then
        log "Error: Could not find the EFI partition."
        exit 1
    fi

    # Verify all required UUIDs were found
    if [[ -z "$ROOT_UUID" || -z "$SWAP_UUID" || -z "$BOOT_KEY_UUID" ]]; then
        echo "Error: Could not find necessary partitions (Root, Swap, or Boot Key Partition)."
        exit 1
    fi

    # Find kernel and initramfs inside /efi (NOT /boot)
    KERNEL_SRC=$(find /efi/EFI/Gentoo/kernel-* 2>/dev/null | head -n 1)
    INITRAMFS_SRC=$(find /efi/EFI/Gentoo/initramfs-* 2>/dev/null | head -n 1)

    if [[ -z "$KERNEL_SRC" || -z "$INITRAMFS_SRC" ]]; then
        echo "Error: Kernel or Initramfs not found in /efi/EFI/Gentoo."
        exit 1
    fi

    sleep 3

    # Create EFI boot entry (using UUID for Boot Key Partition)
    efibootmgr --create --disk boot --part boot \
    --label "Gentoo" \
    --loader '\EFI\Gentoo\bzImage.efi' \
    --unicode "root=UUID=$ROOT_UUID initrd=\EFI\Gentoo\initramfs.img rd.luks.key=UUID=$BOOT_KEY_UUID:/crypto_keyfile.gpg:gpg rd.luks.allow-discards rd.luks.uuid=$SWAP_UUID rd.luks.key=UUID=$BOOT_KEY_UUID:/swap-keyfile.gpg:gpg"

    if [[ $? -eq 0 ]]; then
        log "EFI boot entry created successfully."
    else
        log "Error: Failed to create EFI boot entry."
        exit 1
    fi

    sleep 3

    # Verify EFI entry
    efibootmgr || { echo "Could not create boot entry"; exit 1; }
    sleep 3

    # List files in EFI directory
    ls -lh /efi/EFI/Gentoo/
}

read -r -p "Enter the Boot disk (e.g., /dev/sda): " selected_disk_Boot
read -r -p "Enter the Root disk (e.g., /dev/sda): " selected_disk
validate_block_device "$selected_disk_Boot" "$selected_disk"
chroot_first "$selected_disk_Boot"
emerge_cpuid2cpuflags_and_emptytree
core_package
dracut_update "$selected_disk" "$selected_disk_Boot"
kernel
config_boot "$selected_disk" "$selected_disk_Boot"
