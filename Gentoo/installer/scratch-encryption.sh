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

function setup_disk() {
    local sel_disk="$1"
    local sel_disk_boot="$2"
    read -r -p "You are about to format the selected disk: $sel_disk. Are you sure? (y/n) " confirm
    if [[ "$confirm" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi
    
# Live disk
sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk "$sel_disk"
g # New GPT disklabel
n # New partition 
1 # partition number
 # Default
+48GB # Swap partition size
t # type
1 # select partition 1
19 # Linux Swap
n # New partition
2 # partition number 
 # default
 # default
p # Print pratitions
w # write to disk
q # exit
EOF

#Boot disk
sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk "$sel_disk_boot"
g # New GPT disklabel
n # new pratition
1 # partition number
 # default
+1G # boot size
t # type
1 # EFI system type
n # new partition
2 # partition number
 # Default
+1G # partition size
t # type
2 # selected partition
142 # Linux extended boot
p # print partitions 
w # write to disk
q # exit
EOF
    # Prep for boot disk
    mkfs.vfat -F32 "${sel_disk_boot}1" || { echo "Failed to make vfat"; exit 1; }
    mkfs.ext4 "${sel_disk_boot}2" || { echo "Failed to make ext 4"; exit 1; }
    mkdir -p /media/external-usb || { echo "Failed to make directory /media/extern-usb"; exit 1; }
    mkdir --parents /media/boot-drive || { echo "Failed /media/boot-drive"; exit 1; }
    mkdir -p /media/boot-drive/efi || { echo "Failed"; exit 1; }
    mount "${sel_disk_boot}2" /media/external-usb || { echo "Failed to mount ${sel_disk_boot}2 to /media/extern-usb"; exit 1; }
    mount "${sel_disk_boot}1" /media/boot-drive || { echo "Failed to mount ${sel_disk_boot}1 to /media/boot-drive"; exit 1; }

    # SETUP MAIN DISK FOR USABLE DRIVE
    # Encrypting swap parition
    cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 --key-file /dev/urandom "${sel_disk}1" cryptswap || { echo "Failed to encrypt swap partition"; exit 1; }
    mkswap /dev/mapper/cryptswap || { echo "Failed to create swap"; exit 1; }
    swapon /dev/mapper/cryptswap || { echo "Failed to swapon"; exit 1; }

    # Making keyfile
    cryptsetup luksFormat --header /media/extern-usb/luks_header.img "${sel_disk}2"
    cd /media/external-usb/ || { echo "failed to change directorty"; exit 1;}
    export GPG_TTY=$(tty)

    dd bs=8388608 count=1 if=/dev/urandom | gpg --symmetric --cipher-algo AES256 --output crypt_key.luks.gpg || { echo "failed to make a keyfile"; exit 1; }

    gpg --decrypt crypt_key.luks.gpg | cryptsetup luksFormat --key-size 512 --cipher aes-xts-plain64 "${sel_disk}2" || { echo "Failed  to decrypt keyfil and encrypt diskt"; exit 1; }

    # cd ~ || { echo "failed to change to root directory"; exit 1; }

    # cryptsetup luksHeaderBackup "${sel_disk}2" --header-backup-file crypt_headers.img || { echo "failed to make a LuksHeader backup"; exit 1;}

    # cd /media/external-usb/ || { echo "failed to change directorty"; exit 1;}

    gpg --decrypt crypt_key.luks.gpg | cryptsetup --key-file - open "${sel_disk}2" cryptroot || { echo "failed to decrypt and open disk ${sel_disk}2 "; exit 1;}

    cd ~ || { echo "failed to change to root directory"; exit 1; }

    # SETUP BOOT DISK

    # Root partition setup
    mkdir -p /mnt/root || { echo "Failed to create directory"; exit 1; }
    mkfs.btrfs -L BTROOT /dev/mapper/cryptroot 
    # Testing purpose
    cryptsetup luksHeaderBackup "${sel_disk}2" --header-backup-file crypt_headers.img || { echo "failed to make a LuksHeader backup"; exit 1;}

    mount -t btrfs -o defaults,noatime,compress=lzo /dev/mapper/cryptroot /mnt/root

    btrfs subvolme create /mnt/root/activeroot || { echo "Failed to create subvolume /activeroot"; exit 1; }
    btrfs subvolme create /mnt/root/home || { echo "Failed to create subvolume /home"; exit 1; }
    btrfs subvolme create /mnt/root/etc || { echo "Failed to create subvolume /etc"; exit 1; }
    btrfs subvolme create /mnt/root/var || { echo "Failed to create subvolume /var"; exit 1; }
    btrfs subvolme create /mnt/root/log || { echo "Failed to create subvolume /log"; exit 1; }
    btrfs subvolme create /mnt/root/tmp || { echo "Failed to create subvolume /tmp"; exit 1; }

    # Creating for subvolume mount
    mkdir -p /mnt/gentoo/home || { echo "failed to create home directory in /mnt/gentoo"; exit 1; }
    mkdir -p /mnt/gentoo/etc || { echo "failed to create etc directory in /mnt/gentoo"; exit 1; }
    mkdir -p /mnt/gentoo/var || { echo "failed to create var directory in /mnt/gentoo"; exit 1; }
    mkdir -p /mnt/gentoo/log || { echo "failed to create log directory in /mnt/gentoo"; exit 1; }
    mkdir -p /mnt/gentoo/tmp || { echo "failed to create tmp directory in /mnt/gentoo"; exit 1; }

    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=activeroot /dev/mapper/cryptroot /mnt/gentoo/
    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=home /dev/mapper/cryptroot /mnt/gentoo/home
    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=etc /dev/mapper/cryptroot /mnt/gentoo/etc
    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=var /dev/mapper/cryptroot /mnt/gentoo/var
    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=log /dev/mapper/cryptroot /mnt/gentoo/log
    mount -t btrfs -o defaults,noatime,nosuid,nodev,noexec,compress=lzo,subvol=tmp /dev/mapper/cryptroot /mnt/gentoo/tmp
}

function Download_stage3file () {
    # Define the base URL for the Gentoo stage-3 directory
    BASE_URL="https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/"

    # Fetch the index page
    INDEX_PAGE=$(curl -s "$BASE_URL")

    # Extract the hardened and hardened-selinux stage-3 tarballs
    HARDENED_TARBALLS=$(echo "$INDEX_PAGE" | grep -oP 'stage3-amd64-hardened-[0-9]{8}\.tar\.xz')
    HARDENED_SELINUX_TARBALLS=$(echo "$INDEX_PAGE" | grep -oP 'stage3-amd64-hardened-selinux-[0-9]{8}\.tar\.xz')

    # Check if we found any stage-3 tarballs
    if [[ -z "$HARDENED_TARBALLS" && -z "$HARDENED_SELINUX_TARBALLS" ]]; then
        echo "No hardened or hardened-selinux stage-3 tarballs found."
        exit 1
    fi

    # Display the available tarballs to the user
    echo "Available hardened stage-3 tarballs:"
    echo "$HARDENED_TARBALLS"
    echo ""
    echo "Available hardened-selinux stage-3 tarballs:"
    echo "$HARDENED_SELINUX_TARBALLS"
    echo ""

    # Let the user choose which version to download
    echo "Please choose a version:"
    echo "1. Hardened"
    echo "2. Hardened-Selinux"
    echo "3. Exit"
    read -r -p "Enter the number of your choice: " CHOICE

    case $CHOICE in
        1)
            # Sort and select the latest hardened tarball
            LATEST_HARDENED=$(echo "$HARDENED_TARBALLS" | sort | tail -n 1)
            DOWNLOAD_URL="${BASE_URL}${LATEST_HARDENED}"
            SIGNATURE_URL="${BASE_URL}${LATEST_HARDENED}.asc"
            echo "The latest hardened stage-3 tarball is: $LATEST_HARDENED"
            echo "Downloading to the current directory..."
        
            # Download the tarball and the signature file to the current directory
            wget "$DOWNLOAD_URL" || { echo "FAILED to fetch stage3 file"; exit 1; }
            wget "$SIGNATURE_URL" || { echo "FAILED to fetch stage3 file.asc"; exit 1; }
            ;;
        2)
            # Sort and select the latest hardened-selinux tarball
            LATEST_HARDENED_SELINUX=$(echo "$HARDENED_SELINUX_TARBALLS" | sort | tail -n 1)
            DOWNLOAD_URL="${BASE_URL}${LATEST_HARDENED_SELINUX}"
            SIGNATURE_URL="${BASE_URL}${LATEST_HARDENED_SELINUX}.asc"
            echo "The latest hardened-selinux stage-3 tarball is: $LATEST_HARDENED_SELINUX"
            echo "Downloading to the current directory..."
        
            # Download the tarball and the signature file to the current directory
            wget "$DOWNLOAD_URL" || { echo "FAILED to fetch stage3 file"; exit 1; }
            wget "$SIGNATURE_URL" || { echo "FAILED to fetch stage3 file.asc"; exit 1; }
            ;;
        3)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid choice. Exiting..."
            exit 1
            ;;
    esac

    echo "Verifying downloaded stage file"
    gpg --import /usr/share/openpgp-keys/gentoo-release.asc || { echo "Failed to import GPG keys."; exit 1; }
    gpg --verify stage3-*.tar.xz.asc || { echo "GPG verification failed."; exit 1; }
    sleep 5
    echo "extracting stage3 file"
    tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo || { echo "failed to extract"; exit 1; }

    
    echo "Will now edit locale and set keymaps to sv-latin1"
    sleep 5
    sed -i "s/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g" /mnt/gentoo/etc/locale.gen
    # If dualboot uncomment below
    # sed -i "s/clock=\"UTC\"/clock=\"local\"/g" ./etc/conf.d/hwclock
    sed -i "s/keymap=\"us\"/keymaps=\"sv-latin1\"/g" /mnt/gentoo/etc/conf.d/keymaps
    echo 'LANG="en_US.UTF-8"' >> /mnt/gentoo/etc/locale.conf
    echo 'LC_COLLATE="C.UTF-8"' >> /mnt/gentoo/etc/locale.conf
    echo "Europe/Stockholm" > /mnt/gentoo/etc/timezone
    
    echo "Gentoo stage file setup done"
    echo "Successfully"
}

function config_system () {
    root_uuid=$(find_uuid "${sel_disk}2")
    efi_uuid=$(find_uuid "${sel_disk_boot}1")

    echo "we will be using EOF to configure fstab"
    echo "All this coming from first function where we created disk and subvolome"
    cat << EOF > /mnt/gentoo/etc/fstab || { echo "Failed to edit fstab with EOF"; exit 1; }
UUID=$efi_uuid  /efi    vfat    umask=077                                           0 2
LABEL=BTROOT    /       btrfs   defaults,noatime,compress=lzo,subvol=activeroot     0 0
LABEL=BTROOT    /home   btrfs   defaults,noatime,compress=lzo,subvol=home           0 0
LABEL=BTROOT    /etc    btrfs   defaults,noatime,compress=lzo,subvol=etc            0 0
LABEL=BTROOT    /var    btrfs   defaults,noatime,compress=lzo,subvol=var            0 0
LABEL=BTROOT    /log    btrfs   defaults,noatime,compress=lzo,subvol=log            0 0
LABEL=BTROOT    /tmp    btrfs   defaults,noatime,nosuid,nodev,noexec,compress=lzo,subvol=tmp    0 0
EOF

    # The grub config will not be in the same disk it will be in the sel_disk_boot
    cat << EOF > /mnt/gentoo/etc/default/grub || { echo "Failed to edit grub with EOF"; exit 1; }
GRUB_CMDLINE_LINUX_DEFAULT="crypt_root=UUID=$root_uuid quiet"
GRUB_DISABLE_LINUX_PARTUUID=false
GRUB_DISTBIUTOR="Gentoo"
GRUB_TIMEOUT=3
GRUB_ENABLE_CRYPTODISK=y
EOF
}

function config_portage () {
    echo "we will now configure system"
    mkdir -p /mnt/gentoo/etc/portage/repos.conf
    cp /usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
    sleep 3

    # Copy custom portage configuration files
    mkdir /mnt/gentoo/etc/portage/env
    mv ~/Linux-shell-main/Gentoo/portage/env/no-lto /mnt/gentoo/etc/portage/env/
    mv ~/Linux-shell-main/Gentoo/portage/make.conf /mnt/gentoo/etc/portage/
    mv ~/Linux-shell-main/Gentoo/portage/package.env /mnt/gentoo/etc/portage/

    mv ~/Linux-shell-main/Gentoo/portage/package.use/* /mnt/gentoo/etc/portage/package.use/
    mv ~root/Linux-shell-main/Gentoo/portage/package.accept_keywords/* /mnt/gentoo/etc/portage/package.accept_keywords/
    echo "copinging over package.accept_keywords successully"
    echo "Portage configuration complete."
}

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
    cp /root/Linux-shell-main/Gentoo/installer/scratch.in.chroot.sh /mnt/gentoo/ || { echo "Failed to copy over chroot"; exit 1; }
    chmod +x /mnt/gentoo/chroot.sh || { echo "Failed to make chroot.sh executable"; exit 1; }
    echo "everything is mounted and ready to chroot"
    echo "chrooting will be in 10 sec"
    echo "After the chroot is done it will be in another"
    echo "Bash session"
    sleep 10
    chroot /mnt/gentoo /bin/bash -c "./scratch-in-chroot.sh" || { echo "failed to chroot"; exit 1; }
}

list_disks
echo "Note: In this script the boot and boot partition and keyfile will be on another disk"
echo "so it will prompt two times for disk selection, Please read the prompt correctly!"
read -r -p "Enter the disk you want to partition and format for Boot (e.g., /dev/sda): " selected_disk_Boot
read -r -p "Enter the disk you want to partition and format for Root/swap(e.g., /dev/sda): " selected_disk
validate_block_device "$selected_disk" "$selected_disk_Boot"
setup_disk "$selected_disk" "$selected_disk_Boot"
move_encryption
Download_stage3file
config_system
config_portage
setup_chroot
