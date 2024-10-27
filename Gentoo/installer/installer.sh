#!/bin/bash

# List avalibale disk
function list_disks() {
    echo "Avalible disks:"
    lsblk -d -n -o NAME,SIZE | awk '{print "/dev/" $1 " - " $2}'
}

# Find UUID on selected disk
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
    echo "This script will not umount and reboot the system automaticlly after it is done"
    local sel_disk="$1"
    local boot_size="$2"
    local crypt_name="cryptroot"

    read -r -p "You are about to format the SELECTED disk: $sel_disk. Are you sure? (y/n) " confirm
    if [[ "$confirm" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi

    # Using parted for disk partion
    echo "Ready to format selected disk $sel_disk..."
    echo "It will create 1G efi and rest of the disk is root"
    parted  --script "$sel_disk" \
        mklabel gpt \
        mkpart boot fat32 0% "${boot_size}G" \
        mkpart root btrfs "${boot_size}G" 100% \
        set 1 boot on \
        p \
        q \
    || exit

    # Foramtting boot/efi pratition
    echo "Formatting boot pratition"
    mkfs.vfat -F 32 "${sel_disk}1"

    # Encryption on second partition
    echo "Disk encryption for second partition"
    cryptsetup luksFormat -s 512 -c aes-xts-plain64 "${sel_disk}2"
    cryptsetup luksOpen "${sel_disk}2" $crypt_name
    # Will make btrfs and mount it in /mnt/root
    mkdir /mnt/root
    mkfs.btrfs -L BTROOT /dev/mapper/$crypt_name
    mount -t btrfs -o defaults,noatime,compress=lzo /dev/mapper/$crypt_name /mnt/root/
    # Creating subvolume
    btrfs subvolume create /mnt/root/activeroot
    btrfs subvolume create /mnt/root/home

    mkdir -p /mnt/gentoo/home || exit
    mkdir -p /mnt/gentoo/efi || exit

    # /mnt/gentoo coming from wiki where root is suppose to be mounted
    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=activeroot /dev/mapper/$crypt_name /mnt/gentoo
    mount -t btrfs -o defaults,noatime,compress=lzo,subvol=home /dev/mapper/$crypt_name /mnt/gentoo/home
    sleep  30

    # EFI
    mount /dev/"${sel_disk}1" /mnt/gentoo/efi/
    # Boot
    # mount /dev/"${sel_disk}1" /mnt/gentoo/boot/
    
    echo "Disk $sel_disk configure with boot (EFI), encrypted root and home"
}

function setup_stagefile () {
    echo "This will download stage 3 file from gentoo and verify it"
    # Gentoo stage files and verify
    wget https://distfiles.gentoo.org/releases/amd64/autobuilds/20241020T170324Z/stage3-amd64-hardened-openrc-20241020T170324Z.tar.xz # Add latest version of set build at the end
    wget https://distfiles.gentoo.org/releases/amd64/autobuilds/20241020T170324Z/stage3-amd64-hardened-openrc-20241020T170324Z.tar.xz.asc # Add latest version of set build.asc at the end

    gpg --import /usr/share/openpgp-keys/gentoo-release.asc
    gpg --verify ./stage3-*.tar.xz.asc

    sleep 3

    mv ~./stage3-*.tar.xz /mnt/gentoo
    cd /mnt/gentoo || exit

    tar tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

    sleep 3

    echo "Will change some basic config"
    sed -i "s/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g" ./etc/locale.gen
    sed -i "s/clock=\"UTC\"/clock=\"local\"/g" ./etc/conf.d/hwclock
    sed -i "s/keymap=\"us\"/keymaps=\"sv-latin1\"/g" ./etc/conf.d/keymaps

    echo 'LANG="en_US.UTF-8"' >> ./etc/locale.conf
    echo 'LC_COLLATE="C.UTF-8"' >> ./etc/locale.conf
    echo "Europe/Stockholm" > ./etc/timezone
}

function setup_config () {
    echo "We will configuer fstab and grub"
    #Upadteing ./etc/fstab
    local efi_uuid
    efi_uuid=$(find_uuid "${sel_disk}1")
    echo "LABEL=BTROOT  /       btrfs   defaults,noatime,compress=lzo,subvol=activeroot 0 0" | tee -a ./etc/fstab
    echo "LABEL=BTROOT  /home   btrfs   defaults,noatime,compress=lzo,subvol=home       0 0" | tee -a ./etc/fstab
    echo "UUID=$efi_uuid    /efi    vfat    umask=077   0 2" | tee -a ./etc/fstab
    # echo "UUID=$efi_uuid  /boot    vfat    umask=077   0 2" | tee -a /etc/fstab
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

function setup_portage () {
    echo "This will setup the correct portage" # arguments are accessible through $1, $2,...
    mkdir ./etc/portage/repos.conf
    cp ./usr/share/portage/config/repos.conf ./etc/portage/repos.conf/gentoo.conf
    # Copies network into Chroot
    cp /etc/resolve.conf /mnt/gentoo/etc/

    sleep 10

    # portgae file from github
    mkdir ./etc/portage/env
    mv ~/root/Linux-bash-shell/Gentoo/portage/make.conf ./etc/portage/
    mv ~/root/Linux-bash-shell/Gentoo/portage/package.env ./etc/portage/
    mv ~/root/Linux-bash-shell/Gentoo/portage/env/no-lto ./etc/portage/env/
    mv ~/root/Linux-bash-shell/Gentoo/portage/package.accept.keywords/tui ./etc/portage/package.acccept.keywords/
    mv ~/root/Linux-bash-shell/Gentoo/portage/package.use/* ./etc/portage/package.use/
}

function setup_chroot () {

    echo "Setting upp chroot"
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-slave /mnt/gentoo/run

    chroot /mnt/gentoo /bin/bash
    source /etc/profile
    export PS1="(chroot) ${PS1}"

    emerge-webrsync
    emerge --sync --quiet
    emerge --config sys-libs/timezone-data

    locale-gen
    env-update && source /etc/profile && export PS1="(chroot) ${PS1}"
}

function setup_in_chroot () {
    local hostname="$1"
    local username="$2"
    echo "You are now inside chroot"
    emerge --ask app-portaage/cpuid2cpuflags
    sed -i "s|^CPU_FLAGS_X86=\"cpuid2cpuflags\"|CPU_FLAGS_X86=\"$cpuid2cpuflags\"|" /etc/portage/make.conf
    sed -i "s|^MAKEOPTS=\"-j[THREADS] -l[THREADS]\"|MAKEOPTS=\"-j16 -l16\"|" /etc/portage/make.conf
    nano /etc/portage/make.conf
    # to confirm if the input from sed is right!
    # if not correct correct it with use of antoher tty
    
    # Now we need to recompile the whole system from stage 3 files
    emerge --emptytree -a -1 @installed
    emerge dev-lang/rust

    sed -i "s/#system-bootstrap/system-bootstrap/g" /etc/portage/package.use/Rust
    nano /etc/portage/package.use/Rust
    # After that install base packages
    emerge --ask sys-kernel/gentoo-source sys-kernel/genkernel sys-kernel/installkernel sys-kernel/linux-firmware \
    sys-fs/cryptsetup sys-fs/btrfs-progs sys-block/parted sys-boot/grub sys-apps/sysvinit sys-auth/seatd sys-apps/dbus \
    sys-apps/pciutils sys-process/cronie net-misc/chrony net-misc/networkmanager app-admin/sysklogd app-admin/doas \
    app-shells/bash-completion dev-vcs/git gui-libs/greetd gui-apps/tuigreet app-editors/neovim sys-apps/mlocate \
    sys-block/io-scheduler-udev-rules

    echo "permit :wheel" | tee -a /etc/doas.conf

    chown -c root:root /etc/doas.conf
    # If user want tot make doas.conf read only remove the comment
    # chmod -c 0400 /etc/doas.conf

    #configer greetd
    sed -i "s/vt  = \?\/vt = \corrent\/g" /etc/greetd/config.toml
    sed -i "s/command = \"agreety --cmd /bin/sh\"/command = \"tuigreet --cmd /bin/bash -t\"/g" /etc/greetd/config.toml
    usermod greetd -aG video
    usermod greetd -aG input
    usermod greetd -aG seat

    sed -i "s/c2:2345:respawn:/sbin/agetty 384000 tty2 linux/c2:2345:respawn:/bin/greetd/g" /etc/inittab

    rc-update add seatd boot & rc-update add dbus boot
    rc-update add NetworkManager default & rc-update add sysklogd default & rc-update add chronyd default
    rc-update add cornie default

    rc-update delete hostname boot
    rc-service NetworkManager start
    nmcli general hostname "$hostname" # change mega-test to you hotname
    nmcli general hostname

    passwd # Root password

    useradd "$username"
    passwd "$username"
    usermod "$username" -aG users,wheel,video,audio,input,disk,floopy,cdrom,seat
}

function setup_kernel () {
    echo "time for kernel config"
    eselect kernel set 1
    genkernel --luks --btrfs --keymap --oldconfig --save-config --menuconfig --install all
}

function setup_grub () {
    echo "GRUB"
    grub-install --target=x86_64-efi --efi-directory=/efi
    grub-mkconfig -o /boot/grub/grub.cfg

    echo "This script will not umount and reboot the system automaticlly after it is done"
    echo "If user want to do more suff after grub is done user can"
}

# Ensure the script is run as root
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root!"
  exit 1
fi
# Main script execution
list_disks
# Prompt user for disk selection
read -r -p "Enter the disk you want to format (e.g., /dev/sdb): " selected_disk
# Validate user input
if [[ ! -b "$selected_disk" ]]; then
    echo "Error: $selected_disk is not a valid block device."
    exit 1
fi
# Prompt user for boot partition size
read -r -p "Enter the size of the boot partition in GB (e.g., 1 for 1GB): " boot_size

# Call the function to format and mount the disk
setup_partitions "$selected_disk" "$boot_size" "$crypt_name" && setup_stagefile && setup_config && setup_portage && setup_chroot

read -r -p "Enter the username for the new user: " hostname
# Check if the username is empty
if [[ -z "$hostname" ]]; then
    echo "Error: Username cannot be empty."
    exit 1
fi
#
read -r -p "Enter the username for the new user: " username
# Check if the username is empty
if [[ -z "$username" ]]; then
    echo "Error: Username cannot be empty."
    exit 1
fi
# Entering chroot
setup_in_chroot "$hostname" "$username" && setup_kernel && setup-grub
