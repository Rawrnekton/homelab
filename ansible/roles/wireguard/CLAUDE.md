# wireguard role

Ansible role that manages one WireGuard interface, `wg0`, on a host. In the
homelab it builds the tunnel between the VPS and the gateway and lets the road
warriors in through the VPS.

Read `../../CLAUDE.md` first; this file only holds what applies to this role.

## Scope (locked 2026-09-18)

The 2026-07 review scored the old role 2 of 10: half of it provisioned ISPConfig
vhosts. That half is now `../ispconfig_proxy`; what is left here is the VPN, and
nothing else. The shape was decided in `../../ROADMAP.md`, "The `wireguard`
split".

### In

- One interface per host, `wg0`, run through `wg-quick@wg0`
- Every host declares its own `wireguard_address`, and `wireguard_listen_port`
  when it listens. Nothing in the role knows which host is "the server"
- Two peer lists: `wireguard_peer_hosts` (hosts of the play, public key from
  their facts) and `wireguard_peers` (static peers with a written-down key).
  Endpoint and keepalive are per peer, in both lists
- Keys generated on the host on the first run and never written to the
  inventory; the private key stays the same for the life of the host
- IPv4 forwarding as a boolean on the relaying host
- `wireguard_state: absent`: interface down, config, key and sysctl drop-in
  removed, package left alone
- Input contract in `meta/argument_specs.yml` plus the cross-field rules in
  `tasks/validate-variables.yml`

### Out

- The ISPConfig vhosts (`../ispconfig_proxy`)
- A second interface, or an interface name other than `wg0`
- Preshared keys, `DNS =`, `MTU =`, `Table =`, `FwMark =`, `PostUp`/`PostDown`
- Deriving anything from the group a host is in (the old role tested
  `groups['vps']`)
- Deriving a peer's endpoint or allowed IPs from its variables; both are written
  down per peer
- IPv6 forwarding. `wireguard_ip_forward` sets `net.ipv4.ip_forward` only
- Firewall rules and NAT. The homelab's road warriors reach the gateway's tunnel
  address, not the LAN behind it
- Removing the package on uninstall

## How the role is put together

`tasks/main.yml` validates, then branches on `wireguard_state`. `present.yml` is
one straight line: package, directory, key, public key, the check that every
managed peer has one too, forwarding, config, service. Everything below it
exists because of one of these decisions:

- **The private key is written once, with `creates`, and read back with
  `slurp`.** `wg genkey` only prints a key, and no module generates one, so a
  `shell` task redirects it into the file under `umask 077`. `creates` makes
  every later run a no-op, which is what "the key never changes" means. The
  public key is derived from the file on every run with `wg pubkey`, a pure
  computation with `changed_when: false`. This is what closed the two `# TODO`
  comments of the old role.
- **The public key is a host-scoped fact.** `set_fact` publishes it as
  `wireguard_public_key`, and the template of a peer reads
  `hostvars[peer.host].wireguard_public_key`. That only works when both hosts
  are in the same play and the derive task ran on both before the template task,
  which the linear strategy guarantees. A peer that is not in the play, failed
  earlier, or runs with `wireguard_state: absent` has no key; the assert in
  `present.yml` names it instead of letting Jinja fail on an undefined
  attribute.
- **Two peer lists, because a managed peer and a static peer are different
  things.** They share `allowed_ips`, `endpoint` and `persistent_keepalive`, and
  differ in where the public key comes from: `host` names an inventory host
  whose facts hold it, `name` + `public_key` write it down. Nothing is derived
  from either: the allowed IPs and the endpoint of a peer are written per peer,
  on the host that needs them.
- **The handler restarts the service; it does not `wg syncconf`.** syncconf
  applies keys, port and peers without dropping the interface, but silently
  ignores a changed `Address`. A restart applies every line, at the price of a
  short drop, after which the peers re-handshake on their next packet or
  keepalive. The `roadwarrior` scenario shows the price is paid only by the host
  whose config changed: the client, whose config did not, keeps its interface.
- **`wireguard-tools`, not `wireguard`, and without recommends.** The kernel
  module ships with every kernel since 5.6; on Ubuntu `linux-modules-*` provides
  `wireguard-modules`. The `wireguard` metapackage adds nothing but a
  recommendation of `wireguard-dkms`, which a container cannot satisfy, and
  `wireguard-tools` recommends the same. `install_recommends: false` leaves the
  kernel's module in charge on a real host as well.
- **`wireguard_ip_forward: false` removes the drop-in, not the setting.** A
  container runtime or another tunnel on the host may need forwarding, and this
  role only owns `/etc/sysctl.d/99-wireguard.conf`. `true` writes and applies
  it; `false` removes the file and leaves the live value alone.
- **The template task runs with `no_log`.** The config holds the private key,
  and `ansible.cfg` turns diff mode on for every run. The cost is that a
  template error is reported without its message; run the play once with
  `no_log` removed to see it.
- **`absent.yml` reads `service_facts` before it stops the unit.** The
  instantiated unit `wg-quick@wg0.service` is only known to systemd once it was
  enabled or started; on a host that never ran the present path, or on the
  second absent run, `systemd: state=stopped` would fail on the unknown unit.

### Design notes

- `defaults/main.yml` and `meta/argument_specs.yml` must agree. Four variables
  have a default there; `wireguard_address` and `wireguard_listen_port` have
  none, because there is no sane one: every host declares its own address, and a
  host that does not listen has no port.
- `vars/main.yml` holds the interface name, the paths and the unit name. They
  are not inputs; the role manages `wg0` and nothing else, by scope.
- The validation checks what WireGuard would accept silently and do the wrong
  thing with: an address without a prefix length (the other tunnel addresses
  would be unroutable), an allowed IP claimed by two peers (the last one wins
  and nothing says so), a static peer's key with the wrong shape.
- `endpoint` accepts a name, an IPv4 address, or an IPv6 address in brackets,
  always with a port. wg-quick resolves a name at start time.

## Implementation status (2026-09-18)

Scope boundary: `meta/argument_specs.yml`. Every variable and key changes the
state of the host.

| Variable / key                                                        | Where it takes effect                                                       |
| --------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| `wireguard_state`                                                     | branch in `tasks/main.yml`; `tasks/absent.yml`                              |
| `wireguard_address`                                                   | `Address =` in `templates/wg0.conf.j2`                                      |
| `wireguard_listen_port`                                               | `ListenPort =` in the template                                              |
| `wireguard_ip_forward`                                                | `ansible.posix.sysctl` and the drop-in removal in `tasks/present.yml`       |
| `wireguard_peer_hosts[].host`                                         | `PublicKey =` through `hostvars[host].wireguard_public_key`; the peer check |
| `wireguard_peer_hosts[].allowed_ips`                                  | `AllowedIPs =` of that peer                                                 |
| `wireguard_peer_hosts[].endpoint`                                     | `Endpoint =` of that peer                                                   |
| `wireguard_peer_hosts[].persistent_keepalive`                         | `PersistentKeepalive =` of that peer                                        |
| `wireguard_peers[].name`                                              | the comment line above the peer block                                       |
| `wireguard_peers[].public_key`                                        | `PublicKey =` of that peer                                                  |
| `wireguard_peers[].allowed_ips`, `.endpoint`, `.persistent_keepalive` | as for a managed peer                                                       |

### Verified non-issues — do not "fix" these again

- **`creates` on the key task is enough for idempotence.** The `idempotence`
  step of every Docker scenario proves it, and the `default` verify checks that
  the key the kernel runs with is the key in the file after the second run.
- **`wg pubkey` with `changed_when: false` is honest.** It reads stdin and
  prints; nothing on the host changes. It is the one `changed_when: false` in
  the role, and it is not a shrug.
- **`ansible.utils.ipaddr('host/prefix')` accepts a bare host and adds `/32`.**
  That is why the address rule also checks for a `/` in the string. Do not drop
  that check in favour of the filter alone.
- **`ansible.utils.ipaddr` is a filter, not a test.**
  `reject('ansible.utils.ipaddr')` fails with "no test named". The allowed-IP
  rule loops in Jinja for that reason.
- **A filter result is not a conditional.** ansible-core 2.19+ refuses a
  conditional that evaluates to a string
  (`Conditionals must have a boolean result`); `... | ipaddr(...) is truthy` is
  the form that works.
- **`service_facts` cannot judge `wg-quick@wg0`.** It is an instance of a
  template unit and a oneshot with `RemainAfterExit`: the facts show it as
  `stopped` while it is active, and its `status` is not `enabled` although
  `systemctl is-enabled` says so. The verifies ask `systemctl is-enabled` and
  `is-active` directly (`command`, with a `noqa` and the reason: the systemd
  module refuses to run without a state to enforce). `tasks/absent.yml` still
  uses `service_facts`, only to see whether the instance is known at all.
- **The container does not need `/lib/modules`.** `ip link add type wireguard`
  makes the kernel load the module from the host's side. `prepare.yml` creates
  and deletes a probe interface so that a host without the module fails with a
  hint instead of at the first `wg-quick up`.

### Linting

`ansible-lint --offline .` reports three failures. None of them is a defect in
the role, and all three have the same causes as in the `k3s` and `iscsi_client`
roles. Two `command-instead-of-module` findings on the `systemctl` queries in
the verifies are silenced with `noqa` where they occur, with the reason next to
them (see the non-issues above).

- `schema[meta]` on `Ubuntu 22.04` — ansible-lint carries a stale Galaxy
  platform list. The role runs on 22.04 (molecule) and 24.04 (homelab).
- `syntax-check[unknown-module]` on `ansible.posix.sysctl` — ansible-lint runs
  in its own virtualenv without the collection. It is declared in
  `molecule/resources/collections.yml` and resolves at run time.
- `jinja[invalid]` in `molecule/local/tasks/expect-rejected.yml` — the linter
  renders the template with no variables in scope, so `case_expect` is
  undefined. It is defined by every caller.

### Environment notes

- A privileged container creates a WireGuard interface in its own network
  namespace on the host's kernel; `wg-quick` and systemd inside the container
  run it like on a host. Nothing has to be mounted in.
- Docker's embedded DNS answers with AAAA records on a user-defined network that
  has no IPv6 route, so `prepare.yml` forces apt to IPv4 (inherited from `k3s`).
  For the same reason the scenarios do not use a container name as an endpoint:
  the client's endpoint is the server's `ansible_default_ipv4`, read from facts,
  which is also what `host_vars/odysseus.yml` does for the VPS.
- After the server restarts (it gains a peer in `roadwarrior`), it does not know
  the client's endpoint until the client sends a packet. The verify pings from
  the client first, then from the laptop through the relay; every ping retries,
  because the keepalive takes up to 25 seconds.

### Last full run (2026-09-18)

All four scenarios pass end to end, idempotence included, through
`scripts/molecule-tally.sh`:

| Scenario      | Time  |
| ------------- | ----- |
| `local`       | 0m15s |
| `default`     | 1m35s |
| `uninstall`   | 1m43s |
| `roadwarrior` | 2m22s |

## Open points

1. `host_vars/odysseus.yml` takes the endpoint of the VPS from
   `hostvars['naglfar'].ansible_default_ipv4.address`, as the old template did.
   It works because both hosts are in the play and the VPS's default route
   leaves through its public address. A DNS name of the VPS would be sturdier;
   the inventory has none today. The answer is a name in `host_vars`, not a
   change to the role.
2. The handler restarts `wg-quick@wg0` on every config change, so adding a road
   warrior on the VPS drops the gateway's tunnel for a second. `wg syncconf`
   would avoid that for peer changes but not apply an `Address` change. If the
   drop ever matters, the answer is a second handler for peer-only changes, with
   the template split in two files; not a silent syncconf.
3. `meta/main.yml` claims Ubuntu 22.04 and 24.04. The scenarios run
   `geerlingguy/docker-ubuntu2204-ansible`; the homelab hosts are the authority
   for 24.04. Same open point as in `k3s` and `iscsi_client`.
4. The role has not been run against the real VPS and gateway yet. The keys
   there were generated by the old role into the same file
   (`/etc/wireguard/private.key`), so the first run keeps them and the road
   warriors' configs stay valid; the config file is rewritten and the service
   restarted once.

## Testing

Molecule, four scenarios. Three run on Docker; `local` runs on the Ansible
controller and needs no container at all. Every mise task goes through
`scripts/molecule-tally.sh`, which runs the scenarios one after the other, keeps
going when one fails, and prints a pass/fail table with times. Its exit status
is 0 only when every scenario passed.

| Task                          | Scenarios          | Covers                                            |
| ----------------------------- | ------------------ | ------------------------------------------------- |
| `mise run fast`               | `local`, `default` | Input contract, then the two tunnel ends.         |
| `mise run full`               | all four           | Uninstall and the road warrior added on a re-run. |
| `mise run scenario <name>...` | the named ones     | One or a few, for iterating.                      |

### The scenarios

| Scenario      | Shape                    | Covers                                                                                                                                                                                                                                             |
| ------------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `local`       | no host at all           | 27 cases against the input contract: 8 against the argument spec, 14 against the cross-field rules, 5 inputs that must pass. Seconds.                                                                                                              |
| `default`     | server + client          | The homelab shape: one end listens and forwards, the other connects with endpoint and keepalive, each the other's managed peer. Service, address, peers and handshakes read from the kernel, pings in both directions, key file modes, the sysctl. |
| `roadwarrior` | server + client + laptop | Converges the pair, then sets a laptop up by hand and re-runs with it as a static peer of the server. The laptop pings the server and, relayed, the client; the client's interface is the one from before the re-run.                              |
| `uninstall`   | server + client          | Converges, removes twice with `wireguard_state: absent`, then checks: no interface, no unit running, no config, key or drop-in, package still there.                                                                                               |

### How the scenarios are written

- **Everything that does not need a host runs in `local`.** It uses molecule's
  `default` driver, so there is no container. Its inventory carries a second
  host, `wg-peer`, that exists only so that a managed peer can name a host of
  the inventory. The helper `tasks/validate.yml` runs the two halves of the
  contract in the order the role runs them.
- **Tally in `local`, fail fast everywhere else.**
- **Effect over rendering.** The verifies read `wg show` and the network facts,
  send pings, and compare the key the kernel uses with the file. The config file
  is only checked for its mode and owner, which wg-quick demands.
- **Shared playbooks.** `molecule/resources/` holds `prepare.yml` and
  `converge.yml`; scenarios point at them through `provisioner.playbooks`.
  `collections.yml` is symlinked into each scenario.
- **The laptop's keypair is committed.** The server's static peer has to name
  the public key before anything runs, so `roadwarrior/molecule.yml` carries a
  keypair generated for it. It configures a throwaway container and nothing
  else.
