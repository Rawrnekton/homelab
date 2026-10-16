<!-- BEGIN_ANSIBLE_DOCS -->

# Ansible Role: lvm

create and grow LVM volume groups and logical volumes

Tags: lvm, storage, homelab

## Requirements

| Platform | Versions |
| -------- | -------- |
| Ubuntu   | noble    |
| Debian   | trixie   |

## Role Arguments

### Entrypoint: main

Create and grow LVM volume groups and logical volumes, and mount them.

Installs `lvm2`, creates the volume groups of `lvm_volume_groups`, then creates
or grows the logical volumes of `lvm_volumes`, puts a filesystem on them and
mounts them through `/etc/fstab`.

The role only adds and grows. It never shrinks or removes a logical volume,
never removes a physical volume from a volume group, and never formats a device
that already holds a filesystem. A removed entry is left on the host as it is.

A smaller `size` than the current one fails the run with the message of
`community.general.lvol` and changes nothing.

| Option            | Description                                                                                                                                                                                                                                                              | Type                                                                                 | Required | Default |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------ | -------- | ------- |
| lvm_volume_groups | Volume groups that must exist. Each device becomes a physical volume of the group, as the whole device; the role does not partition. A device that is in the group on the host but not in the list stays in the group. A device added to the list is added to the group. | list of dicts of `lvm_volume_groups` [options](#options-for-main--lvm_volume_groups) | no       | `[]`    |
| lvm_volumes       | Logical volumes that must exist with at least the given size, in list order. The volume group must exist, from `lvm_volume_groups` or from the installer.                                                                                                                | list of dicts of `lvm_volumes` [options](#options-for-main--lvm_volumes)             | no       | `[]`    |

#### Options for main > lvm_volume_groups

| Option  | Description                                                                                                                                                              | Type          | Required | Default |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------- | -------- | ------- |
| vg      | Name of the volume group, for example `data`.                                                                                                                            | str           | yes      |         |
| devices | Absolute device paths, for example `/dev/disk/by-id/nvme-CT1000P310SSD2_253151E4F6C8`. A symlink is resolved, so a `by-id` path and the kernel name are the same device. | list of `str` | yes      |         |

#### Options for main > lvm_volumes

| Option     | Description                                                                                                                                                                                                                                          | Type | Required | Default |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- | -------- | ------- |
| vg         | Name of the volume group that holds the logical volume.                                                                                                                                                                                              | str  | yes      |         |
| lv         | Name of the logical volume. The device is `/dev/<vg>/<lv>`.                                                                                                                                                                                          | str  | yes      |         |
| size       | Absolute size with a unit, one of `k m g t p e`, for example `100g`. The logical volume is created with this size or grown to it. Relative sizes (`+10g`) and percentages (`50%FREE`) are rejected. They grow the volume again on every run.         | str  | yes      |         |
| resizefs   | Grow the filesystem together with the logical volume, also a filesystem the role did not create (the root filesystem). Set `false` for a volume without a filesystem. `fsadm` finds no filesystem to grow there and the resize fails.                | bool | no       | `True`  |
| fstype     | Filesystem to create on the logical volume when it has none. Without it, the role does not touch the content of the volume.                                                                                                                          | str  | no       |         |
| mountpoint | Absolute path to mount the logical volume on. Needs `fstype`. The line in `/etc/fstab` is `/dev/<vg>/<lv> <mountpoint> <fstype> defaults 0 0`. The role refuses to mount on a directory that is not empty, because the mount would hide its content. | path | no       |         |

#### Choices for main > lvm_volumes > fstype

| Choice |
| ------ |
| ext4   |

## Dependencies

None.

## Example Playbook

```yaml
- hosts: all
  tasks:
    - name: Importing role: lvm
      ansible.builtin.import_role:
        name: lvm
      vars:
```

## License

MIT

## Author and Project Information

Jonathan Gerdes

<!-- END_ANSIBLE_DOCS -->

## Usage

```yaml
- name: Provision argo Cluster
  hosts: argo
  become: true
  roles:
    - { role: lvm, tags: [lvm] }
```

```yaml
# host_vars/argus/lvm.yml
lvm_volume_groups:
  - vg: data
    devices:
      - /dev/disk/by-id/nvme-CT1000P310SSD2_253151E4F6C8
lvm_volumes:
  - vg: data
    lv: rancher
    size: 100g
    fstype: ext4
    mountpoint: /var/lib/rancher
```

## Tests

`mise run fast` runs the contract and the argus shape, `mise run full` every
scenario. The docker scenarios need privileged containers and attach loop
devices on the host that runs them; `molecule/resources/prepare.yml` explains
how they stay away from the disks of that host, and `cleanup.yml` how to detach
what a killed run left behind.
