#!/bin/bash

# Ensure the script runs as root
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root"
  exit 1
fi 

source /etc/profile
export PS1="(chroot) ${PS1}"

source /Chroot-sync/chroot-first.sh
source /Chroot-sync/Openrc-runtime.sh
source /emerge/recompile.sh
source /kernel/kernel-compile.sh
source /kernel/Finish.sh

validate_block_device() {
  local boot_disk="$1"
  local root_disk="$2"

  if [[ ! -b "$boot_disk" ]]; then
    echo "Error: $boot_disk is not a valid block device."
    exit 1
  fi

  if [[ ! -b "$root_disk" ]]; then
    echo "Error: $root_disk is not a valid block device."
    exit 1
  fi

  echo "Valid block devices selected: Boot = $boot_disk, Root = $root_disk"
}

Step_1() {
  local boot_disk="$1"

  First "$boot_disk"
  cpu_to_flags
  system-emptytree
  system-packages
}

Step_2() {
  local root_disk="$1"
  local boot_disk="$2"
  Kernel
  dracut_update_and_EFIstub "$root_disk" "$boot_disk"
}

Step_3() {
  echo "Config for session"
  openrc_runtime
  config_for_session
}

lsblk -d -n -o NAME,SIZE,UUID,LABEL | awk '{print "/dev/" $1 " - " $2}'
while true; do
  read -rp "Select the Boot drive: " selected_boot_disk
  read -rp "Select the Root drive: " selected_root_disk
  if validate_block_device "$selected_root_disk" "$selected_boot_disk"; then
    break
  else
    echo "Please try again"
  fi
done

Step_1 "$selected_boot_disk"
Step_2 "$selected_root_disk" "$selected_boot_disk"
Step_3

echo "IMPORTANT: Before rebooting:"
echo "1. Edit /media/keydrive/passphrase.txt with your GPG passphrase"
echo "2. Verify keyfiles exist at:"
echo "   - /media/keydrive/swap-keyfile.gpg"
echo "   - /media/keydrive/root-keyfile.gpg"
echo "3. Test decryption manually with:"
echo "   chroot /mnt /usr/lib/dracut/modules.d/90gpgdecrypt/gpgdecrypt.sh"
echo "After verification, you can reboot."