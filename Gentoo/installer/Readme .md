First we need to format the disk to look something like this:

```
/dev/sda #boot drive
├── /dev/sda1      [EFI]   /efi      1 GB         fat32       Bootloader
└── /dev/sda2      [BOOTX] /boot     1 GB         ext4        Bootloader support files, kernel and initramfs

/dev/nvme0n1 # root drive
 └── /dev/nvme0n1p1 [ROOT]  (root)    ->END        luks        Encrypted root device, mapped to the name 'root'
      └──  /dev/mapper/root /         ->END        btrfs       root filesystem
                            /home     subvolume                Subvolume created for the home directory
```

but for us we also use swap partition that is encrypted with plain random key.
After disk peparation we need to create filsystem for /dev/sda1 and /dev/sda2 (our boot drive) 

```
mkfs.vfat -F32 /dev/sda1
mkfs.ext4 /dev/sda2
```
After sucefully create filesystem we need to mounnt /dev/sda2 to /media/sda2 so we need to create a mount point in /media/
```
mkddir /media/sda2
```
And after mount the device to /media/sda2
```
mount /dev/sda2 /meda/sda2
```
Now we need to co to the directory to genereate a random keyfile to use.
```
cd /media/sda2
```
Key generation for GPG symmetric keyfile
```
dd if=/dev/urandom of=luks-keyfil bs=8388608 count=1
gpg --symmetric --cipher-algo AES256 --output luke-keyfile.gpg luks-keyfile
```
And now we need to decrypt the key that we just created.
```
gpg --decrypt --output /tmp/luks-keyfile luks-keyfile.gpg
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 /dev/[root_pratition] --key-file=/tmp/luks-keyfile
```
To open the disk use the following command.
```
cryptsetup open /dev/[root_partition] --key-file=/tmp/luks-keyfile
```
After you have finished open the drive dont forget to remove the key file in /tmp/luks-keyfile, to securly delete it use:
```
shred -u /tmp/luks-keyfile
```
And now you can Change directrory back to Livecd root with "cd" and now you should be able to mount all the neccsary file system for the root_main_drive
