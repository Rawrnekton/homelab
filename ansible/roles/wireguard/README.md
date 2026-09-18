<!-- BEGIN_ANSIBLE_DOCS -->

# Ansible Role: wireguard

manage one WireGuard interface (wg0) per host

Tags: wireguard, vpn, homelab

## Requirements

| Platform | Versions     |
| -------- | ------------ |
| Ubuntu   | 22.04, 24.04 |

## Role Arguments

### Entrypoint: main

Manage one WireGuard interface (wg0) on this host.

Installs wireguard-tools, generates the private key of the host on the first run
and keeps it, renders `/etc/wireguard/wg0.conf` and runs the interface through
`wg-quick@wg0`.

Nothing in the role knows which host is "the server". Every host declares its
own address, listens when it sets a port, and lists its peers. A peer is either
another host of the play, whose public key the role reads from its facts, or a
static peer with a public key written down in the inventory.

| Option                | Description                                                                                                                                                                                                                                                                                                                                                                          | Type                                            | Required | Default |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------- | -------- | ------- |
| wireguard_state       | `present` installs the tools, writes the keys and the config and starts the interface. `absent` stops the interface and removes the config, the private key and the sysctl drop-in. The package stays installed.                                                                                                                                                                     | str                                             | no       | present |
| wireguard_address     | The tunnel address of this host with its prefix length, for example `10.0.0.2/24`. The prefix is what makes the other tunnel addresses routable through the interface, so it is mandatory.                                                                                                                                                                                           | str                                             | yes      |         |
| wireguard_listen_port | UDP port this host listens on. Set it on a host that other peers connect to; leave it out on a host that only connects out.                                                                                                                                                                                                                                                          | int                                             | no       |         |
| wireguard_ip_forward  | Whether this host forwards IPv4 packets between its peers. Set it on the host that relays traffic between the other tunnel ends. `true` writes `net.ipv4.ip_forward = 1` to `/etc/sysctl.d/99-wireguard.conf` and applies it. `false` removes that drop-in and leaves the live value alone, because other things on the host (a container runtime, for one) may need forwarding too. | bool                                            | no       | False   |
| wireguard_peer_hosts  | Peers that are hosts of this inventory and run this role in the same play. Their public key is read from their facts, so both ends of a tunnel are configured in one run and no key is ever written down.                                                                                                                                                                            | list of dicts of 'wireguard_peer_hosts' options | no       | []      |
| wireguard_peers       | Static peers whose public key is written down in the inventory. The road warriors, whose other end this role never sees.                                                                                                                                                                                                                                                             | list of dicts of 'wireguard_peers' options      | no       | []      |

#### Options for main > wireguard_peer_hosts

| Option               | Description                                                                                                                                                                                        | Type          | Required | Default |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- | -------- | ------- |
| host                 | The inventory name of the peer. It must be in the same play with `wireguard_state` `present`; the role fails otherwise.                                                                            | str           | yes      |         |
| allowed_ips          | The addresses and networks routed to this peer, in CIDR notation. On a host that relays, the peer's own tunnel address as a `/32`. On a host that connects to the relay, the whole tunnel network. | list of 'str' | yes      |         |
| endpoint             | Where to reach the peer, as `host:port`. Set it on the side that connects out; leave it out on the side that listens.                                                                              | str           | no       |         |
| persistent_keepalive | Seconds between keepalive packets to this peer. Set it on the side behind NAT so that the tunnel stays open; `25` is the usual value.                                                              | int           | no       |         |

#### Options for main > wireguard_peers

| Option               | Description                                                                                                     | Type          | Required | Default |
| -------------------- | --------------------------------------------------------------------------------------------------------------- | ------------- | -------- | ------- |
| name                 | Label for the peer, written as a comment in the config.                                                         | str           | yes      |         |
| public_key           | The peer's public key, base64 as `wg pubkey` prints it.                                                         | str           | yes      |         |
| allowed_ips          | The addresses and networks routed to this peer, in CIDR notation. Usually the peer's tunnel address as a `/32`. | list of 'str' | yes      |         |
| endpoint             | Where to reach the peer, as `host:port`. Leave it out for a peer that connects in from a changing address.      | str           | no       |         |
| persistent_keepalive | Seconds between keepalive packets to this peer.                                                                 | int           | no       |         |

#### Choices for main > wireguard_state

| Choice  |
| ------- |
| present |
| absent  |

## Dependencies

None.

## Example Playbook

```
- hosts: all
  tasks:
    - name: Importing role: wireguard
      ansible.builtin.import_role:
        name: wireguard
      vars:
        wireguard_address: # required, type: str
```

## License

MIT

## Author and Project Information

Jonathan Gerdes

<!-- END_ANSIBLE_DOCS -->

## Usage

```yaml
- name: Setup WireGuard tunnel between gateway and VPS
  hosts: gateway:vps
  become: true
  roles:
    - role: wireguard
```

Both ends of a tunnel go in one play: a managed peer's public key is read out of
the facts of the other host, so nobody ever writes a key down. Every host
declares its own tunnel address in `host_vars`, the host that others connect to
sets `wireguard_listen_port`, and the host that relays between the others sets
`wireguard_ip_forward`. Road warriors are static peers in `wireguard_peers`.

```yaml
# host_vars/vps.yml
wireguard_address: 10.0.0.1/24
wireguard_listen_port: 51820
wireguard_ip_forward: true
wireguard_peer_hosts:
  - host: gateway
    allowed_ips: [10.0.0.2/32]
wireguard_peers:
  - name: laptop
    public_key: "{{ vault_wireguard_laptop_public_key }}"
    allowed_ips: [10.0.0.3/32]

# host_vars/gateway.yml
wireguard_address: 10.0.0.2/24
wireguard_peer_hosts:
  - host: vps
    allowed_ips: [10.0.0.0/24]
    endpoint: "{{ hostvars['vps'].ansible_default_ipv4.address }}:51820"
    persistent_keepalive: 25
```

The private key of a host is generated on the first run and never changes.
`wireguard_state: absent` stops the interface and removes the config, the key
and the sysctl drop-in; the package stays.

## Testing

The role is covered by four Molecule scenarios. One of them runs on the Ansible
controller, the other three in Docker, on the host's kernel.

| Task                          | Covers                                                                      |
| ----------------------------- | --------------------------------------------------------------------------- |
| `mise run fast`               | `local`, then the two tunnel ends with packets crossing in both directions. |
| `mise run full`               | All four scenarios: the uninstall and the road warrior relayed on a re-run. |
| `mise run scenario <name>...` | The named scenarios, for iterating.                                         |

`CLAUDE.md` holds the full scenario table, what the Docker scenarios need from
the host, and the reasons behind it.

## License

MIT
