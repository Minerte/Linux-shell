#!/bin/bash

First() {
  local boot_disk="$1"

  if [[ ! -d "/efi" ]]; then
    echo "Making efi directory"
    mkdir /efi
  else
    echo "/efi directory already exists"
  fi

  # Mount the boot partition to /efi
  if ! mount "${boot_disk}1" /efi; then
    echo "Failed to mount boot disk (${boot_disk}1) to /efi"
    exit 1
  fi

  mkdir -p /efi/EFI/Gentoo || { echo "Could not create /EFI/Gentoo in /efi directory"; exit 1; }
  lsblk
  ls -a /efi
  read -rp "is ${boot_disk}1 mounted to /efi. And do you have /efi/EFI/Gentoo (y/n): " user_input
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

  eselect profile list
  read -rp "Select your profile: " profile_choice

  if [[ "$profile_choice" =~ ^[0-9]+$ ]]; then
    # Check if the choice is within the range of available profiles
    if eselect profile set "$profile_choice" &>/dev/null; then
      echo "Profile successfully set to $profile_choice."
    else
      echo "Error: Invalid profile choice. Please select a valid profile number."
    fi
  else
    echo "Error: Please enter a valid number."
  fi

  env-update && source /etc/profile
  export PS1="(chroot) ${PS1}"

  echo "Chroot environment setup complete!"
}

cpu_to_flags() {
  echo "cpuid2cpuflags"
  emerge --oneshot app-portage/cpuid2cpuflags
        
  echo "Adding flag to make.conf"
  CPU_FLAGS=$(cpuid2cpuflags | cut -d' ' -f2-)
  if grep -q "^CPU_FLAGS_X86=" /etc/portage/make.conf; then
    sed -i "s/^CPU_FLAGS_X86=.*/CPU_FLAGS_X86=\"${CPU_FLAGS}\"/" /etc/portage/make.conf  || { echo "could not add CPU_FLAGS_X86= and cpuflags to make.conf"; exit 1; }
    echo "cpuid2cpuflags added succesfully to make.conf"
  else
    echo "CPU_FLAGS_X86=\"${CPU_FLAGS}\"" >> /etc/portage/make.conf || { echo "could not add cpuflags to make.conf"; exit 1; }
  fi
}