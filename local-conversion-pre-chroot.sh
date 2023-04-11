#!/bin/bash
#
# Converts a Linode instance for LUKS full disk encryption.
# Assumes prep-luks-linode.sh has been run to prepare.
# Tested with Ubuntu 22.04 on a newly installed machine.
#
# Assumes:
# - sda = running root
# - sdb = swap
# - sdc = clone of sda
# - sdd = boot drive (raw)
#
# TODO: consider switching this to use ansible?

## Do this before the clone?  (Or after switching the rootfs?)

OLDROOTDEV=`blkid -s UUID -o value /dev/sda`
SWAPDEV=`blkid -s UUID -o value /dev/sdb`
NEWROOTDEV=`blkid -s UUID -o value /dev/sdc`

e2fsck -f /dev/sdc
resize2fs -M /dev/sdc
echo "Please enter new root encryption password"
echo "About to do cryptsetup-reencrypt which may take awhile"
cryptsetup-reencrypt /dev/sdc --new --reduce-device-size 16M --type=luks2
echo "Done with cryptsetup-reencrypt"

cat >> /etc/crypttab <<EOF
rootfs UUID=$NEWROOTDEV none luks,discard
swap   /dev/sdb /dev/urandom	swap,cipher=aes-xts-plain64,size=256
EOF

# Setup the boot partition
printf "n\np\n1\n\n\np\n\nw\n" | fdisk --wipe always /dev/sdd
mkfs.ext4 /dev/sdd1
mkdir /mnt/boot
mount /dev/sdd1  /mnt/boot/
cp -a /boot/* /mnt/boot

echo "Need password again to mount the encrypted filesystem"
cryptsetup open /dev/sdc rootfs
# Now at /dev/mapper/rootfs
e2fsck -f /dev/mapper/rootfs
resize2fs /dev/mapper/rootfs

cryptsetup open /dev/sdc rootfs
# Now at /dev/mapper/rootfs
e2fsck -f /dev/mapper/rootfs
resize2fs /dev/mapper/rootfs

mkdir /mnt/root /mnt/boot
mount /dev/mapper/rootfs /mnt/root/
for x in /dev /dev/pts /sys /proc /run /sys/kernel/security \
    /dev/shm /run/lock /sys/fs/cgroup /sys/fs/pstore /sys/fs/bpf \
    /proc/sys/fs/binfmt_misc /dev/mqueue /dev/hugepages /sys/kernel/debug \
    /sys/kernel/tracing /sys/fs/fuse/connections /sys/kernel/config /run/user/0 \
    /run/credentials/systemd-sysusers.service /proc/sys/fs/binfmt_misc /tmp \
	 ; do
   mount --bind $x /mnt/root$x
done
mount --bind /mnt/boot /mnt/root/boot
echo "Now to run local conversion script post-chroot"
chroot /mnt/root /tmp/local-conversion-post-chroot.sh

