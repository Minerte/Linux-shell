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
    # Start Prep for boot disk
    mkfs.vfat -F 32 "${sel_disk_boot}1"
    mkfs.ext4 "${sel_disk_boot}2"
    mkdir /media/ex-usb
    mount "${sel_disk_boot}2" /media/ex-usb
    cd /media/ex-usb || { echo "Failed to change directory"; exit 1;}
    # End of prep for boot disk

    # Start prep for swap partition
    dd if=/dev/urandom of=swap-keyfile bs=8388608 count=1 || { echo "Could not generate key for swap-keyfile"; exit 1; }
    gpg --symmetric --cipher-algo AES256 --output swap-keyfile.gpg swap-keyfile || { echo "Could not encrypt key with gpg --symmetric key for swap-keyfile"; exit 1; }

    gpg --decrypt --output /tmp/swap-keyfile swap-keyfile.gpg || { echo "Could not decrypt key with gpg --symmetric key for swap-keyfile"; exit 1; }
    cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 "${sel_disk}1" --key-file=/tmp/swap-keyfile || { echo "Could not encrypt swap partition with key-file swap-keyfile"; exit 1; }

    cryptsetup open "${sel_disk}1" cryptswap --key-file=/tmp/swap-keyfile || { echo "Could not open the encrypted swap partition"; exit 1; }
    shred -u /tmp/swap-keyfile
    
    # Swap partition setup
    mkswap /dev/mapper/cryptswap || { echo "Failed to make swap"; exit 1; }
    swapon /dev/mapper/cryptswap || { echo "No swap on"; exit 1; }
    # End of prep for swap partition

    # Start prep for root partition
    dd if=/dev/urandom of=luks-keyfile bs=8388608 count=1 || { echo "Could not generate key for luks-keyfile"; exit 1; }
    gpg --symmetric --cipher-algo AES256 --output luks-keyfile.gpg luks-keyfile || { echo "Could not encrypt key with gpg --symmetric key for luks-keyfile"; exit 1; }

    gpg --decrypt --output /tmp/luks-keyfile luks-keyfile.gpg || { echo "Could not decrypt key with gpg --symmetric key for luks-keyfile"; exit 1; }
    cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 "${sel_disk}2" --key-file=/tmp/luks-keyfile || { echo "Could encrypt root partition with key-file luks-keyfile"; exit 1; }

    cryptsetup open "${sel_disk}2" cryptroot --key-file=/tmp/luks-keyfile || { echo "Could not open the encrypted root partition"; exit 1; }
    shred -u /tmp/luks-keyfile
    # End of prep for root partition

    cd ~ || { echo "Failed to change to user root directory"; exit 1; }

    # Root partition setup
    mkdir /mnt/root || { echo "Failed to create directory"; exit 1; }
    mkfs.btrfs -L BTROOT /dev/mapper/cryptroot || { echo "Failed to create btrfs"; exit 1; }
    mount -t btrfs -o defaults,noatime,compress=zstd /dev/mapper/cryptroot /mnt/root || { echo "Failed to mount btrfs /dev/mapper/cryptroot to /mnt/root"; exit 1; }

    # Create subvolumes
    for sub in activeroot home etc var log tmp; do
        btrfs subvolume create "/mnt/root/$sub" || { echo "Failed to create subvolume $sub"; exit 1; }
    done

    # Creating and mounting to root
    mount -t btrfs -o defaults,noatime,compress=zstd,subvol=activeroot /dev/mapper/cryptroot /mnt/gentoo/
    mkdir /mnt/gentoo/{home,etc,var,log,tmp}
    for sub in home etc var log tmp; do
        mount -t btrfs -o defaults,noatime,compress=zstd,subvol=$sub /dev/mapper/cryptroot /mnt/gentoo/$sub
    done

    # End of prep for root partition

    # Function to display partitions in tree format
    lsblk
    # Ask user for confirmation
    echo -e "\nDoes the disk layout look correct? (y/n): "
    read -r user_input

    if [[ "$user_input" =~ ^[Nn] ]]; then
        echo "Exiting..."
        exit 1
    fi

    # Continue with the rest of your script
    echo "The disk have been succesfully modified with btrfs and subvolumes and the encryption process"
    echo "Continuing script..."
    # Add your next steps here
}

function Download_stage3file() {

    # Function to download a file
    download_file() {
        local url=$1
        local dest=$2
        echo "Downloading $dest from $url..."
        curl -O "$url"
    }

    # Function to verify the file with .asc
    verify_file() {
        local file=$1
        local asc_file=$2
        echo "Verifying $file with $asc_file..."
        gpg --verify "$asc_file" "$file"
        if [ $? -eq 0 ]; then
            echo "Verification successful!"
        else
            echo "Verification failed!"
            exit 1
        fi
    }

    # Prompt user to choose between Hardened and SELinux
    echo "Choose the Gentoo Linux Stage file version:"
    echo "1. Hardened"
    echo "2. SELinux"
    read -p "Enter choice (1 or 2): " choice

    # Set the URL variables for Hardened and SELinux
    if [ "$choice" -eq 1 ]; then
        # Hardened
        base_url="https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/"
        profile="hardened"
    elif [ "$choice" -eq 2 ]; then
        # SELinux
        base_url="https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/"
        profile="selinux"
    else
        echo "Invalid choice! Exiting."
        exit 1
    fi

    # Fetch the latest file list and find the most recent stage3 file for the selected profile
    echo "Fetching the latest file for $profile..."
    file_list=$(curl -s "$base_url" | grep -oP "stage3-amd64-${profile}.*\.tar\.xz")

    # If no files were found, exit with an error
    if [ -z "$file_list" ]; then
        echo "No files found for the selected profile: $profile."
        exit 1
    fi

    # Get the latest file (by sorting by date in filename)
    latest_file=$(echo "$file_list" | sort -V | tail -n 1)

    # Ensure that the .asc file matches the version of the .tar.xz file
    asc_file="${latest_file}.asc"

    # If the .asc file doesn't match, exit with an error
    if ! echo "$file_list" | grep -q "$asc_file"; then
        cho "The .asc file does not match the .tar.xz file version. Exiting."
        exit 1
    fi

    # Form full URLs for the stage file and .asc file
    stage_url="${base_url}${latest_file}"
    asc_url="${base_url}${asc_file}"

    echo "Latest file found: $latest_file"
    echo "Downloading stage file: $stage_url"
    echo "Downloading .asc file: $asc_url"

    # Download the stage file and .asc file
    download_file "$stage_url" "$latest_file"
    download_file "$asc_url" "$asc_file"

    # Verify the file with .asc
    verify_file "$latest_file" "$asc_file"

    echo "Process completed successfully!"

    sleep 5
    echo "Extracting stage3 file..."
    tar xpvf "srage3-*.tar.xz" --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo || { echo "Failed to extract"; exit 1; }
    sleep 5
    echo "Gentoo stage file setup complete."
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

    sleep 5
    sed -i "s/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g" /mnt/gentoo/etc/locale.gen
    # If dualboot uncomment below
    # sed -i "s/clock=\"UTC\"/clock=\"local\"/g" ./etc/conf.d/hwclock
    sed -i "s/keymap=\"us\"/keymaps=\"sv-latin1\"/g" /mnt/gentoo/etc/conf.d/keymaps
    echo 'LANG="en_US.UTF-8"' >> /mnt/gentoo/etc/locale.conf
    echo 'LC_COLLATE="C.UTF-8"' >> /mnt/gentoo/etc/locale.conf
    echo "Europe/Stockholm" > /mnt/gentoo/etc/timezone

}

function config_portage () {
    echo "we will now configure system"
    mkdir -p /mnt/gentoo/etc/portage/repos.conf
    cp /usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
    sleep 5

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
    sleep 5
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
