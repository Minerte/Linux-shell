#!/bin/bash

Kernel() {
  while true; do
    echo "Listing available kernel versions in /usr/src/:"
    kernels=($(ls -d /usr/src/linux-*-gentoo 2>/dev/null))
    
    # Check if any kernels are found
    if [ ${#kernels[@]} -eq 0 ]; then
      echo "No kernel versions found in directory /usr/src/"
      read -rp "Do you want to install a kernel source? (y/n): " choice
      if [[ "$choice" =~ ^[Yy] ]]; then
        echo "Emerging sys-kernel/gentoo-sources..."
        emerge --ask sys-kernel/gentoo-sources
        continue
      else
        echo "Exiting script. No kernel sources available."
        exit 1
      fi
    fi

    # List available kernels
    for i in "${!kernels[@]}"; do
      kernel_dir="${kernels[$i]}"
      kernel_version=$(basename "$kernel_dir" | sed 's/^linux-//; s/-gentoo.*//')
      echo "$((i + 1)). $kernel_version"
    done

    # Prompt user to select a kernel
    read -rp "Please enter the number of the kernel version you want to use (e.g., 1): " kernel_choice
    if [[ ! $kernel_choice =~ ^[0-9]+$ ]] || ((kernel_choice < 1 || kernel_choice > ${#kernels[@]})); then
      echo "Error: Invalid selection. Please try again."
      continue
    fi

    # Set the selected kernel directory and version
    kernel_dir="${kernels[$((kernel_choice - 1))]}"
    kernel_version=$(basename "$kernel_dir" | sed 's/^linux-//; s/-gentoo.*//')

    # Verify the kernel directory exists
    if [[ ! -d "$kernel_dir" ]]; then
      echo "Error: Kernel directory for version $kernel_version is missing in /usr/src/."
      read -rp "Do you want to retry compiling the kernel source? (y/n): " choice
      if [[ "$choice" =~ ^[Yy] ]]; then
        echo "Emerging sys-kernel/gentoo-sources..."
        emerge --ask sys-kernel/gentoo-sources
        continue
      else
        echo "Exiting script. Kernel directory is missing."
        exit 1
      fi
    fi

    break # If kernel is valid, proceed
  done

  # Navigate to the kernel source directory
  cd "$kernel_dir" || { echo "Error: Failed to enter kernel directory."; exit 1; }

  # Check if an existing config file is present
  if [[ -f .config ]]; then
    echo "Merging old and new kernel configurations..."
    cp .config .config.old  # Backup old config
    mv /tmp/.config .config.new  # Rename new config
    make oldconfig KCONFIG_CONFIG=.config.new  # Merge with new config
    mv .config.new .config  # Replace old config with merged one
  else
    echo "Warning: No existing .config file found in $kernel_dir. Using the new one."
    mv /tmp/.config .config
  fi

  echo 'Change back to "main" directory'
  cd / || { echo "Failed to change / directory"; exit 1;}
  # Run genkernel with the selected kernel
  echo "Building kernel $kernel_version with genkernel..."
  genkernel --oldconfig --luks --btrfs --firmware --keymap --no-splash --save-config --menuconfig --install all
}
