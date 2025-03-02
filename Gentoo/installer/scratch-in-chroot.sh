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

    mkdir -p /efi/EFI/Gentoo || { echo "Could not create /EFI/Gentoo in /efi directory"; exit 1; }
    lsblk
    ls -a /efi
        read -rp "is ${sel_disk_boot}1 mounted to /efi. And do you have /efi/EFI/Gentoo (y/n): " user_input
    if [[ "$user_input" =~ ^[Nn] ]]; then
        echo "Exiting..."
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
    emerge --oneshot app-portage/cpuid2cpuflags
    sleep 3
    echo "Adding flag to make.conf"
    CPU_FLAGS=$(cpuid2cpuflags | cut -d' ' -f2-)
    if grep -q "^CPU_FLAGS_X86=" /etc/portage/make.conf; then
        sed -i "s/^CPU_FLAGS_X86=.*/CPU_FLAGS_X86=\"${CPU_FLAGS}\"/" /etc/portage/make.conf  || { echo "could not add CPU_FLAGS_X86= and cpuflags to make.conf"; exit 1; }
        echo "cpuid2cpuflags added succesfully to make.conf"
    else
        echo "CPU_FLAGS_X86=\"${CPU_FLAGS}\"" >> /etc/portage/make.conf || { echo "could not add cpuflags to make.conf"; exit 1; }
    fi

    sleep 3
    echo "re-compiling existing package"
    sleep 3
    while true; do
        emerge --emptytree -a -1 @installed

        if [[ $? -eq 0 ]]; then
            echo "Recompilation completed successfully!"
            break
        else
            echo "Re-compile failed! Check dependencies and flags."
            echo "You are now in the chroot environment. Fix any issues, then type 'retry' to try again."

            while true; do
                read -rp "Type 'retry' to rerun emerge or 'exit' to leave: " input
                case $input in
                    retry)
                        break
                        ;;
                    exit)
                        echo "Exiting chroot recompile script."
                        exit 1
                        ;;
                    *)
                        echo "Invalid input. Type 'retry' to retry or 'exit' to quit."
                        ;;
                esac
            done
        fi
    done

    sleep 5
    echo "Completted succesfully"
    sleep 3
    emerge dev-lang/rust || { echo "Rust dont want to compile check dependency and flags"; exit 1; }
    sleep 3
    echo "enable system-bootstrap in /etc/portage/package.use/Rust"
    sed -i 's/\(#\)system-bootstrap/\1/' /etc/portage/package.use/Rust
    echo "emerging core packages!"
    sleep 3

    while true; do
        emerge sys-kernel/gentoo-sources sys-kernel/genkernel sys-kernel/installkernel sys-kernel/linux-firmware \
            sys-fs/cryptsetup sys-fs/btrfs-progs sys-apps/sysvinit sys-auth/seatd sys-apps/dbus sys-apps/pciutils \
            sys-process/cronie net-misc/chrony net-misc/networkmanager app-admin/sysklogd app-shells/bash-completion \
            dev-vcs/git sys-apps/mlocate sys-block/io-scheduler-udev-rules sys-boot/efibootmgr sys-firmware/sof-firmware \
            app-editors/neovim app-arch/unzip

        if [[ $? -eq 0 ]]; then
            echo "Core packages installed successfully!"
            break
        else
            echo "Could not merge! Check dependencies and flags."
            echo "You are now in the chroot environment. Fix any issues, then type 'retry' to try again."
        
            while true; do
                read -rp "Type 'retry' to rerun emerge or 'exit' to leave: " input
                case $input in
                    retry)
                        break
                        ;;
                    exit)
                        echo "Exiting chroot install script."
                        exit 1
                        ;;
                    *)
                        echo "Invalid input. Type 'retry' to retry or 'exit' to quit."
                        ;;
                esac
            done
        fi
    done

}

function openrc_runtime () {

    echo "updating openrc init"
    echo "remove runtime"
    rc-service dhcpcd stop || { echo "rc-service dhcpcd stop failed"; exit 1; }
    rc-update del hostname boot || { echo "rc-update del hostname boot failed"; exit 1; }
    sleep 3

    echo "default level"
    rc-update add dbus default || { echo "rc-update add dbus default failed"; exit 1; }
    rc-update add seatd default || { echo "rc-updtae add seatd default failed"; exit 1; }
    rc-update add cronie default || { echo "rc-update add cronie default failed"; exit 1; }
    rc-update add chronyd default || { echo "rc-update add chronyd default failed"; exit 1; }
    rc-update add sysklogd default || { echo "rc-update add sysklogd default failed"; exit 1; }
    rc-update add NetworkManager default || { echo "rc-update add NetworkManager default failed"; exit 1; }
    sleep 3

    echo "Editing for Networkmanager"
    rc-service NetworkManager start
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
    echo "New hostname set to: $CUSTOM_HOSTNAME"
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
    while true; do
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

function kernel () {

    echo "-----------------------------------------------------------------------------------"
    echo "You need to activate support for initramfs source file(s)"
    echo "Please read the wiki or Readme.md"
    echo "-----------------------------------------------------------------------------------"
    echo "This will start a session that user can edit the kernel"
    echo "the flags use in the config is:"
    echo "--luks --gpg --firmware --btrfs --keymap --oldconfig --save-config --menuconfig --install all"
    echo "-----------------------------------------------------------------------------------"
    sleep 10
    echo "Starting genkernel with the specified flags..."
    sleep 5
    genkernel --luks --gpg --firmware --btrfs --keymap --oldconfig --save-config --menuconfig --install all || { echo "ERROR: Could not start/install genkernel"; exit 1; }

    sleep 5
    echo "Kernel build completed"

}

function dracut_update() {
    echo "Updating dracut and preparing initramfs for kernel build..."
    local sel_disk="$1"
    local sel_disk_boot="$2"
    
    echo "Kernel command line generated:"
    # Set Dracut modules for encryption support
    add_dracutmodules=" crypt crypt-gpg dm rootfs-block btrfs "
    install_items=" /usr/bin/gpg "
    kernel_cmdline=""

    swapuuid=$(blkid "${sel_disk}1" -o value -s UUID)
    rootuuid=$(blkid "${sel_disk}2" -o value -s UUID)
    boot_key_uuid=$(blkid "${sel_disk_boot}2" -o value -s UUID)
    if [[ -z "$swapuuid" || -z "$rootuuid" || -z "$boot_key_uuid" ]]; then
        echo "Error: Missing one or more UUIDs. Ensure disks are properly configured."
        exit 1
    fi

    # Retrieve the root partition label
    rootlabel=$(blkid "${sel_disk}2" -o value -s LABEL)
    if [ -z "$rootlabel" ]; then
        echo "No LABEL found for ${sel_disk}2 (ROOT)"
        read -rp "Please enter a LABEL for the root partition (or press Enter to use UUID instead): " rootlabel
        if [ -z "$rootlabel" ]; then
            echo "No LABEL provided. Falling back to UUID."
            kernel_cmdline+=" root=UUID=$rootuuid rootflags=subvol=activeroot"
        else
            kernel_cmdline+=" root=LABEL=$rootlabel rootflags=subvol=activeroot"
            echo "The root LABEL is set to: $rootlabel"
        fi
    else
        kernel_cmdline+=" root=LABEL=$rootlabel rootflags=subvol=activeroot"
        echo "The root LABEL is set to: $rootlabel"
    fi

    kernel_cmdline+=" rd.luks.uuid=$rootuuid rd.luks.name=$rootuuid=cryptroot"
    kernel_cmdline+=" rd.luks.key=/luks-keyfile.gpg:UUID=$boot_key_uuid"
    kernel_cmdline+=" rd.luks.allow-discards"
    kernel_cmdline+=" rd.luks.uuid=$swapuuid rd.luks.name=$swapuuid=cryptswap"
    kernel_cmdline+=" rd.luks.key=/swap-keyfile.gpg:UUID=$boot_key_uuid "

    lsblk -o NAME,UUID
    echo "$kernel_cmdline will be added to /etc/dracut.conf"
    read -rp "Does the kernel_cmdline look right? (y/n): " user_input
    if [[ "$user_input" =~ ^[Nn] ]]; then
        echo "Exiting..."
        exit 1
    fi

    grep -q "^kernel_cmdline+=\"$kernel_cmdline\"" /etc/dracut.conf || echo "kernel_cmdline+=\"$kernel_cmdline\"" >> /etc/dracut.conf
    grep -q "^add_dracutmodules+=\"$add_dracutmodules\"" /etc/dracut.conf || echo "add_dracutmodules+=\"$add_dracutmodules\"" >> /etc/dracut.conf
    grep -q "^install_items+=\"$install_items\"" /etc/dracut.conf || echo "install_items+=\"$install_items\"" >> /etc/dracut.conf
    # Regenerate initramfs
    while true; do
        dracut -f -v
        sleep 3

        read -rp "Were there any warnings from 'dracut -f -v'? (y/n): " user_input
        case $user_input in
            [Nn]) 
                echo "No warnings detected. Exiting loop."
                break
                ;;
            [Yy]) 
                echo "Warnings detected! Fix any issues, then type 'retry' to run dracut again."
                ;;
            retry)
                echo "Retrying dracut..."
                continue
                ;;
            exit)
                echo "Exiting script."
                exit 1
                ;;
            *)
                echo "Invalid input. Type 'y' if there were warnings, 'n' if everything is fine, 'retry' to run dracut again, or 'exit' to quit."
                ;;
        esac
    done
    # Verify initramfs contents
    while true; do
        if lsinitrd /boot/initramfs-*.img | grep -E "btrfs|crypt|gpg"; then
            read -rp "Does the initramfs have btrfs, crypt, and gpg support? (y/n): " user_input
            if [[ "$user_input" =~ ^[Yy] ]]; then
                echo "Great! Exiting loop."
                break
            else
                echo "Fix any issues and try again."
            fi
        else
            echo "Initramfs is missing btrfs, crypt, or gpg support. Please fix the issue and try again."
        fi
    done
}

function config_boot() {

    echo "copy /boot/kernel-* and /boot/initramfs to /efi/EFI/Gentoo"
    if cp /boot/kernel-* /efi/EFI/Gentoo/bzImage.efi; then
        echo "Successfully copied kernel-* to /efi/EFI/Gentoo/bzImage.efi"
    else
        echo "Failed to copy kernel-*, trying vmlinuz-* or bzImage-*..."
        if cp /boot/vmlinuz-* /efi/EFI/Gentoo/bzImage.efi; then
            echo "Successfully copied vmlinuz-* to /efi/EFI/Gentoo/bzImage.efi"
        else
            if cp /boot/bzImage-* /efi/EFI/Gentoo/bzImage.efi; then
                echo "Successfully copied bzImage-* to /efi/EFI/Gentoo/bzImage.efi"
            else
                echo "Failed to copy kernel (kernel-*, vmlinuz-*, or bzImage-*) to /efi/EFI/Gentoo/bzImage.efi"
                exit 1
            fi
        fi
    fi

    # Copy the latest initramfs file
    if cp "$(ls -1t /boot/initramfs-* | head -n 1)" /efi/EFI/Gentoo/initramfs.img; then
        echo "Successfully copied the latest initramfs to /efi/EFI/Gentoo/initramfs.img"
    else
        echo "Failed to copy initramfs to /efi/EFI/Gentoo/initramfs.img"
        exit 1
    fi
    echo "All files copied successfully!"

    echo "Configuring key to boot using /efi only"
    local sel_disk="$1"
    local sel_disk_boot="$2"

    swapuuid=$(blkid "${sel_disk}1" -o value -s UUID)
    rootuuid=$(blkid "${sel_disk}2" -o value -s UUID)
    boot_key_uuid=$(blkid "${sel_disk_boot}2" -o value -s UUID)
    rootlabel=$(blkid "${sel_disk}2" -o value -s LABEL)
    if [[ -z "$rootlabel" ]]; then
        echo "No LABEL found for the root partition (${sel_disk}2)."
        read -rp "Please enter a LABEL for the root partition: " rootlabel
        if [[ -z "$rootlabel" ]]; then
            echo "No LABEL provided. Exiting..."
            exit 1
        fi
    else
        echo "The root LABEL is set to: $rootlabel"
    fi

    # Ensure UUIDs are retrieved successfully
    if [[ -z "$swapuuid" || -z "$rootuuid" || -z "$boot_key_uuid" ]]; then
        echo "Error: Missing one or more UUIDs. Ensure disks are properly configured."
        exit 1
    fi
    sleep 3

    while true; do
        # Create the EFI boot entry
        efibootmgr --create --disk "$sel_disk_boot" --part 1 \
            --label "Gentoo" \
            --loader "\EFI\Gentoo\bzImage.efi" \
            --unicode "initrd=\EFI\Gentoo\initramfs.img \
            root=LABEL=$rootlabel \
            rootflags=subvol=activeroot \
            rd.luks.uuid=$rootuuid rd.luks.name=$rootuuid=cryptroot \
            rd.luks.key=UUID=$boot_key_uuid:/luks-keyfile.gpg:gpg \
            rd.luks.allow-discards \
            rd.luks.uuid=$swapuuid rd.luks.name=$swapuuid=cryptswap \
            rd.luks.key=UUID=$boot_key_uuid:/swap-keyfile.gpg:gpg"

        if [[ $? -eq 0 ]]; then
            echo "EFI boot entry created successfully."
        else
            echo "Error: Failed to create EFI boot entry."
            exit 1
        fi

        # Display the boot entries for review
        echo "Current boot entries:"
        efibootmgr -v
        read -rp "Does the efibootmgr look right? (y/n): " user_input
        if [[ "$user_input" =~ ^[Nn] ]]; then
            echo "Boot entry does not look right. Please fix the issue and try again."
            continue  # Restart the loop
        fi

        # Display the contents of /efi/EFI/Gentoo/ for review
        echo "Contents of /efi/EFI/Gentoo/:"
        ls -lh /efi/EFI/Gentoo/
        read -rp "Does the /efi/EFI/Gentoo look right? (y/n): " user_input
        if [[ "$user_input" =~ ^[Nn] ]]; then
            echo "Contents of /efi/EFI/Gentoo/ do not look right. Please fix the issue and try again."
            continue  # Restart the loop
        fi

        # If everything looks good, break out of the loop
        echo "Boot entry and /efi/EFI/Gentoo/ look correct. Proceeding..."
        break
    done

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
kernel
dracut_update "$selected_disk" "$selected_disk_Boot"
config_boot "$selected_disk" "$selected_disk_Boot"
echo "everything works it seams. You can start to umount and reboot!"
echo "yeay"
