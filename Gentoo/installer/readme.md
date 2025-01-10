For more details please follow this link: [Gentoo wiki Full Disk Encryption From Scratch](https://wiki.gentoo.org/wiki/Full_Disk_Encryption_From_Scratch)
This is not directly a guide is for the installer autoscript
and a guide for the autoscript if somethings go wrong and for trubelshoot.

# For use with encrypt-gpg.sh
**The partition needs/will to look like this:**
```
/dev/sda #boot drive
├── /dev/sda1      [EFI]   /efi      1 GB         fat32       Bootloader
└── /dev/sda2      [BOOTX] /boot     1 GB         ext4        Bootloader support files, kernel and initramfs

/dev/nvme0n1 # root drive
 └── /dev/nvme0n1p1 [ROOT]  (root)    ->END        luks        Encrypted root device, mapped to the name 'root'
      └──  /dev/mapper/root /         ->END        btrfs       root filesystem
                            /home     subvolume                Subvolume created for the home directory
```
## the cryptsetup needs to do:
```
cryptsetup luksFormat --header /media/sda2/luks_header.img /dev/nvme0n1p1
```

```
mkfifo key_pipe
gpg --decrypt key_file > key_pipe &
cryptsetup luksAddkey --keyfile key_pipe /dev/nvme0n1p1
rm key_pipe
```

# GPG symmetrically encrypted key file
## IMPORTANT:
**if using gentoo install ISO, it may be necessary to run**
```
export GPG_TTY=$(tty)
```
**In /media/sda2 is where the key will be located**
**This need to be run in /media/sda2**
```
dd  bs=8388608 count=1 if=/dev/urandom | gpg --symmetric --cipher-algo AES256 --output crypt_key.luks.gpg
```

**luksformat  using gpg protected key file**
```
gpg --decrypt crypt_key.luks.gpg | cryptsetup luksFormat --key-size 512 /dev/nvme0n1p1 -gpg: AES256.CFB encrypted data
```

**once the file are created**
```
gpg --decrypt crypt_key.luks.gpg > crypt_key &
read -s -r -p 'LUKS passphrase: ' CRYPT_PASS; echo "$CRYPT_PASS" > cryptsetup_pass &
```
**using cat to pass on information to cryptsetup**
```
cat cryptsetup_pass crypt_key | cryptsetup luksAddKey /dev/nvme0n1p1 -gpg: AES256.CFB encrypted data
```

**now you can exit and be at directory / instead of /media/sda2**
end of  /media/sda2
# LUKSHEADER backup
```
cryptsetup luksHeaderBackup /dev/nvme0n1p1 --header-backup-file crypt_headers.img
```

# Filesystem prep
```
gpg --decrypt crypt_key.luks.gpg | cryptsetup --key-file - open /dev/nvme0n1p1 root
```
note : this command will open /dev/nvme0n1p1 and map it under /dev/mapper/ with the name root

# Format the file systems
```
mkfs .vfat -F32 /dev/sda1 # EFI partition
mkfs.ext4 -L boot /dev/sda2 # encryption key
```
**creating rootfs to /dev/nvme0n1p1**
```
mkfs.btrfs -L rootfs /dev/mapper/root 
```

```
mount -t btrfs -o defaults,noatime,compress=lzo /dev/mapper/root /mnt/gentoo 
# this will create....
btrfs subvolume create /mnt/root/activeroot
btrfs subvolume create /mnt/root/home
```
