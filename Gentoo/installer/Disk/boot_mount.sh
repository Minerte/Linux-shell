#!/bin/bash

Bootmount() {
  local boot_disk="$1"
  echo "Now we will partition the selected disk: $boot_disk for boot and keyfile"
  parted --script "$boot_disk" \
    mklabel gpt \
    mkpart primary fat32 0% 1G \
    set 1 esp on \
    mkpart primary ext4 1G 2G \
    set 2 boot on
  sleep 3 

  echo "Making filesystem for bootdrive and keydrive"
  mkfs.vfat -F 32 "${boot_disk}1"
  mkfs.ext4 "${boot_disk}2"
  echo "Makeing directory for mount in /media/keydrive"
  mkdir /media/keydrive
  echo "Mounting ${boot_disk}2 to /media/keydrive"
  mount "${boot_disk}2" /media/keydrive
  echo "Boot is now mounted"

  sleep 3 
}