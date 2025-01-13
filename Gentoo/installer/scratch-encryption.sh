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
    mkfs.vfat -F32 "${sel_disk_boot}1"
    mkfs.ext4 "${sel_disk_boot}2"
    mkdir -p /media/extern-usb || { echo "Failed to create directory in /media/..."; exit 1; }
    mount "${sel_disk_boot}2" /media/extern-usb || { echo "Failed to mount ${sel_disk_boot}2 to /media/extern-usb"; exit 1; }

    # SETUP MAIN DISK FOR USABLE DRIVE
    # Encrypting swap parition
    cryptsetup open --type plain --cipher aes-xts-plain64 --key-size 512 --key-file /dev/urandom "${sel_disk}1" cryptswap || { echo "Failed to encypt swap partition"; exit 1; }
    mkswap /dev/mapper/cryptswap || { echo "Failed to create swap"; exit 1; }
    swapon /dev/mapper/cryptswap || { echo "Failed to swapon"; exit 1; }

    # Making keyfile
    gpg --decrypt crypt_key.luks.gpg | cryptsetup luksFormat --header /media/extern-usb/luks_header.img --key-file - --key-size 512 --cipher aes-xts-plain64 "${sel_disk}2" || { echo "Failed  to decrypt keyfil and encrypt diskt"; exit 1; }
    cryptsetup luksHeaderBackup "${sel_disk}2" --header-backup-file crypt_headers.img || { echo "Failed to make a LuksHeader backup"; exit 1;}
    gpg --decrypt crypt_key.luks.gpg | cryptsetup --key-file - open "${sel_disk}2" cryptroot || { echo "Failed to decrypt and open disk ${sel_disk}2 "; exit 1;}

    # SETUP BOOT DISK
    mkfs.vfat -F32 "${sel_disk_boot}1"
    mkfs.ext4 "${sel_disk_boot}2"

    # Root partition setup
    mkdir -p /mnt/root || { echo "Failed to create directory"; exit 1; }
    mkfs.btrfs -L BTROOT /dev/mapper/cryptroot 
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
