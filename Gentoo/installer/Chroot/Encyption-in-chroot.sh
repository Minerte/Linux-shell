#!/bin/bash

# Ensure the script runs as root
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root"
  exit 1
fi 

for dir in ~/kernel ~/emerge ~/Chroot-sync; do
  for script in "$dir"/*; do
    if [[ -f "$script" ]]; then
      chmod +x "$script"
      source "$script"
    fi
  done
done

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
  openrc_runtime
  config_for_session
}

Step_2() {
  local root_disk="$1"
  local boot_disk="$2"
  dracut_update_and_EFIstub "$root_disk" "$boot_disk"
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
system-emptytree
system-packages
kernel_compile
Step_2 "$selected_root_disk" "$selected_boot_disk"
