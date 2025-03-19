#!/bin/bash

swap-no-or-yes() {
  FSTAB_FILE="/mnt/gentoo/etc/fstab"

  # Entry to add if swap is detected
  CRYPTSWAP_ENTRY="/dev/mapper/cryptswap      none    swap    sw    0 0"

  # Check if swap is enabled
  echo "Checking for swap partitions..."

  # Use swapon to check active swap devices
  swap_info=$(swapon --show)

  if [ -z "$swap_info" ]; then
    echo "No active swap partition or file found."
    echo "No changes will be made to $FSTAB_FILE."
  else
    echo "Swap partition or file found:"
    echo "$swap_info"

    # Check if the cryptswap entry already exists in fstab
    if grep -q "/dev/mapper/cryptswap" "$FSTAB_FILE"; then
      echo "The cryptswap entry already exists in $FSTAB_FILE. No changes needed."
      else
        echo "Adding cryptswap entry to $FSTAB_FILE..."
        echo "$CRYPTSWAP_ENTRY" | tee -a "$FSTAB_FILE" > /dev/null
        echo "Cryptswap entry added successfully."
      fi
  fi
}
