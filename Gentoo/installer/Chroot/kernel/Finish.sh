#!/bin/bash

set -e  # Exit on error
set -u  # Exit on unset variables

dracut_update_and_EFIstub() {
  local root_disk="$1"
  local boot_disk="$2"
  echo "Updating dracut"

  # List available kernel versions from /lib/modules/
  while true; do
    echo "Listing available kernel versions in /lib/modules/:"
    kernels=($(ls -d /lib/modules/*/ 2>/dev/null | sed 's|/lib/modules/||; s|/||'))
    if [ ${#kernels[@]} -eq 0 ]; then
      echo "No kernel version found in directory /lib/modules/"
      exit 1
    fi
    
    for i in "${!kernels[@]}"; do
      echo "$((i+1)). ${kernels[$i]}"
    done

    read -rp "Please enter the kernel version you want to use (e.g., 1): " kernel_choice
    if [[ ! $kernel_choice =~ ^[0-9]+$ ]] || (( kernel_choice < 1 || kernel_choice > ${#kernels[@]} )); then
      echo "Error: Invalid selection. Please try again."
      continue
    fi
    kernel_version="${kernels[$((kernel_choice-1))]}"
    break
  done

  # Gather UUIDs and PARTUUIDs
  swapuuid=$(blkid "${root_disk}1" -o value -s UUID)
  rootuuid=$(blkid "${root_disk}2" -o value -s UUID)
  boot_key_partuuid=$(blkid "${boot_disk}2" -o value -s PARTUUID)
  kernel_cmdline="" # Initialize if unset

  if [[ -z "$swapuuid" || -z "$rootuuid" || -z "$boot_key_partuuid" ]]; then
    echo "Error: Missing one or more UUIDs. Ensure disks are properly configured."
    exit 1
  fi

  # Retrieve the root partition label
  rootlabel=$(blkid "${root_disk}2" -o value -s LABEL)
  if [ -z "$rootlabel" ]; then
    echo "No LABEL found for ${root_disk}2 (ROOT)"
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

  # Add LUKS parameters
  kernel_cmdline+=" rd.luks.uuid=$rootuuid rd.luks.name=$rootuuid=cryptroot"
  kernel_cmdline+=" rd.luks.key=/dev/disk/by-partuuid/$boot_key_partuuid:/luks-keyfile.gpg"
  kernel_cmdline+=" rd.luks.allow-discards"
  kernel_cmdline+=" rd.luks.uuid=$swapuuid rd.luks.name=$swapuuid=cryptswap"
  kernel_cmdline+=" rd.luks.key=/dev/disk/by-partuuid/$boot_key_partuuid:/swap-keyfile.gpg "

  # Create the custom dracut module
  mkdir -p /usr/lib/dracut/modules.d/90gpgdecrypt/
  
  cat << 'EOF' > /usr/lib/dracut/modules.d/90gpgdecrypt/gpgdecrypt.sh
#!/bin/bash

# Read parameters from kernel command line
boot_key_partuuid=$(getarg rd.luks.key= | cut -d: -f1 | cut -d= -f2 | cut -d/ -f5)
swapuuid=$(getarg rd.luks.uuid= | awk '{print $1}')
rootuuid=$(getarg rd.luks.uuid= | awk '{print $2}')

# Mount the USB keystorage partition
mkdir -p /media/keydrive
mount "/dev/disk/by-partuuid/$boot_key_partuuid" /media/keydrive || { 
  echo "Failed to mount USB keystorage partition"
  exit 1
}

# Decrypt the GPG-encrypted keyfiles
gpg --decrypt --batch --passphrase-file /media/keydrive/passphrase.txt \
  --output /tmp/swap-keyfile /media/keydrive/swap-keyfile.gpg || {
  echo "Failed to decrypt swap keyfile"
  exit 1
}

gpg --decrypt --batch --passphrase-file /media/keydrive/passphrase.txt \
  --output /tmp/root-keyfile /media/keydrive/root-keyfile.gpg || {
  echo "Failed to decrypt root keyfile"
  exit 1
}

# Unlock LUKS partitions
cryptsetup open --key-file=/tmp/swap-keyfile "$(blkid -t UUID=$swapuuid -o device)" cryptswap || {
  echo "Failed to unlock swap partition"
  exit 1
}

cryptsetup open --key-file=/tmp/root-keyfile "$(blkid -t UUID=$rootuuid -o device)" cryptroot || {
  echo "Failed to unlock root partition"
  exit 1
}

# Clean up
shred -u /tmp/root-keyfile /tmp/swap-keyfile
umount /media/keydrive
EOF

cat << 'EOF' > /usr/lib/dracut/modules.d/90gpgdecrypt/module-setup.sh
#!/bin/bash

check() {
    # Verify required binaries exist
    require_binaries gpg cryptsetup || return 1
    return 0
}

depends() {
    # Declare module dependencies
    echo "crypt"
    return 0
}

install() {
    # Install the hook script
    inst_hook initqueue/settled 90 "${moddir}/gpgdecrypt.sh"
    
    # Install all required binaries
    inst_multiple gpg cryptsetup mount umount shred blkid getarg
    
    # Debug output
    dracut_echo "gpgdecrypt module installed successfully"
    return 0
}
EOF

  # Ensure the scripts are executable
  chmod +x /usr/lib/dracut/modules.d/90gpgdecrypt/gpgdecrypt.sh
  chmod +x /usr/lib/dracut/modules.d/90gpgdecrypt/module-setup.sh

  # Update /etc/dracut.conf
  if grep -q '^add_dracutmodules' /etc/dracut.conf; then
    if ! grep -qw '90gpgdecrypt' /etc/dracut.conf; then
      sed -i '/^add_dracutmodules/ s|$| gpgdecrypt crypt crypt-gpg dm rootfs-block |' /etc/dracut.conf
    fi
  else
    echo 'add_dracutmodules+=" 90gpgdecrypt crypt crypt-gpg dm rootfs-block "' >> /etc/dracut.conf
  fi

  if grep -q '^install_items' /etc/dracut.conf; then
    if ! grep -qw '/usr/bin/blkid' /etc/dracut.conf; then
      sed -i '/^install_items/ s|$| /usr/bin/blkid /usr/bin/gpg /usr/bin/cryptsetup /usr/bin/mount /usr/bin/umount /usr/bin/shred /usr/bin/getarg |' /etc/dracut.conf
    fi
  else
    echo 'install_items+=" /usr/bin/blkid /usr/bin/gpg /usr/bin/cryptsetup /usr/bin/mount /usr/bin/umount /usr/bin/shred /usr/bin/getarg "' >> /etc/dracut.conf
  fi

  if grep -q '^kernel_cmdline' /etc/dracut.conf; then
    if ! grep -Fq "$kernel_cmdline" /etc/dracut.conf; then
      sed -i "/^kernel_cmdline/ s|$| $kernel_cmdline |" /etc/dracut.conf
    fi
  else
    echo "kernel_cmdline+=\"$kernel_cmdline\"" >> /etc/dracut.conf
  fi

  # Rebuild the initramfs (without --uefi for OpenRC)
  echo "Building initramfs for kernel version: $kernel_version"

  # Rebuild the initramfs with explicit module path
  dracut --force --verbose --kver "6.12.16-gentoo-x86_64"

  sleep 5
  echo "Copying kernel and initramfs to /efi/EFI/Gentoo"

  # Copy kernel (try multiple possible locations)
  kernel_found=false
  for kernel_path in "/boot/vmlinuz-$kernel_version" "/boot/bzImage-$kernel_version" "/boot/kernel-$kernel_version"; do
    if [ -f "$kernel_path" ]; then
      cp "$kernel_path" /efi/EFI/Gentoo/bzImage.efi
      echo "Successfully copied kernel from $kernel_path"
      kernel_found=true
      break
    fi
  done

  if [ "$kernel_found" = false ]; then
    echo "ERROR: Could not find kernel image in /boot/"
    exit 1
  fi

  # Copy initramfs
  if [ -f "/boot/initramfs-$kernel_version.img" ]; then
    cp "/boot/initramfs-$kernel_version.img" /efi/EFI/Gentoo/initramfs.img
    echo "Successfully copied initramfs to /efi/EFI/Gentoo/initramfs.img"
  else
    echo "ERROR: Could not find initramfs in /boot/"
    exit 1
  fi

  # Create an EFI boot entry
  boot_partuuid=$(blkid "${boot_disk}1" -o value -s PARTUUID)
  efibootmgr --create --disk "/dev/disk/by-partuuid/$boot_partuuid" --part 1 \
    --label "Gentoo" \
    --loader '\EFI\Gentoo\gentoo.efi' \
    --unicode "initrd=\EFI\Gentoo\initramfs.img \
      root=LABEL=$rootlabel \
      rootflags=subvol=activeroot \
      rd.luks.uuid=$rootuuid rd.luks.name=$rootuuid=cryptroot \
      rd.luks.key=/dev/disk/by-partuuid/$boot_key_partuuid:/luks-keyfile.gpg \
      rd.luks.allow-discards \
      rd.luks.uuid=$swapuuid rd.luks.name=$swapuuid=cryptswap \
      rd.luks.key=/dev/disk/by-partuuid/$boot_key_partuuid:/swap-keyfile.gpg"

  echo "IMPORTANT: Before rebooting:"
  echo "1. Edit /media/keydrive/passphrase.txt with your GPG passphrase"
  echo "2. Verify keyfiles exist at:"
  echo "   - /media/keydrive/swap-keyfile.gpg"
  echo "   - /media/keydrive/root-keyfile.gpg"
  echo "3. Test decryption manually with:"
  echo "   chroot /mnt /usr/lib/dracut/modules.d/90gpgdecrypt/gpgdecrypt.sh"
  echo "After verification, you can reboot."
}
