#!/bin/bash

function in_chroot() {
    source /etc/profile
    export PS1="(chroot) ${PS1}"

    emerge-webrsync
    emerge --sync --quiet
    emerge --config sys-libs/timezone-data
    locale-gen
    env-update && source /etc/profile && export PS1="(chroot) ${PS1}"

    echo "Update make.conf with cpuid2cpuflags "
    emerge --ask app-portage/cpuid2cpuflags
    # shellcheck disable=SC2154
    sed -i "s/CPU_FLAGS_X86=\"cpuid2cpuflags\"/CPU_FLAGS_X86=\"$cpuid2cpuflags\"/" /etc/portage/make.conf
    nano /etc/portage/make.conf || { echo "Could not open nano"; exit 1; }
}

function setup_kernel() {
    echo "time for kernel config"
    eselect kernel set 1
    genkernel --luks --btrfs --keymap --oldconfig --save-config --menuconfig --install all
}

function setup_grub() {
    echo "Grub install and setup"
}

in_chroot
setup_kernel
setup_grub
