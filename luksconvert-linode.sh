#!/bin/bash
#
# Creates a Linode instance and converts it to full disk encryption.
# Downside is that at least for now it wastes some space.
# Approach is to:
# * shrink the OS drive (sda)
# * clone the OS drive to make a drive we can encrypt (sdc)
# * create a (raw) boot drive (sdd)
# * expand the OS drive we're going to encrypt
# * use the original OS (sda) to boot into to convert sdc and make sdd bootable
# * boot into sdd, where either lish or dropbear-ssh (port 2222) can be used to unlock
#
# TODO: Delete swap to free up even more space
# TODO: See if there is a way to not waste the space from sda
# TODO: Factor out configuration
#
# Dependencies:
#     pip3 install linode-cli  
#
# Example:
#   ./luksconvert-linode.sh lukstest18 

# Configuration -- change if needed
LABEL=$1
AUTHUSER=$USER
REGION=us-east
NODETYPE=g6-nanode-1
TAGS=test

DISKLABEL="Ubuntu 22.04 LTS Disk"  # Original Root Disk
MINSIZE=3400  # Size to shrink the original root disk down to
BOOTSIZE=1024  # Size of the boot partition (in MB)

function wait_for_status
{
    STATUS=`linode-cli linodes ls --label $1 --json | jq -r '.[0].status'`
    while [ _$STATUS != _$2 ]; do
	sleep 5
	STATUS=`linode-cli linodes ls --label $1 --json | jq -r '.[0].status'`
	echo 1>&2 "Status is $STATUS, waiting for $2"
    done
}

# Waits for the disk to have a valid size then returns it
function disk_size
{
    DISKSIZE=`linode-cli linodes disk-view --json $1 $2 | jq -r '.[0].size'`
    while [ $? != 0 -o _$DISKSIZE == _null ]; do
	sleep 1
	echo 1>&2 "Waiting for disk size (last got $DISKSIZE) for disk $2 on linode $1" 
	DISKSIZE=`linode-cli linodes disk-view --json $1 $2 | jq -r '.[0].size'`
    done
    echo $DISKSIZE
}

function wait_for_reachable
{
    until echo | nc -w 5 -z $1 $2 ; do
	echo Waiting for $1 to be reachable on port $2
	sleep 5
    done
}

if [ _$1 == _ ]; then
    echo "No label specified"
    exit -1
fi

linode-cli linodes create \
  --image 'linode/ubuntu22.04' \
  --region $REGION \
  --type $NODETYPE \
  --label $LABEL \
  --tags $TAGS \
  --root_pass `ssh-askpass "Linode VM root password"` \
  --authorized_users $AUTHUSER \
  --booted true \
  --backups_enabled false \
  --private_ip false

INSTANCE=`linode-cli linodes ls --label $LABEL --json`
INSTANCE_IPV6=`echo $INSTANCE | jq -r '.[0].ipv6' | sed -e 's:/128::'`
INSTANCE_ID=`echo $INSTANCE | jq -r '.[0].id'`
LINODE_ID=$INSTANCE_ID

echo "Instance details: $INSTANCE_ID $INSTANCE_IPV6"
echo $INSTANCE

wait_for_status $LABEL running

linode-cli linodes shutdown $INSTANCE_ID
wait_for_status $LABEL offline

ROOT_DISK_ID=`linode-cli linodes disks-list --json --label="$DISKLABEL" $LINODE_ID | jq -r '.[0].id'`

# TODO: switch to a filter in jq instead?
SWAP_DISK_ID=`linode-cli linodes disks-list --json --label="512 MB Swap Image" $LINODE_ID | jq -r '.[0].id'`

OLDSIZE=`linode-cli linodes disks-list --json --label="$DISKLABEL" $LINODE_ID | jq -r '.[0].size'`

# Shrink the root filesystem so we can clone it
MINSIZE=3300
echo "Shrinking original root disk to $MINSIZE"
linode-cli linodes disk-resize --size $MINSIZE $LINODE_ID $ROOT_DISK_ID
sleep 3
echo "Now to wait for resize to complete"
while [ $(disk_size $LINODE_ID $ROOT_DISK_ID) -ne $MINSIZE ]; do echo "Waiting for resize to complete" ; sleep 5; done 

echo "Cloning root disk ($ROOT_DISK_ID)"
linode-cli linodes disk-clone $LINODE_ID $ROOT_DISK_ID
sleep 3
while [ _`linode-cli linodes disks-list --json --label="Copy of $DISKLABEL" $LINODE_ID | jq -r '.[0].status'` != _ready ]; do echo "Waiting for clone to complete" ; sleep 5; done

NEWSIZE=`expr $OLDSIZE - $MINSIZE - $BOOTSIZE`
CRYPTROOT_DISK_ID=`linode-cli linodes disks-list --json --label="Copy of $DISKLABEL" $LINODE_ID | jq -r '.[0].id'`

echo "About to resize the new cryptdisk ($CRYPTROOT_DISK_ID) to the max size ($NEWSIZE)"
until linode-cli linodes disk-resize --size $NEWSIZE $LINODE_ID $CRYPTROOT_DISK_ID ; do
    sleep 3
    echo "Trying again..."
done
sleep 3
while [ $(disk_size $LINODE_ID $CRYPTROOT_DISK_ID) -ne $NEWSIZE ]; do echo "Waiting for resize to complete" ; sleep 5; done

echo "Creating boot disk"
until linode-cli linodes disk-create --size $BOOTSIZE --filesystem raw --label Boot $LINODE_ID; do
    sleep 3
    echo "Trying again..."
done
sleep 3
while [ _`linode-cli linodes disks-list --json --label="Boot" $LINODE_ID | jq -r '.[0].status'` != _ready ]; do echo "Waiting for boot disk creation" ; sleep 5; done

BOOT_DISK_ID=`linode-cli linodes disks-list --json --label="Boot" $LINODE_ID | jq -r '.[0].id'`

BASE_CONFIG_ID=`linode-cli linodes configs-list --json $LINODE_ID | jq -r '.[0].id'`

# Update the initial configuration to add in the new disks
echo "Updating initial configuration ($BASE_CONFIG_ID) to add in new disks"
linode-cli linodes config-update \
	   --devices.sda.disk_id $ROOT_DISK_ID \
	   --devices.sdb.disk_id $SWAP_DISK_ID \
	   --devices.sdc.disk_id $CRYPTROOT_DISK_ID \
	   --devices.sdd.disk_id $BOOT_DISK_ID \
	   $LINODE_ID $BASE_CONFIG_ID

echo "Booting Linode to original configuration"
linode-cli linodes boot --config_id $BASE_CONFIG_ID $LINODE_ID

CRYPT_CONFIG_LABEL="Direct boot disk to encrypted Ubuntu"
linode-cli linodes config-create \
	   --kernel "linode/direct-disk" \
	   --label "$CRYPT_CONFIG_LABEL" \
	   --comments "sda is now an encrypted drive, sdb is encrypted swap, sdd1 is boot partition" \
	   --devices.sda.disk_id $CRYPTROOT_DISK_ID \
	   --devices.sdb.disk_id $SWAP_DISK_ID \
	   --devices.sdd.disk_id $BOOT_DISK_ID \
	   --root_device "/dev/sdd" \
	   $LINODE_ID
CRYPT_CONFIG_ID=`linode-cli linodes configs-list --json $LINODE_ID --label "$CRYPT_CONFIG_LABEL" | jq -r '.[0].id'`

### Copy over the conversion script and run it...
echo Running remote conversion script on $INSTANCE_IPV6
wait_for_status $LABEL running
wait_for_reachable $INSTANCE_IPV6 22
sleep 5
echo "Getting ssh host keys"
ssh-keyscan $INSTANCE_IPV6  >> ~/.ssh/known_hosts
echo "Copying over setup script"
scp local-conversion-pre-chroot.sh local-conversion-post-chroot.sh root@\[$INSTANCE_IPV6\]:/tmp/
echo "Running setup script"
ssh -tt root@$INSTANCE_IPV6 /tmp/local-conversion-pre-chroot.sh

echo Done, now booting into new OS...
linode-cli linodes shutdown $INSTANCE_ID
wait_for_status $LABEL offline

echo "Cleaning up: removing old base config ID"
linode-cli linodes config-delete $LINODE_ID $BASE_CONFIG_ID

linode-cli linodes boot --config_id $CRYPT_CONFIG_ID $LINODE_ID
wait_for_reachable $INSTANCE_IPV6 2222
echo "Now enter cryptoroot password to finish boot..."
ssh -tt root@$INSTANCE_IPV6 -p 2222 cryptroot-unlock

echo "Now boot should be finishing..."
wait_for_reachable $INSTANCE_IPV6 22
echo "Should be done now!"

