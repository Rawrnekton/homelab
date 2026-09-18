<!-- BEGIN_ANSIBLE_DOCS -->

# Ansible Role: iscsi_client

log in to iSCSI targets and mount their LUNs

Tags: iscsi, storage, homelab

## Requirements

| Platform | Versions     |
| -------- | ------------ |
| Ubuntu   | 22.04, 24.04 |

## Role Arguments

### Entrypoint: main

Log in to iSCSI targets and mount their LUNs.

Installs the open-iscsi initiator, creates a node record for every configured
(portal, target) pair, logs in with CHAP where credentials are given, formats
the LUN once and mounts it persistently.

The role deliberately avoids `sendtargets` discovery, because that call resets
every node record it touches on every run and would wipe the CHAP credentials
and `node.startup` it wrote before.

| Option               | Description                                                                                                                                                                 | Type                                            | Required | Default |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- | -------- | ------- |
| iscsi_client_targets | The portals to log in to, each with the targets to mount from it. One entry is one portal; its `targets` list holds one entry per IQN. A LUN is always LUN 0 of its target. | list of dicts of 'iscsi_client_targets' options | no       | []      |

#### Options for main > iscsi_client_targets

| Option  | Description                                                                                                                                                                  | Type                               | Required | Default |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- | -------- | ------- |
| name    | Label for the portal, used in task output only.                                                                                                                              | str                                | yes      |         |
| portal  | IP address or FQDN of the portal. An FQDN is resolved on the managed host, not on the controller, so split-horizon DNS gives the initiator the address it will actually use. | str                                | yes      |         |
| port    | TCP port of the portal. `3260` when omitted.                                                                                                                                 | int                                | no       |         |
| targets | The targets to log in to on this portal.                                                                                                                                     | list of dicts of 'targets' options | yes      |         |

#### Options for main > iscsi_client_targets > targets

| Option              | Description                                                                                                                                             | Type | Required | Default |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- | -------- | ------- |
| human_readable_name | Label for the target, used in task output only.                                                                                                         | str  | yes      |         |
| name                | The IQN of the target.                                                                                                                                  | str  | yes      |         |
| user                | CHAP user name. Switches CHAP on for this target. Must be set together with `password`.                                                                 | str  | no       |         |
| password            | CHAP password. Must be set together with `user`.                                                                                                        | str  | no       |         |
| mountpoint          | Absolute path where LUN 0 of the target is mounted. Created when missing, written to `/etc/fstab` with `_netdev` and `nofail`.                          | path | yes      |         |
| fstype              | Filesystem to create on an unformatted LUN and to mount it with. `ext4` when omitted. The role never reformats a LUN that already carries a filesystem. | str  | no       |         |

## Dependencies

None.

## Example Playbook

```
- hosts: all
  tasks:
    - name: Importing role: iscsi_client
      ansible.builtin.import_role:
        name: iscsi_client
      vars:
```

## License

MIT

## Author and Project Information

Jonathan Gerdes

<!-- END_ANSIBLE_DOCS -->

## Usage

```yaml
- name: Mount the iSCSI LUNs on the gateway
  hosts: gateway
  become: true
  roles:
    - role: iscsi_client
```

The role installs `open-iscsi`, creates a node record for every configured
(portal, target) pair, logs in with CHAP where credentials are given, formats an
unformatted LUN and mounts it through `/etc/fstab` with `_netdev` and `nofail`.
A re-run is a no-op, and a new target in the list is logged in without touching
the sessions that already exist.

The role never runs `sendtargets` discovery: that call resets every node record
it touches and would wipe the CHAP credentials and `node.startup` the role wrote
before.

## Testing

The role is covered by four Molecule scenarios. One of them runs on the Ansible
controller, the other three in Docker, against an LIO target that the scenarios
build themselves.

| Task                          | Covers                                                                   |
| ----------------------------- | ------------------------------------------------------------------------ |
| `mise run fast`               | `local`, then one portal with two CHAP targets on the role defaults.     |
| `mise run full`               | All four scenarios: every portal shape and the re-run with a new target. |
| `mise run scenario <name>...` | The named scenarios, for iterating.                                      |

`CLAUDE.md` holds the full scenario table, what the Docker pair needs from the
host, and the reasons behind it.

## License

MIT
