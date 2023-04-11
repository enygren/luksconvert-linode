
_Warning: This is an unofficial capability that is not currently a supported use case by Linode. Use at your own risk. As an example, you won't be able to use Linode backup features and the various Linode "helpers" will no longer be able to assist in maintaining your instance._

Creates a Linode instance and converts it to full disk encryption.
Downside is that at least for now it wastes some space.
Approach is to:
* create a new Linode instance
* shrink the OS drive (sda)
* clone the OS drive to make a drive we can encrypt (sdc)
* create a (raw) boot drive (sdd)
* expand the OS drive we're going to encrypt
* use the original OS (sda) to boot into to convert sdc and make sdd bootable
* boot into sdd, where either lish or dropbear-ssh (port 2222) can be used to unlock

Note that this leaves some extra space (eg, 3.3GB currently) unused on the host.
In the future it may be preferable to reclaim this.

Note also that the bootloader partition (which contains
the kernel and initramdisk) is not encrypted.  SSH'ing into the initramdisk
is needed on each bootup to decrypt the root partition and resume boot.

As another example, see [https://github.com/kitknox/lkeluks](https://github.com/kitknox/lkeluks) which converts LKE worker node.


Dependencies:

```
pip3 install linode-cli
```

Example:

```
  ./luksconvert-linode.sh lukstest18 
```

and then to unlock the machine on each boot:

```
   ssh instance -l root -p 2222 -tt cryptroot-unlock
```
