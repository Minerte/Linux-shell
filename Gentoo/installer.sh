#!/bin/bash

# List avalibale disk
function list_disks() {
    echo "Avalible disks:"
    lsblk -d -n -o NAME,SIZE | awk '{print "/dev/" $1 " - " $2}'
}

function find_uuid() {
    local partition="$1"
    if [[ ! -b "$partition" ]]; then
        echo "Error: $partition is not a valid block device."
        exit 1
    fi

    # Using blkid to fin UUID of the partition
    local uuid
    uuid=$(blkid -s UUID -o value "$partition")
    echo "$uuid"
}

# Format and mount selected disk
function setup_partitions() {
    local sel_disk="$1"
    local boot_size="$2"
    local mount_point="$3"
    local crypt_name="cryptroot"

    read -r -p "You are about to format the SELECTED disk: $sel_disk. Are you sure? (y/n) " confirm
    if [[ "$confirm" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi
    
    # Using parted for disk partion
    echo "Ready to format selected disk $sel_disk..."
    parted "$sel_disk" mklabel gpt
    echo "Creating boot partition of size ${boot_size}GB..."
    parted -s "$sel_disk" mkpart boot fat32 0% "${boot_size}"
    parted set 1 boot on
    echo "Creating root pratition with rest of the disk"
    parted "$sel_disk" mkpart root btrfs "${boot_size}" 100%

    # Foramtting boot/efi pratition
    echo "Formatting boot pratition"
    mkfs.vfat -F 32 "${sel_disk}1"

    # Encryption on second partition
    echo "Disk encryption for second partition"
    cryptsetup luksFormat -s 512 -c aes-xts-plain64 "${sel_disk}2"
    cryptsetup luksOpen "${sel_disk}2" "$crypt_name"

    # Will make btrfs and mount it in /mnt/root
    echo "Creating filesystem and mountpoint in /mnt/root"
    mkfs.btrfs -L BTROOT /dev/mapper/$crypt_name
    mkdir /mnt/root
    mount -t btrfs -o defaults,noatime,compress=lzo /dev/mapper/$crypt_name /mnt/root/

    # Creating subvolume
    btrfs subvolume create /mnt/root/activeroot
    btrfs subvolume create /mnt/root/home

    # Mounting subvolume
    mkdir /mnt/gentoo/home
    # /mnt/gentoo coming from wiki where root is suppose to be mounted
    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=activeroot /dev/mapper/$crypt_name /mnt/gentoo/
    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=home /dev/mapper/$crypt_name /mnt/gentoo/home
    
    # EFI
    mkdir /mnt/gentoo/efi
    mount /dev/"${sel_disk}1" /mnt/gentoo/efi/
    # Boot
    # mkdir /mnt/gentoo/boot
    # mount /dev/"${sel_disk}1" /mnt/gentoo/boot/
    
    echo "Disk $sel_disk configure with boot (EFI), encrypted root and home"
}

function first_setup () {
    echo "This will now start to import and configer basic before chroot"
    # Gentoo stage files and verify
    wget https://distfiles.gentoo.org/releases/amd64/autobuilds/ # Add latest version of set build at the end
    wget https://distfiles.gentoo.org/releases/amd64/autobuilds/ # Add latest version of set build.asc at the end

    gpg --import /usr/share/openpgp-keys/gentoo-release.asc
    gpg --verify ./stage3-*.tar.xz.asc

    mv ./stage3-*.tar.xz /mnt/gentoo
    cd /mnt/gentoo || exit

    tar tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

    sed -i "s/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g" ./etc/locale.gen
    sed -i "s/clock=\"UTC\"/clock=\"local\"/g" ./etc/conf.d/hwclock
    sed -i "s/keymap=\"us\"/keymaps=\"sv-latin1\"/g" ./etc/conf.d/keymaps

    echo 'LANG="en_US.UTF-8"' >> ./etc/locale.conf
    echo 'LC_COLLATE="C.UTF-8"' >> ./etc/locale.conf
    echo "Europe/Stockholm" > ./etc/timezone
}

function second_setup () {
    echo "We will configuer fstab and grub"
    #Upadteing ./etc/fstab
    local efi_uuid
    efi_uuid=$(find_uuid "${sel_disk}1")
    echo "LABEL=BTROOT  /       btrfs   defaults,noatime,compress=lzo,subvol=activeroot 0 0" | tee -a ./etc/fstab
    echo "LABEL=BTROOT  /home   btrfs   defaults,noatime,compress=lzo,subvol=home       0 0" | tee -a ./etc/fstab
    echo "UUID=$efi_uuid    /efi    vfat    umask=077   0 2" | tee -a ./etc/fstab
    # echo "UUID=yyyyyyy  /boot    vfat    umask=077   0 2" | tee -a /etc/fstab
    # If user have made /boot partition

    # Grub config
    local root_uuid
    root_uuid=$(find_uuid "/dev/mapper/$crypt_name")
    echo "Updating ./etc/default/grub with root uuid: $root_uuid"
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"crypt_root=UUID=$root_uuid quiet\"|" ./etc/default/grub
    sed -i "s|^GRUB_DISABLE_LINUX_PARTUUID=\.*\|GRUB_DISABLE_LINUX_PARTUUID=\false\|" ./etc/default/grub
    sed -i "s|^GRUB_DISTBIUTOR=\".*\"|GRUB_DISTBIUTOR=\"Gentoo\"|" ./etc/default/grub
    sed -i "s|^GRUB_TIMEOUT=\".*\"|GRUB_TIMEOUT=\10\|" ./etc/default/grub
    sed -i "s|^GRUB_ENABLE_CRYPTODISK=\".*\"|GRUB_ENABLE_CRYPTODISK=\y\|" ./etc/default/grub
}

# Main script execution
list_disks

# Prompt user for disk selection
read -r -p "Enter the disk you want to format (e.g., /dev/sdb): " selected_disk

# Prompt user for boot partition size
read -r -p "Enter the size of the boot partition in GB (e.g., 1 for 1GB): " boot_size

# Prompt user for mount point
read -r -p "Enter the mount point for the root partition (e.g., /mnt/mydisk): " mount_point

# Validate user input
if [[ ! -b "$selected_disk" ]]; then
    echo "Error: $selected_disk is not a valid block device."
    exit 1
fi

# Call the function to format and mount the disk
setup_partitions "$selected_disk" "$boot_size" "$mount_point" "$crypt_name"
