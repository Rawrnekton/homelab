# ThinkCentre hosts: Ubuntu cloud image with cloud-init

The hosts `olympus-1..3` and `heracles` are Lenovo ThinkCentre (x86, NVMe).
`olympus-1..3` are M710q with an Intel I219 network adapter. This document tells
you how to install them without a monitor, a keyboard or a boot stick. You
prepare the NVMe on the workstation, then you put it into the host.

`olympus-1..3` are the new names of `argo-1..3`. `heracles` is a node of
`olympus` with more compute, and it gets a taint. For a restore test of the
backups, you install the same machine with the name `restore-test`. Then you
install it again as `heracles`.

Written 2026-10-28.

## Why a cloud image, not the installer

The Ubuntu installer (also with autoinstall) must start from a second medium,
for example a USB stick. Then the host needs a change of the boot order. The
cloud image is a complete installed system. The script writes it directly to the
NVMe, and cloud-init configures it at the first boot. All files are in git.

The disadvantage: root is a plain partition, not a logical volume. The data is
on a volume group on a second partition, the same as on argus.

## Decisions

- **Image:** Ubuntu Server 26.04 LTS cloud image for amd64
  (`ubuntu-26.04-server-cloudimg-amd64.img`, qcow2) from
  `cloud-images.ubuntu.com`.
- **Boot:** the ESP of the image contains the UEFI fallback loader
  `EFI/BOOT/BOOTX64.EFI` (shim). The firmware starts it from a disk with no boot
  entry. If the NVMe is the only disk, you do not change the boot order. At the
  first boot, shim adds the boot entry `ubuntu`.
- **Data:** the partition `data` (p2) is empty. The `lvm` role makes the volume
  group on it. Free space in the volume group stays available, for example for
  an LVM CSI driver.
- **cloud-init:** the seed is in `/var/lib/cloud/seed/nocloud/` on the root
  partition. The script copies it there. It contains only the settings that
  Ansible needs before it can connect.

### Disk layout

| Partition | Size    | Content                | From          |
| --------- | ------- | ---------------------- | ------------- |
| p13       | 1 GiB   | `/boot`, label `BOOT`  | image         |
| p14       | 4 MiB   | BIOS boot              | image         |
| p15       | 106 MiB | ESP, label `UEFI`      | image         |
| p1        | 50 GiB  | `/`, `cloudimg-rootfs` | image, larger |
| p2        | rest    | GPT name `data`, empty | script        |

`/etc/fstab` and the kernel command line find the partitions by their labels.
Thus a host must have only one disk with this image.

### Kernel

The cloud image has `linux-virtual`. This is the `generic` kernel without
`linux-modules-extra`. The necessary modules are in the base package
`linux-modules` (examined 2026-10-28 on `7.0.0-31-generic`):

| Module         | Function                    | Package         |
| -------------- | --------------------------- | --------------- |
| `e1000e`       | network adapter (argo-1..3) | `linux-modules` |
| `iscsi_tcp`    | Longhorn, iSCSI             | `linux-modules` |
| `dm-thin-pool` | LVM thin volumes            | `linux-modules` |

If a host has a different network adapter, examine its driver first. Without the
driver, the host has no network, and cloud-init cannot complete.

### cloud-init files

| File                                    | Content                         |
| --------------------------------------- | ------------------------------- |
| `cloud-init/thinkcentre/user-data`      | user, SSH key, `growpart` off   |
| `cloud-init/thinkcentre/network-config` | DHCP on the first `en*` adapter |
| `cloud-init/<host>/meta-data`           | `instance-id`, `local-hostname` |

The differences to `cloud-init/argus/`:

- The hostname comes from `local-hostname` in `meta-data`. Thus one `user-data`
  is sufficient for all hosts.
- `growpart` is off. The root partition has a fixed size, and the partition
  `data` comes directly after it.
- `dhcp-identifier: mac`. Without it, the DHCP client ID comes from the
  machine-id, which changes at each install.
- The adapter has no fixed name. The match `en*` finds `enp0s31f6` (argo-1..3)
  and `eno1` (heracles).

| Item                           | cloud-init  | Ansible role            |
| ------------------------------ | ----------- | ----------------------- |
| Hostname                       | yes         |                         |
| Admin user `joge`, SSH key     | yes         |                         |
| Passwordless sudo              | yes (first) | `common` (again)        |
| No password SSH, no root login | yes         |                         |
| Network (DHCP)                 | yes         |                         |
| Root partition size            | script      |                         |
| Packages, upgrades             |             | `common`                |
| LVM on `data` and mounts       |             | `lvm`                   |
| open-iscsi                     |             | `longhorn_requirements` |
| k3s, Cilium                    |             | `k3s`                   |

## Step 0: One time on the workstation

1. Install `qemu-img`:

   ```bash
   sudo apt install qemu-utils
   ```

2. Make a DHCP reservation for each host, with the MAC address of its network
   adapter. On a running host, `ip -br link` shows the MAC address.

## Step 1: Prepare the NVMe

1. Put the NVMe into the USB case and connect it. Find its device name:

   ```bash
   lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,LABEL,MOUNTPOINTS
   ```

2. The desktop can mount old partitions automatically. Unmount each mounted
   partition of the NVMe:

   ```bash
   udisksctl unmount -b /dev/sda3
   ```

3. An old argo NVMe has the volume group `ubuntu-vg`. The workstation also has a
   `ubuntu-vg`. If `lsblk` shows logical volumes under the NVMe, deactivate them
   with the UUID, never with the name:

   ```bash
   sudo pvs -o pv_name,vg_name,vg_uuid
   sudo vgchange -an --select vg_uuid=<uuid of the NVMe>
   ```

4. Run the script. It shows the disk and asks for the device name before it
   deletes the data:

   ```bash
   scripts/prepare-disk.sh /dev/sda olympus-1
   ```

   The script does these steps:

   1. It stops if the device is not a USB disk, has a mounted partition, has
      active logical volumes, or does not have 512-byte sectors.
   2. It downloads the image to `~/.cache/homelab/cloud-images/` and examines
      the checksum. A cached image is used again if its checksum is correct.
   3. It deletes the old partition table and writes the image.
   4. It moves the backup GPT header to the end of the disk.
   5. It makes p1 50 GiB (`ROOT_SIZE_GIB`) and makes the filesystem larger.
   6. It makes p2 `data` with the rest of the disk.
   7. It copies the cloud-init seed to p1.

5. Disconnect the NVMe:

   ```bash
   udisksctl power-off -b /dev/sda
   ```

## Step 2: First boot

1. Put the NVMe into the host. Disconnect all other disks and USB sticks. Start
   the host. The first boot takes approximately one minute.

2. Remove the old host key, then connect:

   ```bash
   ssh-keygen -R olympus-1; ssh-keygen -R olympus-1.lan
   ssh joge@olympus-1 'cloud-init status --wait --long'
   ```

   The result must be `status: done`.

3. Delete the fact cache:

   ```bash
   rm -f /tmp/ansible_facts/olympus-1
   ```

4. Examine the host:

   ```bash
   ssh joge@olympus-1 'hostname; uname -r; ip -br addr; lsblk -o NAME,SIZE,PARTLABEL,MOUNTPOINTS; df -h /; ls /sys/kernel/btf/vmlinux'
   ```

   | Check                     | Expected                          |
   | ------------------------- | --------------------------------- |
   | `hostname`                | `olympus-1`                       |
   | `uname -r`                | ends in `-generic`                |
   | `ip -br addr`             | the reserved IPv4 address         |
   | `lsblk`                   | `nvme0n1p2` with PARTLABEL `data` |
   | `df -h /`                 | approximately 49G                 |
   | `/sys/kernel/btf/vmlinux` | exists                            |

## Step 3: Ansible

The host must be in the inventory. The `lvm` role needs the partition `data` as
the device of the volume group. Example for `host_vars/<host>/lvm.yml`:

```yaml
lvm_volume_groups:
  - vg: data
    devices:
      - /dev/disk/by-partlabel/data

lvm_volumes:
  - vg: data
    lv: rancher
    size: 50g
    fstype: ext4
    mountpoint: /var/lib/rancher
```

`community.general.lvg` resolves the symlink, thus a second run changes nothing.
Then run the playbook as for argus:

```bash
cd ansible
ansible-playbook site.yml --limit olympus-1 --syntax-check
ansible-playbook site.yml --limit olympus-1 --check
ansible-playbook site.yml --limit olympus-1
# The second run must show changed=0.
ansible-playbook site.yml --limit olympus-1
```

## Reinstall a host

Do steps 1 to 3 again. The script deletes all data on the NVMe, also the volume
group `data`.

If the host is a node of a cluster with more than one node, the cluster keeps
its old node password. If the k3s log shows "Node password rejected", delete the
secret on a different node:

```bash
sudo k3s kubectl -n kube-system delete secret olympus-1.node-password.k3s
```

## Risks

- **cloud-init runs one time.** A change to `cloud-init/` has no effect on a
  running host. It applies at the next install. Put all changes that must get to
  a running host into Ansible.
- **The first boot on x86 has no test yet.** If the host gets no IPv4 address,
  connect a monitor and examine
  `journalctl -b -u systemd-networkd -u cloud-init-local`.
- **The image changes.** `release` always points to the newest build. Two hosts
  that you prepare on different days can have different package versions. The
  `common` role installs the updates.
