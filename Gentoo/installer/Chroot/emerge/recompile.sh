#!/bin/bash

system-emptytree() {
  echo "re-compiling existing package"
  sleep 3
  while true; do
    emerge --emptytree -a -1 @installed

    if [[ $? -eq 0 ]]; then
      echo "Recompilation completed successfully!"
      break
    else
      echo "Re-compile failed! Check dependencies and flags."
      echo "You are now in the chroot environment. Fix any issues, then type 'retry' to try again."

      while true; do
        read -rp "Type 'retry' to rerun emerge or 'exit' to leave: " input
        case $input in
          retry)
            break
            ;;
          exit)
            echo "Exiting chroot recompile script."
            exit 1
            ;;
          *)
            echo "Invalid input. Type 'retry' to retry or 'exit' to quit."
            ;;
        esac
      done
    fi
  done

  emerge dev-lang/rust || { echo "Rust dont want to compile check dependency and flags"; exit 1; }
  echo "enable system-bootstrap in /etc/portage/package.use/Rust"
  sed -i 's/\(#\)system-bootstrap/\1/' /etc/portage/package.use/Rust
}

system-packages() {
  emerge dev-lang/rust || { echo "Rust dont want to compile check dependency and flags"; exit 1; }
  echo "enable system-bootstrap in /etc/portage/package.use/Rust"
  sed -i 's/\(#\)system-bootstrap/\1/' /etc/portage/package.use/Rust

  while true; do
    emerge sys-kernel/gentoo-sources sys-kernel/genkernel sys-kernel/installkernel sys-kernel/linux-firmware sys-kernel/dracut \
      sys-fs/cryptsetup sys-fs/btrfs-progs sys-apps/sysvinit sys-auth/seatd sys-apps/dbus sys-apps/pciutils sys-process/cronie \
      sys-block/io-scheduler-udev-rules sys-boot/efibootmgr sys-firmware/sof-firmware sys-apps/mlocate \
      app-editors/neovim app-arch/unzip app-crypt/gnupg app-admin/sysklogd app-shells/bash-completion \
      net-misc/chrony net-misc/networkmanager dev-vcs/git

    if [[ $? -eq 0 ]]; then
      echo "Core packages installed successfully!"
      break
    else
      echo "Could not merge! Check dependencies and flags."
      echo "You are now in the chroot environment. Fix any issues, then type 'retry' to try again."
        
      while true; do
        read -rp "Type 'retry' to rerun emerge or 'exit' to leave: " input
        case $input in
          retry)
            break
            ;;
          exit)
            echo "Exiting chroot install script."
            exit 1
            ;;
          *)
            echo "Invalid input. Type 'retry' to retry or 'exit' to quit."
            ;;
        esac
      done
    fi
  done
}
