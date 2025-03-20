#!/bin/bash

config_system() {
  echo "we will be using EOF to configure fstab"
  echo "All this coming from first function where we created disk and subvolome"
  cat << EOF > /mnt/gentoo/etc/fstab || { echo "Failed to edit fstab with EOF"; exit 1; }
#Root
LABEL=BTROOT    /       btrfs   defaults,noatime,compress=zstd,subvol=activeroot     0 0
LABEL=BTROOT    /home   btrfs   defaults,noatime,compress=zstd,subvol=home           0 0
LABEL=BTROOT    /etc    btrfs   defaults,noatime,compress=zstd,subvol=etc            0 0
LABEL=BTROOT    /var    btrfs   defaults,noatime,compress=zstd,subvol=var            0 0
LABEL=BTROOT    /log    btrfs   defaults,noatime,compress=zstd,subvol=log            0 0
LABEL=BTROOT    /tmp    btrfs   defaults,noatime,nosuid,nodev,noexec,compress=zstd,subvol=tmp    0 0

EOF
  sleep 3
  echo "setting up loclale.gen"
  sed -i "s/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g" /mnt/gentoo/etc/locale.gen
  # If dualboot uncomment below
  # sed -i "s/clock=\"UTC\"/clock=\"local\"/g" ./etc/conf.d/hwclock
  echo "Changing to swedish keyboard"
  sed -i "s/keymap=\"us\"/keymaps=\"sv-latin1\"/g" /mnt/gentoo/etc/conf.d/keymaps
  echo "change locale.conf and edit timezone to Europe/Stockholm"
  echo 'LANG="en_US.UTF-8"' >> /mnt/gentoo/etc/locale.conf
  echo 'LC_COLLATE="C.UTF-8"' >> /mnt/gentoo/etc/locale.conf
  echo "Europe/Stockholm" > /mnt/gentoo/etc/timezone
  sleep 3

  blkid | grep BTROOT
  read -rp "Do the root drive have LABEL=BTROOT (y/n): " user_input
  if [[ "$user_input" =~ ^[Nn] ]]; then
    echo "Exiting..."
    exit 1
  fi

  echo "Succesfully edited basic system"
}

config_portage() {
  echo "we will now configure system"
  # Copy custom portage configuration files
  echo "Moving over portge file from download to chroot"
  mkdir /mnt/gentoo/etc/portage/env
  mv ~/Linux-shell-main/Gentoo/portage/env/no-lto /mnt/gentoo/etc/portage/env/
  mv ~/Linux-shell-main/Gentoo/portage/make.conf /mnt/gentoo/etc/portage/
  mv ~/Linux-shell-main/Gentoo/portage/package.env /mnt/gentoo/etc/portage/
  mv ~/Linux-shell-main/Gentoo/portage/package.unmask /mnt/gentoo/etc/portage/

  mv ~/Linux-shell-main/Gentoo/portage/package.use/* /mnt/gentoo/etc/portage/package.use/
  mv ~root/Linux-shell-main/Gentoo/portage/package.accept_keywords/* /mnt/gentoo/etc/portage/package.accept_keywords/
  echo "copinging over package.accept_keywords successully"
  echo "Portage configuration complete."
}
