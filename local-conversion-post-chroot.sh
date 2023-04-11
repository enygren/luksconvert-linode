#!/bin/bash

BOOTDEV=`blkid -s UUID -o value /dev/sdd1`
NEWROOTDEV=`blkid -s UUID -o value /dev/sdc`

cat >> /etc/crypttab <<EOF
rootfs UUID=$NEWROOTDEV none luks,discard
swap   /dev/sdb /dev/urandom	swap,cipher=aes-xts-plain64,size=256
EOF

sed -e 's:/dev/sda:/dev/mapper/rootfs:' -e 's:/dev/sdb:/dev/mapper/swap:'  -i /etc/fstab
echo "UUID=$BOOTDEV       /boot           ext4    errors=remount-ro 0     2" >> /etc/fstab

apt-get update
apt-get dist-upgrade -u -y
apt-get install -y dropbear-initramfs
cp ~/.ssh/authorized_keys /etc/dropbear/initramfs/
sed -i  's/#DROPBEAR_OPTIONS=/DROPBEAR_OPTIONS="-I 600 -j -k -p 2222 -s"/' /etc/dropbear/initramfs/dropbear.conf

update-initramfs -u
grub-install /dev/sdd
update-grub

swapoff /dev/sdb
echo "Converting sdb swap partition to LUKS forcibly"
TEMPKEY=`dd if=/dev/urandom bs=1k count=1 | sha256sum`
printf "YES\n$TEMPKEY\n$TEMPKEY\n" | cryptsetup  --use-urandom --label=swap --master-key-file=/dev/urandom  luksFormat /dev/sdb
