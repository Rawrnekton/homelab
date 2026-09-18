# iscsi_client role

Ansible role that logs a host in to iSCSI targets and mounts their LUNs. In the
homelab it mounts the two Garage volumes the WD NAS serves to the gateway.

Read `../../CLAUDE.md` first; this file only holds what applies to this role.

## Scope (locked 2026-09-18)

The 2026-07 review scored this role 8 of 10 and asked for polish only. The
rework brought it to the standard without adding a feature. The role was renamed
from `iscsi-client` to `iscsi_client`, because ansible-lint rejects a hyphen in
a role name; `site.yml` and the `group_vars` file moved with it.

### In

- Install `open-iscsi`, run `iscsid`, enable the boot-time login service
- Resolve a portal FQDN on the managed host, not on the controller
- One node record per (portal, target) pair, written without discovery
- CHAP per target, switched on by `user` + `password`
- Automatic login at boot (`node.startup = automatic`)
- Wait for the by-path device of LUN 0, format it once (`ext4` unless `fstype`
  says otherwise), mount it through `/etc/fstab` with `_netdev` and `nofail`,
  mode `0750` on the mountpoint
- A re-run is a no-op; a new target in the list is logged in without touching
  the sessions that exist
- Input contract in `meta/argument_specs.yml` plus the cross-field rules in
  `tasks/validate-variables.yml`

### Out

- `sendtargets` discovery (see the design notes for why)
- Uninstall, logout, or removing a target that left the list: the role only
  adds. What was mounted stays mounted
- LUNs other than 0, and more than one LUN per target
- Multipath, interface binding (`iscsiadm -m iface`)
- Mutual CHAP, discovery CHAP
- `iscsid.conf` tuning (timeouts, queue depth)
- Mount options as a variable; they are fixed in `tasks/main.yml`
- Anything on top of the block device: LVM, resize, reformat
- The target side. The molecule scenarios build one, the role never does

## How the role is put together

`tasks/main.yml` is one straight line: validate, enrich, install, record, login,
wait, format, mount. Everything below it exists because of one of these
decisions:

- **No `sendtargets` discovery.** The call re-creates a node record for every
  IQN the portal advertises, not just the ones that get configured, and on every
  run it resets each record's keys to the `iscsid.conf` defaults. That wipes the
  CHAP password and `node.startup` the login task wrote. The (portal, target)
  pairs are already known, so the records are created directly with
  `iscsiadm -m node -o new`, and `community.general.open_iscsi` persists auth
  and startup on login. This is the one `command` in the role that a module
  could not replace: `open_iscsi` only writes node records through discovery.
- **The portal FQDN is resolved on the managed host.** `lookup()` plugins run on
  the controller, and with split-horizon DNS the controller's view of the portal
  (a WireGuard or NAT-forwarded address) can differ from the host's.
  `getent hosts` goes through the host's NSS exactly as the initiator will.
- **Every target is enriched once, up front.** `portal_ip` and `iscsi_dev` (the
  `/dev/disk/by-path/ip-<ip>:<port>-iscsi-<iqn>-lun-0` link) are added to
  `iscsi_client_targets` by two `set_fact` tasks, so the filesystem, mount and
  fstab tasks never rebuild the path string. The comment at the top of
  `tasks/main.yml` shows the enriched shape.
- **The by-path link is the device.** `/dev/sdX` changes with login order; the
  by-path link carries the portal, the port and the IQN, so the fstab line is
  stable across reboots and the mount proves that all three were right.
- **The mountpoint mode is set after the mount, not before.** Set before, it
  sits on the directory underneath, the mount covers it with the root of the
  filesystem (`0755`), and the next run changes it again. This was a defect in
  the original role; the `idempotence` step found it.

### Design notes

- `defaults/main.yml` and `meta/argument_specs.yml` must agree. The only
  variable is `iscsi_client_targets`, default `[]`, so the role does nothing
  until the inventory fills it. `port` (3260) and `fstype` (`ext4`) are per-item
  defaults applied with `default()` in the tasks: a role argument spec validates
  nested options but does not write their defaults back into the variable.
- The `creates:` guard on the node record task is a glob. `iscsiadm -o new`
  writes the record as `<ip>,<port>` (a file); the first login learns the target
  portal group and open-iscsi moves it to `<ip>,<port>,<tpgt>/default`. A guard
  on either exact path re-runs the command on every second run.
- The role never asserts the port group tag, the session id or the `/dev/sdX`
  name: none of them is stable, and none of them is in the contract.
- `password` is `no_log: true` in the argument spec, and the login task's loop
  label shows the portal and the target only.

## Implementation status (2026-09-18)

Scope boundary: `meta/argument_specs.yml`. One variable, eight keys; every key
changes the state of the host or labels its output.

| Key                             | Where it takes effect                                                            |
| ------------------------------- | -------------------------------------------------------------------------------- |
| `name`                          | loop labels in `tasks/main.yml`                                                  |
| `portal`                        | `getent hosts` and `portal_ip` in `tasks/main.yml`; `portal:` of the login       |
| `port`                          | node record, login and the by-path link in `tasks/main.yml`                      |
| `targets[].human_readable_name` | loop labels in `tasks/main.yml`                                                  |
| `targets[].name`                | node record, login, the by-path link, and through it the fstab line              |
| `targets[].user`, `.password`   | `node_auth`, `node_user`, `node_pass` of the login; persisted in the node record |
| `targets[].mountpoint`          | `ansible.posix.mount` (mount and fstab) and the `0750` mode in `tasks/main.yml`  |
| `targets[].fstype`              | `community.general.filesystem` and the `fstype` of the mount                     |

### Verified non-issues — do not "fix" these again

- **`portal_dns.results[loop.index0]` is safe when some portals are IP
  addresses.** A loop item skipped by `when:` still occupies its index in
  `results`, so the index of a portal in `iscsi_client_targets` is the index of
  its lookup. The `portals` scenario runs one portal of each kind.
- **`community.general.filesystem` does not reformat a LUN that carries a
  filesystem**, and reports no change. The `idempotence` step of every Docker
  scenario proves it on every run.
- **`_netdev` is absent from the mount table.** It is an fstab-only option that
  `mount` consumes; the kernel never reports it. Assert it in `/etc/fstab`, not
  in `ansible_facts.mounts`.
- **The role does not load `iscsi_tcp`.** On a real host the `open-iscsi`
  package ships a `modules-load.d` entry and the next boot loads it; `iscsid`
  also asks the kernel for the transport on the first login. The molecule
  scenarios load it in `prepare` only because the container's systemd ran the
  modules-load step before the package was installed.

### Linting

`ansible-lint --offline .` reports five failures. None of them is a defect in
the role, and all five have the same causes as in the `k3s` role:

- `schema[meta]` on `Ubuntu 22.04` — ansible-lint carries a stale Galaxy
  platform list. The role runs on 22.04 (molecule) and 24.04 (homelab).
- `syntax-check[unknown-module]` on `community.general.open_iscsi`,
  `community.general.modprobe` and `ansible.posix.mount` — ansible-lint runs in
  its own virtualenv without the collections. All three are declared in
  `molecule/resources/collections.yml` and resolve at run time.
- `jinja[invalid]` in `molecule/local/tasks/expect-rejected.yml` — the linter
  renders the template with no variables in scope, so `case_expect` is
  undefined. It is defined by every caller.

### Environment notes

The Docker scenarios build a real iSCSI target and a real initiator on the
host's kernel. Four things about that took time to find:

- **The initiator container runs on the host network.** The kernel talks to
  `iscsid` over a `NETLINK_ISCSI` socket that exists in the host network
  namespace only. In a namespace of its own, `iscsid` logs
  `sendmsg: bug? ctrl_fd 5` and exits 255 at the first login. With
  `network_mode: host` Docker's embedded DNS is gone, so `prepare.yml` writes
  the targets into the initiator's `/etc/hosts` (with `unsafe_writes`, because
  Docker bind-mounts that file). The role still resolves the portal on the
  managed host, through NSS, as in production.
- **The host must not run an `iscsid` of its own.** The kernel has one iSCSI
  transport, and two daemons on it would fight over its events. The scenarios'
  cleanup logs every session out, because a session whose `iscsid` died with its
  container would otherwise stay in recovery on the host for ever.
- **The target is LIO, driven through configfs, not `tgt`.** `tgt` keeps LUN 0
  for its controller and serves the first disk at LUN 1, but the role expects
  the disk at LUN 0, as the WD NAS serves it. LIO serves LUN 0 and creates its
  portal socket in the network namespace of the process that writes it, so the
  target listens inside its container and the initiator reaches it through the
  Docker bridge. The price: LIO state is global to the kernel and outlives the
  container. `cleanup.yml` removes it, the "leftover" tasks in `prepare.yml`
  cope with a run that never reached cleanup, and every scenario uses its own
  IQNs. A fully stuck state is wiped from any privileged container with
  `/lib/modules` mounted: `targetcli clearconfig confirm=true`. The same global
  state is why a scenario has **one** target container: `targetcli` in a second
  container loads the whole configuration and fails on the backstore file that
  only the first container can see. Two portals are two ports on one container.
- **The initiator container gets the host's `/dev`.** The SCSI disk behind a
  session appears in the host's devtmpfs, and the host's udev writes the by-path
  link the role waits for. With Docker's private `/dev` the link never appears
  and the wait times out.

Also inherited from `k3s`: Docker's embedded DNS answers with AAAA records on a
user-defined network that has no IPv6 route, so `prepare.yml` forces apt to IPv4
before it installs anything. And `targetcli` wants its daemon by default;
`targetcli --disable-daemon` turns that preference off for the container.

### Last full run (2026-09-18)

All four scenarios pass end to end, idempotence included, through
`scripts/molecule-tally.sh`.

| Scenario     | Time  |
| ------------ | ----- |
| `local`      | 0m11s |
| `default`    | 2m24s |
| `portals`    | 2m23s |
| `add-target` | 2m35s |

## Open points

1. `meta/main.yml` claims Ubuntu 22.04 and 24.04. The scenarios run
   `geerlingguy/docker-ubuntu2204-ansible`; the homelab gateway is the authority
   for 24.04. Same open point as in `k3s`.
2. The LUN is fixed at 0, by scope. The day a target serves more than one LUN,
   the answer is a `lun` key per target with default 0, not a change to the path
   string. The `local` scenario rejects that key today, on purpose, so that
   adding it is a conscious step.
3. A target removed from the list keeps its session, mount and fstab line, by
   scope. The homelab has never needed it. If it does, it is an
   `iscsi_client_state`-style switch and an `absent` path, and the `add-target`
   scenario is where its test goes.

## Testing

Molecule, four scenarios. Three run on Docker; `local` runs on the Ansible
controller and needs no container at all. Every mise task goes through
`scripts/molecule-tally.sh`, which runs the scenarios one after the other, keeps
going when one fails, and prints a pass/fail table with times. Its exit status
is 0 only when every scenario passed.

| Task                          | Scenarios          | Covers                                                                      |
| ----------------------------- | ------------------ | --------------------------------------------------------------------------- |
| `mise run fast`               | `local`, `default` | Input contract, then one portal with two CHAP targets on the role defaults. |
| `mise run full`               | all four           | Every portal shape and the re-run with a new target.                        |
| `mise run scenario <name>...` | the named ones     | One or a few, for iterating.                                                |

### The scenarios

| Scenario     | Shape                             | Covers                                                                                                                                                                                         |
| ------------ | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `local`      | no host at all                    | 19 cases against the input contract: 6 against the argument spec (shape, required keys, unknown keys, types), 8 against the cross-field rules, 5 inputs that must pass. Seconds.               |
| `default`    | 1 initiator + 1 target            | The homelab shape: a portal by name, two targets with CHAP, `fstype` omitted and set. Sessions, node records keeping CHAP and `node.startup`, mounts, fstab, a file written on each LUN.       |
| `portals`    | 1 initiator + 1 target, 2 portals | Every portal-level option: one portal by name with CHAP on 3260, one by IP address without CHAP on 3261, both served by one container. The fstab lines carry the address and the port of each. |
| `add-target` | 1 initiator + 1 target            | Converges one target, then re-runs with a second: the new one is mounted and the first session keeps its SID. What a green first run cannot show.                                              |

### How the scenarios are written

- **Everything that does not need a host runs in `local`.** It uses molecule's
  `default` driver, so there is no container. The helper `tasks/validate.yml`
  runs the two halves of the contract in the order the role runs them:
  `validate_argument_spec` against `meta/argument_specs.yml` (read from the
  file, because Ansible validates the `main` entry point on its own and running
  `main` would install packages on the controller), then
  `tasks/validate-variables.yml` through `include_role`.
- **Tally in `local`, fail fast everywhere else.** `local` checks 19 independent
  things, so every case runs and one report task at the end fails with the whole
  table. The Docker scenarios stop at the first break: once a session is
  missing, the assertions behind it mean nothing.
- **Effect over rendering.** The verifies read `iscsiadm -m session`, the node
  records, `ansible_facts.mounts` and write a file on the LUN. `/etc/fstab` is
  asserted because the mount tool dictates it, and it is the only place
  `_netdev` can be seen.
- **Shared playbooks.** `molecule/resources/` holds `prepare.yml`,
  `converge.yml` and `cleanup.yml`; scenarios point at them through
  `provisioner.playbooks`. `collections.yml` is symlinked into each scenario,
  because molecule looks for it in the scenario directory. The target definition
  is data: `molecule_lio_targets` in the scenario's inventory, one entry per LUN
  with its IQN, port and CHAP credentials, and `prepare.yml` builds whatever it
  lists.
- **`cleanup.yml` is part of the test sequence**, before destroy and once at the
  very start (with `ignore_unreachable`, because no container exists then). It
  unmounts everything under `/var/lib/molecule`, logs every session out and
  deletes the LIO targets. Skipping it leaves kernel state on the host; see the
  environment notes.
- **No uninstall scenario.** The role has no `absent` path, by scope.
  `add-target` is the re-run scenario the standard asks for.
