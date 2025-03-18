#!/bin/bash

Kernel() {
    ./usr/src/linux/scripts/kconfig/merge_config.sh .config /tmp/.config
    diff .config.old .config
    read -rp "pleaes double check if the changes from custom .config change the original .config that is now .config.bak"
    # have that they can retry if it did not work
    # use: Diff command to compare
    # This mean that they need to configure manually in graphic or in another tty
    # if so make it so it runs: genkernel --luks --gpg --firmware --btrfs --keymap --oldconfig --save-config --menuconfig --install all
}