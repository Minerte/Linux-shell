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
    if ! emerge-webrsync; then
        echo "Failed to run emerge-webrsync"
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

function remerge_and_core_package () {

    # Adds cpuflag to make.conf
    echo "emerge cpuid2cpuflags"
    emerge --ask --oneshot app-portage/cpuid2cpuflags
    sleep 3
    echo "Adding flag to make.conf"
    CPU_FLAGS=$(cpuid2cpuflags | cut -d' ' -f2-)
    if grep -q "^CPU_FLAGS_X86=" /etc/portage/make.conf; then
        sed -i "s/^CPU_FLAGS_X86=.*/CPU_FLAGS_X86=\"${CPU_FLAGS}\"/" /etc/portage/make.conf  || { echo "could not add CPU_FLAGS_X86= and cpuflags to make.conf"; exit 1; }
    else
        echo "CPU_FLAGS_X86=\"${CPU_FLAGS}\"" >> /etc/portage/make.conf || { echo "could not add cpuflags to make.conf"; exit 1; }
    fi
    sleep 3
    echo "re-compiling existing package"
    sleep 3
    emerge --emptytree -a -1 @installed  || { echo "Re-compile failed check dependency and flags"; exit 1; }
    sleep 5
    echo "Cpuflags added and recompile apps"
    echo "Completted succesfully"
    sleep 3

    emerge --ask dev-lang/rust || { echo "Rust dont want to compile check dependency and flags"; exit 1; }
    sleep 3
    echo "enable system-bootstrap in /etc/portage/package.use/Rust"
    sed -i 's/\(#\)system-bootstrap/\1/' /etc/portage/package.use/Rust

    echo "emerging core packages!"
    sleep 3
    emerge --ask sys-kernel/gentoo-sources sys-kernel/genkernel sys-kernel/installkernel sys-kernel/linux-firmware \
    sys-fs/cryptsetup sys-fs/btrfs-progs sys-apps/sysvinit sys-auth/seatd sys-apps/dbus sys-apps/pciutils \
    sys-process/cronie net-misc/chrony net-misc/networkmanager app-admin/sysklogd app-shells/bash-completion \
    dev-vcs/git sys-apps/mlocate sys-block/io-scheduler-udev-rules sys-boot/efibootmgr sys-firmware/sof-firmware \
    app-editors/neovim app-arch/unzip || { echo "Could not merge! check dependency and flags (emerge core)"; exit 1; }

    echo "Core packages installed succesfully!"
    mkdir /efi/EFI/Gentoo

}

# Needs to do before kernel setup


function openrc_runtime () {

    echo "updating openrc init"
    echo "remove runtime"
    rc-service dhcpcd stop || { echo "rc-service dhcpcd stop failed"; exit 1; }
    rc-update del dhcpcd default || { echo "rc-update del dhcpcd default failed"; exit 1; }
    rc-update del hostname boot || { echo "rc-update del hostname boot failed"; exit 1; }
    sleep 3

    echo "default level"
    rc-update add dbus default || { echo "rc-update add dbus default failed"; exit 1; }
    rc-updtae add seatd default || { echo "rc-updtae add seatd default failed"; exit 1; }
    rc-update add cronie default || { echo "rc-update add cronie default failed"; exit 1; }
    rc-update add chronyd default || { echo "rc-update add chronyd default failed"; exit 1; }
    rc-update add sysklogd default || { echo "rc-update add sysklogd default failed"; exit 1; }
    rc-update add NetworkManager default || { echo "rc-update add NetworkManager default failed"; exit 1; }
    sleep 3

    echo "Editing for Networkmanager"
    rc-service NetworkManager start || { echo "Failed to start NetworkManager"; exit 1; }
    echo "Wating 5s to make sure"
    sleep 5

    get_input() {   
        local prompt="$1"
        local var
        read -rp "$prompt" var
        echo "$var"
    }

    CUSTOM_HOSTNAME=$(get_input "Enter the hostname you want to set: ")

    while true; do
        HOSTNAME_MODE=$(get_input "Choose hostname mode (dhcp/always): ")
        if [[ "$HOSTNAME_MODE" == "dhcp" || "$HOSTNAME_MODE" == "always" ]]; then
            break
        else
            echo "Invalid choice! Please enter 'dhcp' or 'always'."
        fi
    done

    nmcli general hostname "$CUSTOM_HOSTNAME" || { echo "Failed to create custom hostname"; exit 1; }
    CONFIG_DIR="/etc/NetworkManager/conf.d"
    CONFIG_FILE="$CONFIG_DIR/hostname.conf"
    mkdir -p "$CONFIG_DIR" || { echo "Failed to create directory for $CONFIG_DIR"; exit 1; }
    echo -e "[main]\nhostname=$CUSTOM_HOSTNAME" > "$CONFIG_FILE" || { echo "Failed put $CUSTOM_HOSTNAME in $CONFIG_FILE"; exit 1; }
    NM_MAIN_CONFIG="/etc/NetworkManager/NetworkManager.conf"
    touch "$NM_MAIN_CONFIG" || { echo "Failed to create file $NM_MAIN_CONFIG"; exit 1; }
    sed -i '/^hostname-mode=/d' "$NM_MAIN_CONFIG" || { echo "Failed to edit file $NM_MAIN_CONFIG"; exit 1; }

    # Add the new hostname-mode setting
    if ! grep -q "^\[main\]" "$NM_MAIN_CONFIG"; then
    echo -e "\n[main]" >> "$NM_MAIN_CONFIG"
    fi
    echo "hostname-mode=$HOSTNAME_MODE" >> "$NM_MAIN_CONFIG"

    rc-service NetworkManager restart
    echo "-------------------------------------------"
    echo "New hostname set to: $(hostnamectl hostname)"
    echo "Hostname mode set to: $HOSTNAME_MODE"
    echo "NetworkManager succesfully configured"
    echo "-------------------------------------------"

}

function config_for_session() {

    echo "Config doas"
    echo "permit persist -wheel" >> /etc/doas.conf
    chown -c root:root /etc/doas.conf
    chmod 0400 /etc/doas.conf
    echo "/etc/doas.conf permission is now set as root:root 0400"

    echo "Editing greetd config"
    sed -i "s/?/current/g" /etc/greetd/config.toml || { echo "Cant edit the file from ? to current in /etc/greetd/config.toml"; exit 1; }
    sed -i "s/agreety/tuigreet/g" /etc/greetd/config.toml || { echo "Cant edit the file from agreety to tuigreet in /etc/greetd/config.toml"; exit 1; }
    sed -i "s/\/bin\/sh/\/bin\/bash/g" /etc/greetd/config.toml || { echo "Cant edit the file from /bin/sh to /bin/bash in /etc/greetd/config.toml"; exit 1; }
    echo "Adding greetd access"
    usermod greetd -aG seat || { echo "Failed to seat group to greetd"; exit 1; }
    usermod greetd -aG video || { echo "Failed to video group to greetd"; exit 1; }
    usermod greetd -aG input || { echo "Failed to input group to greetd"; exit 1; }
    echo "---------------------------------------------------------------------------------------"
    echo "After reboot the user need to edit /etc/initab to get tuigreet to show up when booting"
    echo "c1:12345:respawn:/bin/greetd"
    echo "---------------------------------------------------------------------------------------"
    read -rp "Confirm that you have read the information (y/n): " user_input
    if [[ "$user_input" =~ ^[Nn] ]]; then
        echo "-------------------------------------------------------------------------------------"
        echo "The script will still continue so you need to search on internet how to do it later!"
        echo "-------------------------------------------------------------------------------------"
    fi
    echo "greetd config done!"
    sleep 5

    echo "Making root password"
    while true; do
        echo "Type yours password for root"
        passwd root
        if [ $? -eq 0 ]; then
            echo "Root password set successfully."
            break
        else
            echo "Failed to set root password. Please try again."
        fi
    done

    echo "Adding user"
    while tru; do
        read -rp "Enter the username: " user_acc

        if [ -z "$user_acc" ]; then
            echo "Username cannot be empty. try again."
        else
            break
        fi
    done

    useradd -m -G users,wheel,seat,disk,input,cdrom,floppy,audio,video -s /bin/bash "$user_acc"

    if [ $? -eq 0 ]; then
        echo "User $user_acc created successfully."
    else
        echo "Failed to create user $user_acc."
        exit 1
    fi

    while true; do
        echo "Setting password for $user_acc:"
        passwd "$user_acc"
        if [ $? -eq 0 ]; then
            echo "Password for $user_acc set successfully."
            break
        else
            echo "Failed to set password for $user_acc. Please try again."
        fi
    done

    echo "Config for session is now done"

}

function dracut_update() {

    echo "Updating dracut and preparing initramfs for kernel build..."
    local sel_disk="$1"
    local sel_disk_boot="$2"
    
    echo "Kernel command line generated:"
    # Set Dracut modules for encryption support
    add_dracutmodules=" crypt crypt-gpg dm rootfs-block "
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

    lsblk -o NAME,UUID
    echo "$kernel_cmdline will be added to /etc/dracut.conf"
    read -rp "Does the kernel_cmdline+= to /etc/dracut.conf look right? (y/n): " user_input
    if [[ "$user_input" =~ ^[Nn] ]]; then
        echo "Exiting..."
        exit 1
    fi
    echo "kernel_cmdline+=\"$kernel_cmdline\"" >> /etc/dracut.conf || { echo "Failed to mobe kernel_cmdline to /etc/dracut.conf"; exit 1; }
    echo "add_dracutmodules+=\"$add_dracutmodules\"" >> /etc/dracut.conf || { echo "Failed to mobe add_dracutmodules to /etc/dracut.conf"; exit 1; }
    sleep 3
    dracut -v

}

function kernel () {

    echo "---------------------------------------------------------"
    echo "You need to activate support for initramfs sourc file(s)"
    echo "Please read the wiki or Readme.md"
    echo "---------------------------------------------------------"
    echo "This will start a session that user can edit the kernel"
    echo "the flags use in the config is:"
    echo "--luks --gpg --btrfs --keymap --oldconfig --save-config --menuconfig --install all"
    sleep 10
    genkernel --luks --gpg --btrfs --keymap --oldconfig --save-config --menuconfig --install all || { echo "Could not start/install genkernel"; exit 1; }
    sleep 5
    echo "kernel completed"
    
}

function config_boot() {

    echo "copy /boot/kernel-* and /boot/initramfs to /efi/EFI/Gentoo"
    cp /boot/kernel-* /efi/EFI/Gentoo/bzImage.efi
    cp /boot/initramfs-* /efi/EFI/Gentoo/initramfs.img

    echo "Configuring key to boot using /efi only"
    local sel_disk="$1"
    local sel_disk_boot="$2"

    SWAP_UUID=$(blkid "${sel_disk}1" -o value -s UUID)
    ROOT_UUID=$(blkid "${sel_disk}2" -o value -s UUID)
    BOOT_KEY_UUID=$(blkid "${sel_disk_boot}2" -o value -s UUID)

    # Ensure UUIDs are retrieved successfully
    if [[ -z "$SWAP_UUID" || -z "$ROOT_UUID" || -z "$BOOT_KEY_UUID" ]]; then
        echo "Error: Missing one or more UUIDs. Ensure disks are properly configured."
        exit 1
    fi
    sleep 3

    # Create EFI boot entry (using UUID for Boot Key Partition)
    efibootmgr --create --disk "$sel_disk_boot" --part 1 \
    --label "Gentoo" \
    --loader '\\EFI\\Gentoo\\bzImage.efi' \
    --unicode "root=UUID=$ROOT_UUID initrd=\\EFI\\Gentoo\\initramfs.img rd.luks.key=UUID=$BOOT_KEY_UUID:/luks-keyfile.gpg:gpg rd.luks.allow-discards rd.luks.uuid=$SWAP_UUID rd.luks.key=UUID=$BOOT_KEY_UUID:/swap-keyfile.gpg:gpg"

    if [[ $? -eq 0 ]]; then
        echo "EFI boot entry created successfully."
    else
        echo "Error: Failed to create EFI boot entry."
        exit 1
    fi
    sleep 3

    efibootmgr || { echo "Could not create boot entry"; exit 1; }
    read -rp "Does the efibootmgr look right? (y/n): " user_input
    if [[ "$user_input" =~ ^[Nn] ]]; then
        echo "Exiting..."
        exit 1
    fi
    sleep 3

    ls -lh /efi/EFI/Gentoo/
    read -rp "Does the /efi/EFI/Gentoo look right? (y/n): " user_input
    if [[ "$user_input" =~ ^[Nn] ]]; then
        echo "Exiting..."
        exit 1
    fi
    sleep 3

}

echo "!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "! Now you are in chroot. !"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!"
sleep 5

lsblk
read -r -p "Enter the Boot disk (e.g., /dev/sda): " selected_disk_Boot
read -r -p "Enter the Root disk (e.g., /dev/sda): " selected_disk
validate_block_device "$selected_disk_Boot" "$selected_disk"
chroot_first "$selected_disk_Boot"
remerge_and_core_package
openrc_runtime
config_for_session
dracut_update "$selected_disk" "$selected_disk_Boot"
kernel
config_boot "$selected_disk" "$selected_disk_Boot"
