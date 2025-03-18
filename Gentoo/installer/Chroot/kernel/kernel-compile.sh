#!/bin/bash

Kernel() {
  while true; do 
    echo "listing avalable kernel versions in /usr/src/:"
    kernels=($(ls -d /usr/src/linux-*-gentoo-*-/ 2>/dev/null))
    if [ ${#kernels[@]} -eq 0 ]; then
      echo "No kernel version found in directory /usr/src/"
      continue
    fi
    for i in "${!kernels[@]}"; do
      kernel_dir="${kernels[$i]}"
      kernel_version=$(basename "$kernel_dir" | sed 's/^linux-//; s/-gentoo-.*//')
      echo "$((i+1)). $kernel_version"
    done

    read -rp "Please enter the kernel version you want to use (e.g., 1): " kernel_choice
    if [[ ! $kernel_choice =~ ^[0-9]+$ ]] || (( kernel_choice < 1 || kernel_choice > ${#kernels[@]} )); then
      echo "Error: Invalid selection. Please try again."
      continue
    fi
    kernel_dir="${kernels[$((kernel_choice-1))]}"
    kernel_version=$(basename "$kernel_dir" | sed 's/^linux-//; s/-gentoo-.*//')

    if [[ ! -d "$kernel_dir" ]]; then
      echo "Error: Kernel for version $kernel_version are missing in /usr/src/..."
      echo "Please ensure the kernel is installed and try again."
      read -rp "Do you want to retry to compile the kernel source? (y/n): " choice
      if [[ "$choice" =~ ^[Nn] ]]; then
        echo "We will contanuie to scan the directoiry"
        echo "or you ccan try in other tty to fix the issue"
        continue
      elif [[ "$choice" =~ ^[Yy] ]]; then
        echo "We will re emerge the package sys-kernel/gentoo-sources"
        sleep 5
        emerge --ask sys-kernel/gentoo-sources
        continue
      else
        echo "Inlavid choice. Please try again."
        continue
      fi
    fi
    break # If kernel is valid, procced
  done

  while true; do
    if [[ -f /tmp/.config ]]; then
      mv /tmp/.config "$kernel_dir/.config"
      echo "Moved /tmp/.config to $kernel_dir/.config"
    else
      echo "Error: /tmp/.config not found. Please ensure the file exists."
      exit 1
    fi
    # Merge configurations
    if [[ -f "$kernel_dir/scripts/kconfig/merge_config.sh" ]]; then
      cd "$kernel_dir" || { echo "Failed to change directory to $kernel_dir"; exit 1; }
      ./scripts/kconfig/merge_config.sh .config "$kernel_dir/.config"
      echo "Configurations merged successfully."
    else
      echo "Error: merge_config.sh not found. Please ensure the kernel source is properly installed."
      exit 1
    fi
    # Show differences between old and new .config
    if [[ -f .config.old && -f .config ]]; then
      echo "Differences between .config.old and .config:"
      diff .config.old .config
    else
      echo "Error: .config.old or .config not found. Cannot show differences."
      exit 1
    fi

    read -rp "pleaes double check if the changes from custom .config change the original .config that is now .config.bak (y/n/retry): " config_change
    case $config_change in
      [Yy])
        echo "It looks good"
        break
        ;;
      [Nn])
        echo "Fix any issue there is and the ntypr 'retry'"
        ;;
      retry)
        echo "retrying"
        continue
        ;;
      *)
        echo " Invalid input. Type 'y' if it looks good, 'n' if there need to be a fix, 'etry'to retry"
        ;;
    esac
  done
  # if so make it so it runs: genkernel --luks --gpg --firmware --btrfs --keymap --oldconfig --save-config --menuconfig --install all

  genkernel --firmware --keymap --oldconfig --menuconfig --install all

}
