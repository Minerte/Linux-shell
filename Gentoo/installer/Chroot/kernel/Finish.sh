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
    echo "crypt crypt-gpg"
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
  grep -q "udevdir=/lib/udev" /etc/dracut.conf || echo "udevdir=/lib/udev" >> /etc/dracut.conf
  grep -q "ro_mnt=yes" /etc/dracut.conf || echo "ro_mnt=yes" >> /etc/dracut.conf
  grep -q 'omit_drivers+=" i2o_scsi "' /etc/dracut.conf || echo 'omit_drivers+=" i2o_scsi "' >> /etc/dracut.conf
  grep -q 'omit_dracutmodules+=" systemd systemd-initrd dracut-systemd systemd-udevd "' /etc/dracut.conf || echo 'omit_dracutmodules+=" systemd systemd-initrd dracut-systemd systemd-udevd "' >> /etc/dracut.conf
  grep -q 'add_dracutmodules+=" gpgdecrypt crypt crypt-gpg dm rootfs-block btrfs "' /etc/dracut.conf || echo 'add_dracutmodules+=" crypt crypt-gpg dm rootfs-block btrfs "' >> /etc/dracut.conf
  grep -q 'filesystems+=" btrfs "' /etc/dracut.conf || echo 'filesystems+=" btrfs "' >> /etc/dracut.conf
  grep -q 'use_fstab="yes"' /etc/dracut.conf || echo 'use_fstab="yes"' >> /etc/dracut.conf
  grep -q 'hostonly="yes"' /etc/dracut.conf || echo 'hostonly="yes"' >> /etc/dracut.conf
  grep -q "allow_symlinks=1" /etc/dracut.conf || echo "allow_symlinks=1" >> /etc/dracut.conf
  grep -q 'uefi="yes"' /etc/dracut.conf || echo 'uefi="yes"' >> /etc/dracut.conf
  grep -q 'install_items+=" /usr/bin/blkid /usr/bin/gpg /usr/bin/cryptsetup /usr/bin/mount /usr/bin/umount /usr/bin/shred /usr/bin/getarg "' /etc/dracut.conf || echo 'install_items+=" /usr/bin/blkid /usr/bin/gpg /usr/bin/cryptsetup /usr/bin/mount /usr/bin/umount /usr/bin/shred "' >> /etc/dracut.conf
  if grep -q '^kernel_cmdline' /etc/dracut.conf; then
    if ! grep -Fq "$kernel_cmdline" /etc/dracut.conf; then
      sed -i "/^kernel_cmdline/ s|$| $kernel_cmdline |" /etc/dracut.conf
    fi
  else
    echo "kernel_cmdline+=\"$kernel_cmdline\"" >> /etc/dracut.conf
  fi
  grep -q 'i18n_vars="/etc/conf.d/keymaps:KEYMAP /etc/rc.conf:UNICODE"' /etc/dracut.conf || echo 'i18n_vars="/etc/conf.d/keymaps:KEYMAP /etc/rc.conf:UNICODE"' >> /etc/dracut.conf
  grep -q 'i18n_install_all="yes"' /etc/dracut.conf || echo 'i18n_install_all="yes"' >> /etc/dracut.conf

  # Rebuild the initramfs with explicit module path
  echo "Building initramfs for kernel version: $kernel_version"
  sleep 5
  dracut --kver "$kernel_version" --add "gpgdecrypt" --force

  sleep 5
  echo "Copying kernel and initramfs to /efi/EFI/Gentoo"
  # Copy kernel (try multiple possible locations)
  echo "Copying /boot/kernel-* and /boot/initramfs to /efi/EFI/Gentoo"
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

  if cp "$(ls -1t /boot/initramfs-* | head -n 1)" /efi/EFI/Gentoo/initramfs.img; then
    echo "Successfully copied the latest initramfs to /efi/EFI/Gentoo/initramfs.img"
  else
    echo "Failed to copy initramfs to /efi/EFI/Gentoo/initramfs.img"
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

  efibootmgr -v
  read -rp "Does the efibootmgr look right? (y/n): " user_input
  if [[ "$user_input" =~ ^[Nn] ]]; then
    echo "Boot entry does not look right. Please fix the issue and try again."
    exit 1
  fi
}
