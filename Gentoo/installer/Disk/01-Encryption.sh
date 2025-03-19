#!/bin/bash

Encryption_swap() {
  local root_disk="$1"

  echo "Now we need to generate encryption keyfile for swap"
  dd if=/dev/urandom of=/media/keydrive/swap-keyfile bs=8388608 count=1 
  echo "GPG symmetric encryption of the swap-keyfile"
  sleep 5
  gpg --symmetric --cipher-algo AES256 --output /media/keydrive/swap-keyfile.gpg /media/keydrive/swap-keyfile
  sleep 3 
  echo "GPG encryption successful for swap"

  echo "Now we need to generate encryption keyfile for root"
  dd if=/dev/urandom of=/media/keydrive/root-keyfile bs=8388608 count=1 
  echo "GPG symmetric encryption of the root-keyfile"
  sleep 5
  gpg --symmetric --cipher-algo AES256 --output /media/keydrive/root-keyfile.gpg /media/keydrive/root-keyfile
  sleep 3 

  echo "We will now delete the unencrypted keyfile for swap and root"
  echo "/media/keydrive/swap-keyfile and /media/keydrive/root-keyfile"
  shred /media/keydrive/swap-keyfile && shred /media/keydrive/root-keyfile
  echo "Key-file shred successful!"
  sleep 3

  echo "We now need to GPG decrypt both swap-keyfile and root-keyfile to encrypt the partitions"
  gpg --decrypt --output /tmp/swap-keyfile /media//keydrive/swap-keyfile.gpg 
  gpg --decrypt --output /tmp/root-keyfile /media/keydrive/root-keyfile.gpg 
  echo "Both GPG encryption file decrypted successfully"
  sleep 3 

  echo "Now we can encrypt the disk with the keyfile"
  cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 "${root_disk}1" --key-file=/tmp/swap-keyfile
  cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 "${root_disk}2" --key-file=/tmp/root-keyfile
  echo "Disk is now Formated with luks and keyfile"

  echo "Opening the partitions"
  cryptsetup open "${root_disk}1" cryptswap --key-file=/tmp/swap-keyfile
  cryptsetup open "${root_disk}2" cryptroot --key-file=/tmp/root-keyfile
  shred /tmp/swap-keyfile && shred /tmp/root-keyfile
  echo "Disk is now opend and key shreded"
  sleep 3 
}

Encryption_no_swap() {
  sleep 3 
  local root_disk="$1"

  echo "Now we need to generate encryption keyfile for too (no swap)"
  dd if=/dev/urandom of=/media/keydrive/root-keyfile bs=8388608 count=1 
  echo "GPG symmetric encryption of the root-keyfile (no swap)"
  gpg --symmetric --cipher-algo AES256 --output /media/keydrive/root-keyfile.gpg /media/keydrive/root-keyfile
  echo "GPG encryption successfully for root (no swap)"
  sleep 3

  echo "We will now delete the none gpg key!"
  shred /media/keydrive/root-keyfile
  echo "keyfile shreded"
  sleep 3

  echo "we need to decrypt and format and open disk"
  gpg --decrypt --output /tmp/root-keyfile /media/keydrive/root-keyfile.gpg
  cryptsetup --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 "${root_disk}1" --key-file=/tmp/root-keyfile
  cryptsetup open "${root_disk}1" cryptroot --key-file=/tmp/root-keyfile
  shred /tmp/root-keyfile
  echo "Disk is now opend and key shreded"
  sleep 3 
}
