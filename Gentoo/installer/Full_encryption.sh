#!/bin/bash

# Ensure the script runs as root
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root"
  exit 1
fi 

source ~/Linux-shell-main/Gentoo/installer/Disk/01-Encryption.sh || { echo "Failed to source Disk"; exit 1;}
source ~/Linux-shell-main/Gentoo/installer/Config/04-swap-no-or-yes.sh || { echo "Failed to source config"; exit 1;}
source ~/Linux-shell-main/Gentoo/installer/Stage_and_verify/02-Stage3-download.sh || { echo "Failed to source stage -02"; exit 1;}
source ~/Linux-shell-main/Gentoo/installer/Stage_and_verify/03-gpg-verify.sh || { echo "Failed to source stage -03"; exit 1;}
source ~/Linux-shell-main/Gentoo/installer/Config/05-Config-system.sh || { echo "Failed to source config -05"; exit 1;}

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

Disk_prep() {
  local root_disk="$1"
  local boot_disk="$2"
  sleep 3
  read -rp "You are about to format the selected disk: $boot_disk and $root_disk (y/n): " confirm
  if [[ "$confirm" != "y" ]]; then
    echo "Abort the script."
    exit 1
  fi
  echo "We will now partition the selected disk: $boot_disk"
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
  echo "Boot disk is now done"
  sleep 3
  echo "-------------------------------------------------------------------------"
  echo "Now we will start to partition the root drive: $root_disk"
  echo "If user choose swap it will be (100% root) - swap_size"
  read -rp "Do you want a swap? (y/n): " choice 
  if [[ "$choice" =~ ^[Nn] ]]; then
    echo "No Swap"
    parted --script "$root_disk"\
      mklabel gpt \
      mkpart primary btrfs 0% 100%

    Encryption_no_swap "$root_disk"

    echo "Root is done (No swap)"
  fi

  if [[ "$choice" =~ ^[Yy] ]]; then
    echo "Now we will partition for Swap and Root"
    while true; do 
      echo "The root partition will be like 100% - SWAP"
      read -rp "Please select a SWAP size (in GB): " swap_size
      if ! [[ "$swap_size" =~ ^[0-9]+$ ]]; then
        echo "Not a valid size. Please enter a positive integer."
        continue
      fi
      if (( swap_size < 1 || swap_size > 1000 )); then
        echo "Swap size must be between 1GB and 1000GB."
        continue
      fi
      break
    done

    echo "The swap is set to ${swap_size}GB."
    parted --script "$root_disk"\
      mklabel gpt \
      mkpart primary linux-swap 0% "${swap_size}G" \
      set 1 swap on \
      mkpart primary btrfs "${swap_size}G" 100%

    Encryption_swap "$root_disk"
    echo "Root with swap are now done"
  fi
  echo "Disk prep are now done"
  sleep 3
}

Prep_root() {

  echo "Making swap and swapon"
  mkswap /dev/mapper/cryptswap || { echo "Failed to make swap"; exit 1; }
  swapon /dev/mapper/cryptswap || { echo "No swap on"; exit 1; }

  mkfs.btrfs -L BTROOT /dev/mapper/cryptroot
  mkdir /mnt/root
  mount -t btrfs -o defaults,noatime,compress=zstd /dev/mapper/cryptroot /mnt/root
  sleep 3

  echo "Creation of subvolumes"
  for sub in activeroot home etc var log tmp; do 
    btrfs subvolume create /mnt/root/$sub  || { echo "Failed to create subvolume $sub"; exit 1; }
  done
  sleep 3
  echo "Mounting subvolumes to /mnt/gentoo"
  mount -t btrfs -o defaults,noatime,compress=zstd,subvol=activeroot /dev/mapper/cryptroot /mnt/gentoo/
  mkdir /mnt/gentoo/{home,etc,var,log,tmp}
  for sub in home etc var log tmp; do
        mount -t btrfs -o defaults,noatime,compress=zstd,subvol=$sub /dev/mapper/cryptroot /mnt/gentoo/$sub   || { echo "Failed to mount subvolume $sub"; exit 1; }
  done
  sleep 3
  lsblk 
  read -rp "Does the disk layout look correct? (y/n): " confirm
  if [[ "$confirm" =~ ^[Nn] ]]; then
    echo "ABORTING SCRIPT!"
    exit 1 
  fi 
  echo "Disk configuration done"
  sleep 3
}

Stage_file() {
  while true; do
    echo "Please choose the type of stage3 file for amd64:"
    echo "1. Hardened OpenRC"
    echo "2. Hardened SELinux OpenRC"

    read -rp "Enter your choice (1-2): " type_choice
  
    if download_stage3 "$type_choice"; then
      STAGE3_FILENAME=$(ls stage3-amd64-*.tar.xz 2>/dev/null)
      ASC_FILENAME="${STAGE3_FILENAME}.asc"

      if gpg_verify "$ASC_FILENAME" "$STAGE3_FILENAME"; then
        echo "Extracting stage3 file..."
        tar xpvf "$STAGE3_FILENAME" --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo || { echo "Failed to extract $STAGE3_FILENAME"; continue; }
        echo "Gentoo stage3 file setup complete."
        echo "Success!"
        break
      else
        echo "GPG verification failed. Deleting files and retrying..."
        rm -f "$STAGE3_FILENAME" "$ASC_FILENAME"
      fi
    else
      echo "Download failed. Retrying..."
    fi
  done
}

System_config() {
  sleep 3
  config_system
  swap-no-or-yes # to edit the fstab if swap is enable
  config_portage
  echo "config done"
  sleep 3
}

chroot_ready() {
  echo "Copy over resolv.conf to chroot"
  mkdir -p /mnt/gentoo/etc/portage/repos.conf
  cp /usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf
  cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
  echo "we will now have network in chroot later"

  echo "Setting up chroot environment..."
  mount --types proc /proc /mnt/gentoo/proc
  mount --rbind /sys /mnt/gentoo/sys
  mount --make-rslave /mnt/gentoo/sys
  mount --rbind /dev /mnt/gentoo/dev
  mount --make-rslave /mnt/gentoo/dev
  mount --bind /run /mnt/gentoo/run
  mount --make-slave /mnt/gentoo/run
  sleep 5

  echo "Coping over chroot.sh into chroot"
  cp -r /root/Linux-shell-main/Gentoo/installer/Chroot/* /mnt/gentoo/ || { echo "Failed to copy over chroot"; exit 1; }
  chmod +x /mnt/gentoo/Encryption-in-chroot.sh || { echo "Failed to make chroot.sh executable"; exit 1; }
  echo "everything is mounted and ready to chroot"
  echo "After the chroot is done it will be in another bash session"
  echo "chroot with this comand!"
  echo "chroot /mnt/gentoo /bin/bash"
  echo "After chroot run ./Chroot/Encryption-in-chroot.sh"
  sleep 5
}

export GPG_TTY=$(tty)
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
Disk_prep "$selected_root_disk" "$selected_boot_disk"
Prep_root
Stage_file
System_config
chroot_ready