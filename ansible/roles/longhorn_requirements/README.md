<!-- BEGIN_ANSIBLE_DOCS -->

# Ansible Role: longhorn_requirements

prepare a node for Longhorn (iSCSI, NFS client, multipath)

Tags: longhorn, storage, homelab

## Requirements

| Platform | Versions |
| -------- | -------- |
| Ubuntu   | noble    |
| Debian   | trixie   |

## Role Arguments

### Entrypoint: main

Prepare a node for Longhorn.

Installs `open-iscsi` and `nfs-common`, loads `iscsi_tcp` now and on boot, and
starts and enables `iscsid`.

When `multipath-tools` is installed, blacklists `^sd[a-z0-9]+` in
`/etc/multipath.conf` and restarts `multipathd`.

Longhorn itself (the Helm release, the storage classes) is not in this role.

| Option | Description | Type | Required | Default |
| ------ | ----------- | ---- | -------- | ------- |

## Dependencies

None.

## Example Playbook

```yaml
- hosts: all
  tasks:
    - name: Importing role: longhorn_requirements
      ansible.builtin.import_role:
        name: longhorn_requirements
      vars:
```

## License

MIT

## Author and Project Information

Jonathan Gerdes

<!-- END_ANSIBLE_DOCS -->
