# This is both a guide and what the autoscript is doing
### The guide is taken from [Full Disk Encryption from scratch](https://wiki.gentoo.org/wiki/Full_Disk_Encryption_From_Scratch) from the Gentoo wiki, also note that readme.md only include the diskpepration with encryption and kernel changes that needs to be done.

The disk will look something like this when we done partitioning.
```
/dev/sda #boot drive
├── /dev/sda1      [EFI]   /efi      1 GB         fat32       Bootloader
└── /dev/sda2      [BOOTX] /boot     1 GB         ext4        Bootloader support files, kernel and initramfs

/dev/nvme0n1 # root drive
 ├── /dev/nvmeon1p1
 |    └──  /dev/mapper/cryptswap  SWAP      ->END        SWAP
 └── /dev/nvme0n1p2 [ROOT]  (root)          ->END        luks        Encrypted root device, mapped to the name 'root'
      └──  /dev/mapper/cryptroot  /         ->END        btrfs       root filesystem
                                  /home     subvolume                Subvolume created for the home directory
                                  /etc      subvolume
                                  /var      subvolume
                                  /log      subvolume
                                  /tmp      subvolume
```
### Preparing the "boot drive" to be mounted and generate keyfile
After disk preparation we need to create filesystem for /dev/sda1 and /dev/sda2 (our boot drive).
```
mkfs.vfat -F32 /dev/sda1
mkfs.ext4 /dev/sda2
```
**Note that /dev/sda1 is the bootloader and /dev/sda2 is for storage of keyfile**

After successfully create a filesystem we need to mount /dev/sda2 to /media/sda2 so we need to create a mount point in /media/.
```
mkdir /media/sda2
mount /dev/sda2 /meda/sda2
```

Now we need to change directory to /media/sda2 to generate the file and encrypt the root disk, I do it this way for its easier for me. You could do it in the root Live-cd but then you need to change of=/path/to/file.
```
cd /media/sda2
```

### Key generation for SWAP partition
Here we generate a keyfile, the keyfile of swap should be **16MB**
```
dd if=/dev/urandom of=swap-keyfile bs=16777216 count=1 # User can change bs= to any number that is higher then 512bytes
gpg --symmetric --cipher-algo AES256 --output swap-keyfile.gpg swap-keyfile
```

We need to decrypt the gpg file so we can encrypt the swap partition using the keyfil.
```
gpg --decrypt --output /tmp/swap-keyfil swap-keyfile.gpg
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 /dev/[swap_partition] --key-file=/tmp/swap-keyfile 
```

Now we can open the disk for modification.
```
cryptsetup open /dev/[swap_partition] cryptswap --key-file=/tmp/swap-keyfile
```
And then you might want to securely remove the **swap-keyfile** with the command:
#### Caution do not delete the swap-keyfile in /media/sda2!
```
shred -u /tmp/swap-keyfile
```

### Key generation for GPG symmetric keyfile for Root drive
First we need to generate the key and the generation of the keyfile, so the keyfile size should be **32MB** with the command
```
dd if=/dev/urandom of=luks-keyfil bs=33554432 count=1 # User can change bs= to any number that is higher then 512bytes
gpg --symmetric --cipher-algo AES256 --output luke-keyfile.gpg luks-keyfile
```

We need to decrypt the key that we just created. So we can format the disk with **cryptsetup**
```
gpg --decrypt --output /tmp/luks-keyfile luks-keyfile.gpg
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 /dev/[root_pratition] --key-file=/tmp/luks-keyfile
```

After that we can open the drive with **cryptsetyp** and in this case we have now "rename" the /dev/[root_pratition] to **cryptroot**
```
cryptsetup open /dev/[root_partition] cryptroot --key-file=/tmp/luks-keyfile
```

After you have finished with the encryption process you can remove the key file in **/tmp/luks-keyfile**, to securely delete it use:
#### Caution do not delete the luks-keyfile in /media/sda2!
```
shred -u /tmp/luks-keyfile
```

And now you can Change directory back to Livecd root with "cd" and now you should be able to mount all the necessary file system for the root_main_drive

### Now we can start to format the partition for usage

##### For swap:
```
mkswap /dev/mapper/cryptswap
swapon /dev/mapper/cryptswap
```
#### For Root:
```
mkdir -p /mnt/root
mkfs.btrfs -L BTROOT /dev/mapper/cryptroot
mount -t btrfs -o defaults,noatime,compress=lzo /dev/mapper/cryptroot /mnt/root
```
now we can create sub volumes for btrfs.
```
btrfs subvolume create /mnt/root/activeroot
btrfs subvolume create /mnt/root/home
btrfs subvolume create /mnt/root/etc
btrfs subvolume create /mnt/root/var
btrfs subvolume create /mnt/root/log
btrfs subvolume create /mnt/root/tmp
```
Then we need to create directory for the home, etc, var, log and tmp in directory /mnt/gentoo/.
```
mkdir /mnt/gentoo/home
mkdir /mnt/gentoo/etc
mkdir /mnt/gentoo/var
mkdir /mnt/gentoo/log
mkdir /mnt/gentoo/tmp
```
now we can mount the cryptroot subvolumes to /mnt/gentoo/
```
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=activeroot /dev/mapper/cryptroot /mnt/gentoo/
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=home /dev/mapper/cryptroot /mnt/gentoo/home
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=etc /dev/mapper/cryptroot /mnt/gentoo/etc
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=var /dev/mapper/cryptroot /mnt/gentoo/var
mount -t btrfs -o defaults,noatime,compress=lzo,subvol=log /dev/mapper/cryptroot /mnt/gentoo/log
mount -t btrfs -o defaults,noatime,nosuid,noexec,nodev,compress=lzo,subvol=tmp /dev/mapper/cryptroot /mnt/gentoo/tmp
```

# Now we will edit in chroot
This should be done before the kernel compile.
example picture of disk config to change for dracut.conf
```
sda
├──sda1     BDF2-0139
└──sda2     0e86bef-30f8-4e3b-ae35-3fa2c6ae705b # UUID=BOOT_KEY_PARTITION_UUID
nvme0n1
└─nvme0n1p1 4bb45bd6-9ed9-44b3-b547-b411079f043b # PARTITION_FOR_ROOT 
  └─root    cb070f9e-da0e-4bc5-825c-b01bb2707704
```
we need to add configurations to dracut in /etc/dracut.conf
```
add_dracutmodules+=" crypt crypt-gpg dm rootfs-block " # This is for GPG key config
kernel_cmdline+=" root=LABEL=crypt rd.luks.uuid=PARTITION_FOR_ROOT rd.luks.key=/crypt_key.luks.gpg:UUID=BOOT_KEY_PARTITION_UUID "
```

extracting the initramfs the user should cd to /usr/src/initramfs
```
/usr/lib/dracut/skipcpio /boot/initramfs-6.1.28-gentoo-initramfs.img | zcat | cpio -ivd
```

You should do it when you gone build the kernel.
**Embedding a directory**
With the _initramfs_ unpacked in /usr/src/initramfs, the kernel can be configured to embed it:
```
General Setup --->
[*] Initial RAM filesystem and RAM disk (initramfs/initrd) support
    (/usr/src/initramfs) Initramfs source file(s)
[*]   Support initial ramdisk/ramfs compressed using gzip
```
