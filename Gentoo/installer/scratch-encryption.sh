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

function setup_disk() {

    local sel_disk="$1"
    local sel_disk_boot="$2"
    read -r -p "You are about to format the selected disk: $sel_disk. Are you sure? (y/n) " confirm
    if [[ "$confirm" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi
    
# Live disk
    echo "Editing disk for drive"
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
    echo "Editing disk for boot and key"
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
    # Start Prep for boot disk
    echo "Making filesystem for boot and key"
    mkfs.vfat -F 32 "${sel_disk_boot}1"
    mkfs.ext4 "${sel_disk_boot}2"
    echo "Making directory in /media/ to mount the key"
    mkdir /media/ex-usb
    mount "${sel_disk_boot}2" /media/ex-usb
    cd /media/ex-usb || { echo "Failed to change directory"; exit 1;}
    # End of prep for boot disk

    # Start prep for swap partition
    echo "Generating random keyfile"
    dd if=/dev/urandom of=swap-keyfile bs=8388608 count=1 || { echo "Could not generate key for swap-keyfile"; exit 1; }
    echo "GPG symmetric encryption for keyfile"
    gpg --symmetric --cipher-algo AES256 --output swap-keyfile.gpg swap-keyfile || { echo "Could not encrypt key with gpg --symmetric key for swap-keyfile"; exit 1; }

    echo "Decrypting GPG keyfile"
    gpg --decrypt --output /tmp/swap-keyfile swap-keyfile.gpg || { echo "Could not decrypt key with gpg --symmetric key for swap-keyfile"; exit 1; }
    echo "Encrypting swap partition with keyfile"
    cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 "${sel_disk}1" --key-file=/tmp/swap-keyfile || { echo "Could not encrypt swap partition with key-file swap-keyfile"; exit 1; }

    echo "Opening up the swap partition"
    cryptsetup open "${sel_disk}1" cryptswap --key-file=/tmp/swap-keyfile || { echo "Could not open the encrypted swap partition"; exit 1; }
    echo "Shreding keyfile"
    shred -u /tmp/swap-keyfile
    
    # Swap partition setup
    echo "Making swap and swapon"
    mkswap /dev/mapper/cryptswap || { echo "Failed to make swap"; exit 1; }
    swapon /dev/mapper/cryptswap || { echo "No swap on"; exit 1; }
    # End of prep for swap partition

    # Start prep for root partition
    echo "Generating random keyfile"
    dd if=/dev/urandom of=luks-keyfile bs=8388608 count=1 || { echo "Could not generate key for luks-keyfile"; exit 1; }
    echo "GPG symmetric encryption for keyfile"
    gpg --symmetric --cipher-algo AES256 --output luks-keyfile.gpg luks-keyfile || { echo "Could not encrypt key with gpg --symmetric key for luks-keyfile"; exit 1; }

    echo "Decrypting GPG keyfile"
    gpg --decrypt --output /tmp/luks-keyfile luks-keyfile.gpg || { echo "Could not decrypt key with gpg --symmetric key for luks-keyfile"; exit 1; }
    echo "Encrypting root partition with keyfile"
    cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 "${sel_disk}2" --key-file=/tmp/luks-keyfile || { echo "Could encrypt root partition with key-file luks-keyfile"; exit 1; }

    echo "Opening up the root partition"
    cryptsetup open "${sel_disk}2" cryptroot --key-file=/tmp/luks-keyfile || { echo "Could not open the encrypted root partition"; exit 1; }
    echo "Shreding keyfile"
    shred -u /tmp/luks-keyfile
    # End of prep for root partition

    cd || { echo "Failed to change to user root directory"; exit 1; }

    # Root partition setup
    echo "Making /mnt/root for mount of subvolumes"
    mkdir /mnt/root || { echo "Failed to create directory"; exit 1; }
    echo "Makeing btrfs filesystem"
    mkfs.btrfs -L BTROOT /dev/mapper/cryptroot || { echo "Failed to create btrfs"; exit 1; }
    echo "mounting filesystem to /mnt/root"
    mount -t btrfs -o defaults,noatime,compress=zstd /dev/mapper/cryptroot /mnt/root || { echo "Failed to mount btrfs /dev/mapper/cryptroot to /mnt/root"; exit 1; }

    # Create subvolumes
    echo "creation of subvolumes"
    for sub in activeroot home etc var log tmp; do
        btrfs subvolume create "/mnt/root/$sub" || { echo "Failed to create subvolume $sub"; exit 1; }
    done

    # Creating and mounting to root
    echo "Mounting everything to /mnt/gentoo"
    mount -t btrfs -o defaults,noatime,compress=zstd,subvol=activeroot /dev/mapper/cryptroot /mnt/gentoo/
    mkdir /mnt/gentoo/{home,etc,var,log,tmp,efi}
    for sub in home etc var log tmp; do
        mount -t btrfs -o defaults,noatime,compress=zstd,subvol=$sub /dev/mapper/cryptroot /mnt/gentoo/$sub
    done
    # End of prep for root partition

    lsblk
    read -rp "\nDoes the disk layout look correct? (y/n): " user_input
    if [[ "$user_input" =~ ^[Nn] ]]; then
        echo "Exiting..."
        exit 1
    fi
    echo "The disk have been succesfully modified with btrfs and subvolumes and the encryption process"
    echo "Continuing script..."

}

function Download_and_Verify_stage3() {

    cd / || { echo "Failed to change directory to root"; exit 1; }

    URL1="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-hardened-openrc/"
    URL1_FALLBACK="https://gentoo.osuosl.org/releases/amd64/autobuilds/current-stage3-amd64-hardened-openrc/"
    URL2="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-hardened-selinux-openrc/"
    URL2_FALLBACK="https://gentoo.osuosl.org/releases/amd64/autobuilds/current-stage3-amd64-hardened-selinux-openrc/"

    echo "------------------------------------------------------------------------"
    echo "Please choose the type of stage3 file for amd64:"
    echo "1. Hardened OpenRC (URL1)"
    echo "2. Hardened SELinux OpenRC (URL2)"
    echo "------------------------------------------------------------------------"
    read -rp "Enter your choice (1-2): " type_choice

    case "$type_choice" in
        1)
            BOUNCER_URL="$URL1"
            FALLBACK_URL="$URL1_FALLBACK"
            FILE_PATTERN='stage3-amd64-hardened-openrc-\d{8}T\d{6}Z\.tar\.xz'
            ;;
        2)
            echo "As of 2025-02-27 can empty tree proberlay with certain flags and pyton targets"
            BOUNCER_URL="$URL2" 
            FALLBACK_URL="$URL2_FALLBACK"
            FILE_PATTERN='stage3-amd64-hardened-selinux-openrc-\d{8}T\d{6}Z\.tar\.xz'
            ;;
        *)
            echo "Invalid choice. Exiting..."
            exit 1
            ;;
    esac

    echo "Fetching the latest stage3 file from $BOUNCER_URL..."
    echo "------------------------------------------------------------------------"

    # Try to retrieve the list of files from the selected Bouncer URL
    FILE_LIST=$(curl -s "$BOUNCER_URL")
    if [[ -z "$FILE_LIST" ]]; then
        echo "Primary URL failed. Trying fallback URL $FALLBACK_URL..."
        FILE_LIST=$(curl -s "$FALLBACK_URL")
        if [[ -z "$FILE_LIST" ]]; then
            echo "Failed to retrieve the list of files from both primary and fallback URLs. Exiting..."
            exit 1
        fi
        BOUNCER_URL="$FALLBACK_URL"
    fi

    # Find the latest stage3 file and its corresponding .asc file
    STAGE3_FILENAME=$(echo "$FILE_LIST" | grep -oP "$FILE_PATTERN" | tail -n 1)
    ASC_FILENAME="${STAGE3_FILENAME}.asc"

    if [[ -z "$STAGE3_FILENAME" || -z "$ASC_FILENAME" ]]; then
        echo "Failed to find the latest stage3 file or its .asc file. Exiting..."
        exit 1
    fi

    STAGE3_URL="$BOUNCER_URL/$STAGE3_FILENAME"
    ASC_URL="$BOUNCER_URL/$ASC_FILENAME"

    echo "Downloading stage3 file: $STAGE3_FILENAME"
    curl -O "$STAGE3_URL" || { echo "Failed to download stage3 file"; exit 1; }

    echo "Downloading verification file: $ASC_FILENAME"
    curl -O "$ASC_URL" || { echo "Failed to download .asc file"; exit 1; }

    # Ensure the files are not empty
    if [[ ! -s "$STAGE3_FILENAME" || ! -s "$ASC_FILENAME" ]]; then
        echo "Downloaded files are empty. Exiting..."
        exit 1
    fi

    echo "Download complete: $STAGE3_FILENAME and $ASC_FILENAME"

    echo "Importing Gentoo release key..."
    gpg --import /usr/share/openpgp-keys/gentoo-release.asc || { echo "Failed to import Gentoo release key"; exit 1; }
    # Can add if the file dont want to verify with the extra troubleshooting
    # gpg --keyserver hkps://keys.gentoo.org --recv-keys 0xBB572E0E2D182910 || { echo "Failed to retrieve key from keyserver"; exit 1; }
    echo "Key successfully imported"

    echo "Verifying stage3 file..."
    # Can add --debug-level guru for troubleshooting
    gpg --verify "$ASC_FILENAME" "$STAGE3_FILENAME" || { echo "Failed to verify $STAGE3_FILENAME with $ASC_FILENAME"; exit 1; }
    echo "Verification successful!"
    sleep 5

    echo "Extracting stage3 file..."
    tar xpvf "$STAGE3_FILENAME" --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo || { echo "Failed to extract $STAGE3_FILENAME"; exit 1; }

    echo "Gentoo stage3 file setup complete."
    echo "Success!"

}

function config_system () {

    echo "we will be using EOF to configure fstab"
    echo "All this coming from first function where we created disk and subvolome"
    cat << EOF > /mnt/gentoo/etc/fstab || { echo "Failed to edit fstab with EOF"; exit 1; }
LABEL=BTROOT    /       btrfs   defaults,noatime,compress=zstd,subvol=activeroot     0 0
LABEL=BTROOT    /home   btrfs   defaults,noatime,compress=zstd,subvol=home           0 0
LABEL=BTROOT    /etc    btrfs   defaults,noatime,compress=zstd,subvol=etc            0 0
LABEL=BTROOT    /var    btrfs   defaults,noatime,compress=zstd,subvol=var            0 0
LABEL=BTROOT    /log    btrfs   defaults,noatime,compress=zstd,subvol=log            0 0
LABEL=BTROOT    /tmp    btrfs   defaults,noatime,nosuid,nodev,noexec,compress=zstd,subvol=tmp    0 0
EOF

    sleep 3
    echo "setting up loclale.gen"
    sed -i "s/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g" /mnt/gentoo/etc/locale.gen
    # If dualboot uncomment below
    # sed -i "s/clock=\"UTC\"/clock=\"local\"/g" ./etc/conf.d/hwclock
    echo "Changing to swedish keyboard"
    sed -i "s/keymap=\"us\"/keymaps=\"sv-latin1\"/g" /mnt/gentoo/etc/conf.d/keymaps
    echo "change locale.conf and edit timezone to Europe/Stockholm"
    echo 'LANG="en_US.UTF-8"' >> /mnt/gentoo/etc/locale.conf
    echo 'LC_COLLATE="C.UTF-8"' >> /mnt/gentoo/etc/locale.conf
    echo "Europe/Stockholm" > /mnt/gentoo/etc/timezone

    echo "Succesfully edited basic system"

}

function config_portage () {

    echo "we will now configure system"
    mkdir -p /mnt/gentoo/etc/portage/repos.conf
    cp /usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
    echo "we will now have network in chroot later"
    sleep 3

    # Copy custom portage configuration files
    echo "Moving over portge file from download to chroot"
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
    sleep 5

    echo "Coping over chroot.sh into chroot"
    cp /root/Linux-shell-main/Gentoo/installer/scratch-in-chroot.sh /mnt/gentoo/ || { echo "Failed to copy over chroot"; exit 1; }
    chmod +x /mnt/gentoo/scratch-in-chroot.sh || { echo "Failed to make chroot.sh executable"; exit 1; }
    echo "everything is mounted and ready to chroot"
    echo "chrooting will be in 10 sec"
    echo "After the chroot is done it will be in another bash session"
    sleep 10
    chroot /mnt/gentoo /bin/bash -c "./scratch-in-chroot.sh" || { echo "failed to chroot"; exit 1; }

}

echo "Hello and welcome to an Gentoo linux install script!"
echo "That the script is very limited what the user can edit and configure."
echo "If you look at the source code you will understand."
echo "For this is almost just a basic Gentoo install because of the packages."
echo "And the disk configuration is very hardcoded hehehehe ;)"
echo "Lets start!!!"
export GPG_TTY=$(tty)

list_disks
echo "-------------------------------------------------------------------------------------"
echo "Note: In this script the boot and boot partition and keyfile will be on another disk"
echo "So it will prompt two times for disk selection, Please read the prompt correctly!"
echo "-------------------------------------------------------------------------------------"
read -r -p "Enter the disk you want to partition and format for Boot (e.g., /dev/sda): " selected_disk_Boot
read -r -p "Enter the disk you want to partition and format for Root/swap(e.g., /dev/sda): " selected_disk
validate_block_device "$selected_disk" "$selected_disk_Boot"
setup_disk "$selected_disk" "$selected_disk_Boot"
Download_and_Verify_stage3
config_system
config_portage
setup_chroot
