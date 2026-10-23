# argus: Ubuntu Server with cloud-init

argus is a Raspberry Pi 5 (8 GB). It runs a single-node k3s with Cilium for
Loki, Grafana and Mimir. This document tells you how to install argus. It also
tells you how to recover argus when the microSD card fails.

Written 2026-10-18.

## Why Ubuntu, not Raspberry Pi OS

Cilium does not start on Raspberry Pi OS. The Raspberry Pi kernels have no BTF
(`CONFIG_DEBUG_INFO_BTF` is not set), so the Cilium agent cannot load its socket
LB programs. The Pi 5 kernels also cause a crash of cilium-envoy (tcmalloc):

- `kernel_2712.img` has 16K pages.
- `kernel8.img` has only 39-bit virtual addresses.

The Ubuntu kernel for the Pi (`linux-raspi`) does not have these problems. The
values come from `/boot/config-7.0.0-1022-raspi` (Ubuntu 26.04, package
`linux-modules-7.0.0-1022-raspi`, examined 2026-10-18):

| Kernel option           | Raspberry Pi OS | Ubuntu 26.04 `linux-raspi`   |
| ----------------------- | --------------- | ---------------------------- |
| `CONFIG_DEBUG_INFO_BTF` | not set         | `y`                          |
| Page size               | 16K or 4K       | 4K (`CONFIG_ARM64_4K_PAGES`) |
| `CONFIG_ARM64_VA_BITS`  | 47 or 39        | 48                           |
| `CONFIG_INET_UDP_DIAG`  | not set         | `m`                          |
| `vxlan`, `geneve`       | -               | `m`, in `linux-modules`      |
| `iscsi_tcp` (Longhorn)  | -               | `m`, in `linux-modules`      |

The modules are in the base package, not in `linux-modules-extra-raspi`. Each
Ubuntu kernel update includes BTF.

## Decisions

- **Image:** Ubuntu Server 26.04.1 LTS for Raspberry Pi
  (`ubuntu-26.04.1-preinstalled-server-arm64+raspi.img.xz`). Ubuntu supports
  this release until 2031.
- **Boot:** argus starts from the microSD card. The EEPROM stays as it is. The
  default boot order already starts from the SD card.
- **Data:** the NVMe is a data disk only. The `lvm` role mounts
  `/var/lib/rancher` and `/var/lib/longhorn` from it. The SD card contains only
  the OS, so it is easy to replace.
- **cloud-init:** the files are in `cloud-init/argus/` in this repository. They
  contain only the settings that Ansible needs before it can connect. Ansible
  does all other configuration.

| Item                           | cloud-init  | Ansible role            |
| ------------------------------ | ----------- | ----------------------- |
| Hostname                       | yes         |                         |
| Admin user `joge`, SSH key     | yes         |                         |
| Passwordless sudo              | yes (first) | `common` (again)        |
| No password SSH, no root login | yes         |                         |
| Network (DHCP)                 | yes         |                         |
| First-boot network fix         | yes         |                         |
| Packages, upgrades             |             | `common`                |
| Memory cgroup                  | not needed  | not needed              |
| NVMe LVM and mounts            |             | `lvm`                   |
| open-iscsi                     |             | `longhorn_requirements` |
| k3s, Cilium                    |             | `k3s`                   |

There is no root user with a password and no root SSH login. The user `joge`
with sudo and an SSH key is enough.

## Step 1: Flash the microSD card

1. Optional: keep an image of the old card:

   ```bash
   sudo dd if=/dev/sda of=~/argus-rpios-$(date +%F).img bs=4M status=progress
   ```

2. Download the image and examine the checksum:

   ```bash
   cd ~/Downloads
   base=https://cdimage.ubuntu.com/releases/26.04.1/release
   img=ubuntu-26.04.1-preinstalled-server-arm64+raspi.img.xz
   curl -LO "$base/$img"
   curl -LO "$base/SHA256SUMS"
   sha256sum -c --ignore-missing SHA256SUMS
   ```

3. Unmount all partitions of the card, then write the image:

   ```bash
   lsblk -o NAME,SIZE,RM,TRAN,LABEL,MOUNTPOINTS
   # Do this for each mounted partition of the card.
   udisksctl unmount -b /dev/sda1
   xzcat "$img" | sudo dd of=/dev/sda bs=4M conv=fsync status=progress
   ```

4. Remove the card and attach it again. The system mounts the FAT partition
   `system-boot`. Copy the three cloud-init files onto it. They replace the
   files of the image:

   ```bash
   boot=/run/media/$USER/system-boot
   cp cloud-init/argus/{user-data,network-config,meta-data} "$boot/"
   diff -r cloud-init/argus "$boot" | grep -v '^Only in'
   sync && udisksctl unmount -b /dev/sda1
   ```

## Step 2: First boot

1. Put the card into argus and start it. The first boot takes some minutes.
   During this time, cloud-init runs and the root partition increases to the
   full size of the card.

2. Remove the old host key, then connect:

   ```bash
   ssh-keygen -R argus.lan; ssh-keygen -R 192.168.2.180
   ssh argus 'cloud-init status --wait --long'
   ```

   The result must be `status: done`.

3. Delete the fact cache. `ansible.cfg` keeps facts for one hour in
   `/tmp/ansible_facts`:

   ```bash
   rm -f /tmp/ansible_facts/argus
   ```

4. Examine the kernel:

   ```bash
   ssh argus 'uname -r; getconf PAGESIZE; ls -l /sys/kernel/btf/vmlinux; lsblk; cat /sys/fs/cgroup/cgroup.controllers'
   ```

   | Check                     | Expected          |
   | ------------------------- | ----------------- |
   | `uname -r`                | ends in `-raspi`  |
   | `getconf PAGESIZE`        | `4096`            |
   | `/sys/kernel/btf/vmlinux` | exists            |
   | `lsblk`                   | shows `nvme0n1`   |
   | `cgroup.controllers`      | contains `memory` |

## Step 3: Ansible

The roles run in the order of `site.yml`: `common`, then `lvm`, `k3s`,
`longhorn_requirements`.

```bash
cd ansible
ansible-playbook site.yml --limit argus --syntax-check
ansible-playbook site.yml --limit argus --check
ansible-playbook site.yml --limit argus
# The second run must show changed=0.
ansible-playbook site.yml --limit argus
```

Then examine Cilium:

```bash
kubectl --kubeconfig ~/.kube/argus.yaml get nodes -o wide
kubectl --kubeconfig ~/.kube/argus.yaml -n kube-system exec ds/cilium -- cilium-dbg status
kubectl --kubeconfig ~/.kube/argus.yaml -n kube-system logs ds/cilium | grep -i btf
```

The node must be `Ready`. The log must not show `no BTF found`.

## Recovery: the microSD card failed

The NVMe contains the data. The SD card contains only the OS. To recover:

1. Do steps 1 and 2 with a new card.
2. Run Ansible as in step 3. The `lvm` role finds the volume group `data` on the
   NVMe and mounts it again. k3s starts with its old state from
   `/var/lib/rancher`.
3. A possible problem is the node password. k3s keeps it in
   `/etc/rancher/node/password`, on the SD card. The cluster keeps a copy in the
   secret `kube-system/argus.node-password.k3s`, on the NVMe. A new card has a
   new password. If the k3s log shows "Node password rejected", do these
   commands:

   ```bash
   sudo k3s kubectl -n kube-system delete secret argus.node-password.k3s
   sudo systemctl restart k3s
   ```

To make recovery shorter, keep a copy of the working card (step 1.1) after the
first good run.

## Risks

- **cloud-init runs one time.** A change to `cloud-init/argus/` has no effect on
  a running argus. It applies at the next flash. Put all changes that must get
  to the running host into Ansible.
- **Cilium on Ubuntu `linux-raspi` has no test yet.** If Cilium does not start,
  read the `cilium-agent` log first. The BTF error must not be in the log.
