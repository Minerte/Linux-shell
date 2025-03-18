#!/bin/bash

set -e  # Exit on error
set -u  # Exit on unset variables

dracut_update_and_EFIstub() {
  local root_disk="$1"
  local boot_disk="$2"
  echo "Updating dracut"

  # List available kernel versions
  while true; do
    echo "Listing available kernel versions in /usr/src/:"
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

    break
  done

  # Gather UUIDs and PARTUUIDs
  swapuuid=$(blkid "${root_disk}1" -o value -s UUID)
  rootuuid=$(blkid "${root_disk}2" -o value -s UUID)
  boot_key_partuuid=$(blkid "${boot_disk}2" -o value -s PARTUUID)

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
  kernel_cmdline+=" rd.luks.key=/dev/disk/by-partuuid/$boot_key_partuuid:/swap-keyfile.gpg"

  # Create the custom dracut module
  mkdir -p /usr/lib/dracut/modules.d/90gpgdecrypt/
  cat << EOF > /usr/lib/dracut/modules.d/90gpgdecrypt/gpgdecrypt.sh
#!/bin/bash

# Mount the USB keystorage partition
mkdir -p /media/keydrive
mount /keydisk-PART-UUID /media/keydrive || { echo "Failed to mount USB keystorage partition"; exit 1; }

# Decrypt the GPG-encrypted keyfile
gpg --decrypt --batch --passphrase 123456789 --output /tmp/swap-keyfile /media/keydrive/swap-keyfile.gpg || { echo "Failed to decrypt keyfile"; exit 1; }
gpg --decrypt --batch --passphrase 123456789 --output /tmp/root-keyfile /media/keydrive/root-keydile.gpg || { echo "Failed to decrypt keyfile"; exit 1; }

# Unlock the LUKS-encrypted root partition
cryptsetup open --key-file=/tmp/swap-keyfile /dev/sdX cryptswap || { echo "Failed to unlock swap partition"; exit 1; }
cryptsetup open --key-file=/tmp/root-keyfile /dev/sdX cryptroot || { echo "Failed to unlock root partition"; exit 1; }

# Clean up
shred -u /tmp/root-keyfile && shred -u /tmp/swap-keyfile
umount /media/keydrive
EOF

  cat << EOF > /usr/lib/dracut/modules.d/90gpgdecrypt/module-setup.sh
#!/bin/bash

check() {
    return 0
}

depends() {
    echo "crypt"
}

install() {
    inst_hook initqueue/settled 90"\$moddir/gpgdecrypt.sh" /gpgdecrypt.sh
    inst_multiple gpg cryptsetup mount umount shred
}
EOF

  # Ensure the scripts are executable
  chmod +x /usr/lib/dracut/modules.d/90gpgdecrypt/gpgdecrypt.sh
  chmod +x /usr/lib/dracut/modules.d/90gpgdecrypt/module-setup.sh

  # Update /etc/dracut.conf
  if ! grep -q "^add_dracutmodules+=\" 90gpgdecrypt crypt crypt-gpg dm rootfs-block \"" /etc/dracut.conf; then
      echo 'add_dracutmodules+=" 90gpgdecrypt crypt crypt-gpg dm rootfs-block "' >> /etc/dracut.conf
  fi

  if ! grep -q "^install_items+=\" /usr/bin/gpg /usr/bin/cryptsetup /usr/bin/mount /usr/bin/umount /usr/bin/shred \"" /etc/dracut.conf; then
      echo 'install_items+=" /usr/bin/gpg /usr/bin/cryptsetup /usr/bin/mount /usr/bin/umount /usr/bin/shred "' >> /etc/dracut.conf
  fi

  if ! grep -q "^kernel_cmdline+=\"$kernel_cmdline\"" /etc/dracut.conf; then
      echo "kernel_cmdline+=\"$kernel_cmdline\"" >> /etc/dracut.conf
  fi

  # Rebuild the initramfs
  dracut --force -v --uefi --add gpgdecrypt --kver "$kernel_version"

  sleep 5
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
    sleep 5

  # Embed the kernel command line into the EFI binary
  objcopy \
    --add-section .cmdline=<(echo -n "$kernel_cmdline") \
    --change-section-vma .cmdline=0x30000 \
    /efi/EFI/Gentoo/bzImage.efi \
    /efi/EFI/Gentoo/gentoo.efi

  # Create an EFI boot entry
  efibootmgr --create --disk "$boot_disk" --part 1 \
  --label "Gentoo" \
  --loader '\EFI\Gentoo\gentoo.efi' \
  --unicode "initrd=\EFI\Gentoo\initramfs.img"

    echo "NOW EVERYTHING IS DONE AND WE CAN REBOOT"
}