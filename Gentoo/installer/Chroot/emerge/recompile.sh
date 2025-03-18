#!/bin/bash

system-emptytree() {
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
    emerge sys-kernel/gentoo-sources sys-kernel/genkernel sys-kernel/installkernel sys-kernel/linux-firmware \
      sys-fs/cryptsetup sys-fs/btrfs-progs sys-apps/sysvinit sys-auth/seatd sys-apps/dbus sys-apps/pciutils \
      sys-process/cronie net-misc/chrony net-misc/networkmanager app-admin/sysklogd app-shells/bash-completion \
      dev-vcs/git sys-apps/mlocate sys-block/io-scheduler-udev-rules sys-boot/efibootmgr sys-firmware/sof-firmware \
      app-editors/neovim app-arch/unzip

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
