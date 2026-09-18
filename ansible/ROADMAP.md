# Ansible role roadmap

A scored snapshot of every role under `roles/`, taken 2026-07, to use when
deciding what to rework and in what order. Scores are subjective on purpose. The
scores below are the 2026-07 reading and are **not** re-scored as roles are
reworked; a reworked role gets a status line instead.

Explicitly **not** scored: presence/quality of `tests/`, `README.md`, and
`meta/main.yml`. Every role scored here ships the unedited `ansible-galaxy init`
boilerplate for those. `CLAUDE.md` rules 5 to 7 now require them while a role is
reworked. The `k3s` role is the first one to satisfy that.

## Status

| Role                                | State                                                                                                                                                           |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `k3s` (was `cluster-setup`)         | Reworked, feature-complete for v1.0.0, 10 molecule scenarios. On branch `refractor/cluster-setup`, not yet reviewed or merged.                                  |
| `iscsi_client` (was `iscsi-client`) | Brought to the standard, no new features, 4 molecule scenarios against an LIO target in Docker. On branch `refractor/iscsi-client`, not yet reviewed or merged. |
| everything else                     | As scored below.                                                                                                                                                |

## How these are scored

Each role gets 0-10 against five questions, weighted roughly evenly and then
eyeballed into one number:

1. **Scope** - does the role do one coherent thing that matches its name?
2. **Variable design** - do the data structures fit what they model, and does
   `defaults/main.yml` actually reflect what the tasks use?
3. **Correctness & idempotency** - will a second run do the right thing; are
   `changed_when`/`failed_when` honest; are there landmines (fragile parsing,
   unenforced invariants, duplicated logic)?
4. **Module discipline** - real modules over shell/command soup, used
   consistently across the codebase.
5. **Hygiene** - dead code, leftover debug output, secrets handling,
   language/tooling consistency.

See `CLAUDE.md` for the rules these questions are checking against.

## Scores

| Role                               | Score | One-line verdict                                                        |
| ---------------------------------- | ----- | ----------------------------------------------------------------------- |
| [iscsi-client](#iscsi-client--8)   | **8** | The one to imitate.                                                     |
| [garage](#garage--7)               | **7** | Solid; a few sharp edges.                                               |
| [common](#common--7)               | **7** | Small and fine, low stakes.                                             |
| [dns](#dns--7)                     | **7** | Small and fine, inherits an architecture problem.                       |
| [longhorn](#longhorn--5)           | **5** | Right modules, everything hardcoded.                                    |
| [lvm-setup](#lvm-setup--4)         | **4** | Works, but a one-off script wearing a role costume.                     |
| [haproxy](#haproxy--4)             | **4** | Config logic is fine; the var schema is the problem.                    |
| [certbot](#certbot--3)             | **3** | Same cert-assembly logic reimplemented three times.                     |
| [cluster-setup](#cluster-setup--3) | **3** | Defaults don't match what tasks actually use. **Reworked — now `k3s`.** |
| [wireguard](#wireguard--2)         | **2** | Two unrelated roles wearing a trench coat.                              |

## Suggested rework order

Ordered by (severity) x (how much it's actively in my way right now), not by how
quick the fix is:

1. **wireguard** - split now; it's the clearest single win and unblocks thinking
   about the VPN and the reverse-proxy-vhost problem separately.
2. **haproxy** - the var schema is the thing you specifically said fights you
   every time you touch it; redesigning it pays off on every future service you
   add.
3. ~~**cluster-setup**~~ - **done.** Rebuilt as `k3s` (2026-08/09); see the
   Status table above and `roles/k3s/CLAUDE.md`.
4. **certbot** - three independent implementations of "assemble a PEM from a
   cert lineage" is a bug waiting for the three to drift.
5. **longhorn** - low risk, mostly "promote hardcoded values to defaults and
   pick one Helm-invocation style."
6. **lvm-setup** - lowest priority; decide if this stays a narrow bootstrap
   script (rename it to say so) or actually becomes reusable.
7. **garage / common / dns / iscsi-client** - polish only, not blocking.

## Cross-role decisions

Decisions that more than one role depends on. They were taken in the scope
interview of 2026-09-18, before any of the affected roles was started, so that
no single rework invents a shape the others then inherit. A role's own scope
block (below, under its finding) points here instead of repeating it.

### The `services` shape (decided 2026-09-18)

"A service this homelab exposes" is declared once, in `group_vars/all`, and read
by `dns`, `haproxy` and `ispconfig_proxy`. `certbot` does not read it;
certificates are their own list.

```yaml
# group_vars/all/services.yml
services:
  - name: mealie.cindergla.de # the full FQDN, the key everywhere
    dns_target: 192.168.2.170 # the A record the dns role writes
    backend: argo-cluster # a haproxy pool by name, always required
    external: true # a vhost on the VPS; default false
  - name: mqtt.cindergla.de
    dns_target: 192.168.2.170
    mode: tcp # default https; tcp = own frontend, TCP passthrough
    listen_port: 1883 # only with mode tcp
    backend: argo-mqtt

certificates:
  - name: wildcard-cindergla-de # the lineage and PEM file name
    domains: ["*.cindergla.de"]
  - name: rancher-k8s-internal
    domains: ["rancher.k8s.internal.cindergla.de"]
```

```yaml
# group_vars/homelab/haproxy.yml: the pools, a haproxy concept
haproxy_backends:
  - name: argo-cluster
    servers: [192.168.2.171, 192.168.2.172, 192.168.2.173]
    port: 443
    ssl: true
    ssl_verify: false
    health_check: true
  - name: argo-mqtt
    servers: [192.168.2.171, 192.168.2.172, 192.168.2.173]
    port: 31883
    health_check: true
```

- **`name` is the full FQDN.** No base-domain variable and no label-plus-suffix
  assembly; `dns_domain_suffix` and `haproxy_base_domain` go away. Repeating the
  domain in every entry is the accepted price for a second domain or a
  multi-level name working without a special case. An earlier attempt to be
  clever about this failed and never reached git.
- **`backend` names a pool that `haproxy` declares, and every service sets it.**
  A pool is servers, one port, TLS towards the servers, and the health check.
  Services only point at one. There is **no default pool**: the file says where
  traffic goes without a fallback rule. The reason for named pools is that the
  gateway is a single point of failure and a detached monitoring host is the
  next project; its services must not route through the cluster pool.
- **`mode` is `https` (default) or `tcp`, and it is explicit.** An `https`
  service is matched by its name in the Host header on the shared port 443
  frontend. A `tcp` service gets its own frontend on `listen_port` in TCP mode
  with its pool as `default_backend`; this is what `haproxy_tcp_services`
  rendered before, with the DNS record it was missing. A pool's HAProxy mode
  follows the services that name it; a pool named by both modes fails
  validation, because HAProxy needs two backend blocks for that. `listen_port`
  is only valid with `mode: tcp`, must be unique, and must not be 80 or 443.
  `external: true` on a `tcp` service fails validation: the VPS vhost is an HTTP
  reverse proxy.
- **`external` is one boolean, default `false`.** `true` means exactly: the VPS
  gets a vhost for the name and proxies it through the tunnel to the gateway.
  There is no third state.
- **Every service gets a DNS record**, whatever its mode.
- **Certificates are a list of their own, not derived from `services`.** One
  entry is one certbot lineage and one PEM under `/etc/haproxy/ssl/`. An entry
  may hold a wildcard, one name, or several names. The recommended layout is one
  wildcard entry plus one entry per name the wildcard does not match
  (`rancher.k8s.internal.cindergla.de`). Merging everything into one multi-SAN
  certificate is possible with the same shape but not recommended: every added
  name re-issues the whole certificate. HAProxy picks the certificate by SNI
  from the directory, so no service-to-certificate mapping exists anywhere.
  `haproxy` asserts that every `https` service is matched by some
  `certificates[].domains` entry, a wildcard matching exactly one label; a name
  nobody issues a certificate for fails the run instead of keeping a self-signed
  placeholder forever.
- **Port 443 has no `default_backend`.** `is_default: true` goes away and no
  `haproxy_default_backend` variable replaces it. A name that matches no ACL
  gets a 503, which is the signal that a `services` entry is missing. A name
  that relied on the fallback (`rancher.k8s.internal.cindergla.de` is in no list
  today) becomes an entry.

### The `wireguard` split (decided 2026-09-18)

`roles/wireguard` today is a VPN role and an ISPConfig provisioning role in one
file. It becomes two roles:

- **`wireguard`** manages one interface (`wg0`) per host and nothing else.
  - Each host declares its own `wireguard_address` and, on a host that listens,
    `wireguard_listen_port`, in `host_vars`. Nothing in the role knows which
    host is "the server".
  - Peers are two lists, because they are two kinds of things:
    `wireguard_peer_hosts` holds inventory names of managed hosts, whose public
    key the role reads from their facts (so both ends are in the same play, as
    today); `wireguard_peers` holds static peers with `name`, `public_key` and
    `allowed_ips` (the road warriors). Endpoint and keepalive are per peer where
    they apply.
  - Keys are generated on the host on the first run and are never in the
    inventory. The private key is written with `creates` and read back with
    `slurp`; the public key is derived from it. This closes the two `# TODO`
    comments on `changed_when`.
  - IP forwarding is a boolean the relaying host sets, not a group test.
  - `wireguard_state: absent` is **in scope**, so a rebuild is testable:
    interface down, config and keys removed, package left alone.
- **`ispconfig_proxy`** creates the reverse-proxy vhost on the VPS for every
  service with `external: true`.
  - It runs on the `vps` host and calls the ISPConfig JSON API there, with plain
    `uri` tasks and no delegation to the controller.
  - It reads the vhost first, creates it if missing, and updates it when the
    alias list or the Apache directives differ. Deleting the vhost when the last
    external service leaves is out.
  - One vhost carries all external names, the first as the domain and the rest
    as aliases. One vhost per service was only the first thing that worked.
  - The upstream (`https://10.0.0.2/`, the gateway's tunnel address) is an
    explicit variable `ispconfig_proxy_upstream` in `group_vars/vps`, with a
    comment saying what it is. It is not derived from the `wireguard` variables;
    that link would be the kind of clever the owner does not want to decode in
    six months.

---

## iscsi-client — 8

> **Reworked.** Renamed to `iscsi_client` (ansible-lint rejects a hyphen in a
> role name) and brought to the standard on branch `refractor/iscsi-client`
> (2026-09): argument spec, input validation, four molecule scenarios against an
> LIO target in Docker, role `CLAUDE.md`. No feature was added. The rework found
> one defect the 2026-07 read missed: the mountpoint mode was set before the
> mount, so the second run always reported a change. The finding below is kept
> as the reason the role scored where it did.

**Still the one to imitate among the roles that have not been reworked.** It is
not the overall reference any more — `k3s` is, because it ships a declared
contract and a test suite that `iscsi-client` does not have. What `iscsi-client`
still teaches, and `CLAUDE.md` does not, is taste: modelling the domain
correctly on the first try.

**Why it's the high-water mark:** the variable shape (portal -> targets) matches
the actual domain model, defaults ship a realistic worked example, and the
comment at the top of `tasks/main.yml` documents the _shape_
`iscsi_client_targets` grows into after enrichment - genuinely useful for the
next reader. It deliberately avoids `sendtargets` discovery because that call is
destructive to existing CHAP/`node.startup` state on every re-run, and says so.
CHAP creds flow through vault-backed vars cleanly.

**Dings:** none structural. `changed_when: false` and `check_mode: false` are
used correctly throughout rather than as an escape hatch.

## garage — 7

**Why:** idempotent by construction - buckets and keys are checked against
`json-api ListBuckets`/`ListKeys` output before creating anything, which is
exactly the "check structured state, don't assume" pattern this repo should
standardize on. `defaults/main.yml` is genuinely usable, with inline comments on
how to generate every secret. Systemd unit has real hardening (`ProtectHome`,
`NoNewPrivileges`, `PrivateTmp`).

**Dings:** `garage_binary_architecture` defaults to a hardcoded
`x86_64-unknown-linux-musl` with the alternatives just listed in a comment,
rather than derived from `ansible_architecture`; one
`changed_when: false # i am too lazy rn to check this properly`; binary download
has no checksum verification; `replication_factor = 1` is baked into the
template rather than being a variable, which is fine as a deliberate single-node
simplification but should be a comment saying so, not implicit.

## common — 7

**Why:** does exactly what it says - passwordless sudo for the SSH user, a short
package list. Nothing to fight with because there's nothing to overdesign.

**Dings:** none worth flagging at this scope. Passwordless sudo for every
managed host is a real security-relevant default worth a one-line comment in the
role explaining it's intentional (it already is intentional per the top-level
README), but that's a documentation nit, not a scoring one.

## dns — 7

> **Rework scope (locked 2026-09-18).** Bring to the standard. In: one A record
> per `services[]` entry, written from the full FQDN and `dns_target`;
> `dns_state: absent` removes the block. Out: installing or configuring Pi-hole
> in any other way. The write mechanism stays `blockinfile` on
> `/etc/pihole/custom.list`, because the host runs Pi-hole 5.18.2. **Flag:**
> Pi-hole 6 moved local records into `pihole.toml`, so this role stops working
> the day the Pi-hole is upgraded; the upgrade and the Pi-hole rework are a
> later project, not part of this one. `dns_services` and `dns_domain_suffix` go
> away; the role reads `services` as decided in "Cross-role decisions".

**Why:** `blockinfile` + a restart-and-wait-for-port-53 handler is exactly the
right amount of mechanism for "render some lines into a file."

**Dings:** entirely inherits
[rule 2](CLAUDE.md#2-metaargument_specsyml-is-the-variable-contract)'s last
bullet - `dns_services` is one of at least two independently-shaped definitions
of "a service this homelab exposes." Not this role's fault to fix alone, but
it's the role most exposed to that duplication going stale.

## longhorn — 5

**Why it's mid-pack:** uses `kubernetes.core.helm`/`helm_repository` properly,
which is the correct module and the one `cluster-setup` should also be using
instead of shelling out.

**Dings:** `defaults/main.yml` is empty - chart version (`1.8.1`), replica count
(`3`), and the storage class YAML are all hardcoded in `tasks/longhorn.yml` and
`files/longhorn-r1.yml` with no override path. Applies the custom storage class
via `kubectl apply` + shell/stdout-string matching
(`'unchanged' not in apply_out.stdout`) in the same task file that correctly
uses the Helm _module_ two tasks earlier - inconsistent within a single file,
not just across roles. One block of commented-out node-labeling code left in.

## lvm-setup — 4

**Why it's this low:** it works, but it's really two unrelated one-off steps
("grow the root LV," "carve out and mount a Longhorn LV") glued under a generic
name, with volume group name (`ubuntu-vg`), the Longhorn LV size (`100g`), and
the mount target all hardcoded rather than exposed as variables - only
`lvm_setup_root_size` is. Fine as a bootstrap script for this specific fleet;
not fine if the name implies it's a general-purpose LVM role, because it isn't
one.

## haproxy — 4

> **Rework scope (locked 2026-09-18).** The variable schema is replaced by the
> `services` shape and the `haproxy_backends` pools from "Cross-role decisions";
> the config generation itself is kept. In: the shared port 443 frontend with
> one ACL per `https` service and no `default_backend`; one TCP frontend per
> `tcp` service; pools with mode derived from their services; self-signed
> placeholder PEMs keyed on `certificates[]` so HAProxy starts before `certbot`
> has run; the assertion that every `https` service is covered by a certificate
> entry; port 80 as a redirect to HTTPS only; `haproxy_state: absent` (package,
> config, certificate directory). Out: variables for timeouts, `maxconn` and
> ciphers (they stay fixed in the template); the ACME HTTP challenge; a stats
> page; any default route.

**Why:** the Jinja templating itself (ACL generation, backend/frontend assembly,
TCP passthrough services) is competent and not the problem.

**Dings, all in `defaults/main.yml`'s shape:** one `haproxy_https_backends`
entry conflates a routing rule (`domains`), a server pool
(`servers`/`port`/`ssl`/`health_check` shared across every server in it), and a
global default-route flag (`is_default: true`) with an invariant - exactly one
entry must set it - that nothing enforces. In the current inventory, twelve
unrelated services share one backend entry purely because they happen to point
at the same three cluster nodes on port 443, which works but means the schema
already isn't modeling "one service" so much as "one server pool that happens to
serve many services." Self-signed placeholder-cert generation is embedded in
this role and coupled to `certbot` only through a shared directory convention
(`/etc/haproxy/ssl/*.pem`), with no shared source of truth for which domains
should have certs - see `CLAUDE.md` rule 2; this is the other place that
duplication actually bites, since a domain added here but forgotten in the
global `services` list silently keeps its self-signed cert forever.

This is the role you called out by name, and the read here agrees with your
instinct: the mechanism (HAProxy config generation) is fine, the data model
bolted onto it isn't.

## certbot — 3

> **Rework scope (locked 2026-09-18).** Rebuilt without Docker. In: certbot and
> `certbot-dns-netcup` in one native virtual environment (`pipx` or `venv`); one
> lineage per `certificates[]` entry, issued with `-d` per domain; renewal
> through certbot's own systemd timer; **one** English deploy-hook script that
> writes `privkey.pem` + `fullchain.pem` to
> `/etc/haproxy/ssl/<certificates[].name>.pem` and reloads HAProxy, replacing
> the cron job, `new_cert.sh` and the three copies of the name logic; the netcup
> customer id, API key and API password as vault variables rendered into the
> credentials file; email, propagation wait and ACME server URL as variables
> with defaults; `certbot_authenticator` (default `dns-netcup`, `manual` with
> hook scripts allowed) so molecule can issue against a Pebble ACME server in
> Docker; cleanup of lineages and PEMs that are not in `certificates`;
> `certbot_state: absent` (venv, timer, hook, lineages). Out: Docker, the git
> clone and image build, the Raspbian apt repository, the HTTP challenge. The
> netcup path itself gets one manual verification against the real gateway;
> nothing else on the gateway needs Docker, so it goes.

**Why it's low despite working:** the "take a lineage's `privkey.pem` +
`fullchain.pem` and cat them into `/etc/haproxy/ssl/<name>.pem`" operation is
implemented three separate times with three separate ways of deriving `<name>`
from a domain: the cron job's `awk -F . '{print $1}'` (first label only),
`new_cert.sh`'s use of the full `$service_name` verbatim, and `cleanup.yml`'s
`regex_replace('\..*$', '.pem')`. These already disagree for any domain that
isn't exactly `label.tld` - a two-label suffix like `cindergla.de` masks it
today, but it's three copies of the same logic that can silently drift.

**Also:** `new_cert.sh` is in German while every other comment/string in the
repo is in English; `certbot-docker-setup.yml` hardcodes the Raspbian Docker apt
repo URL unconditionally (works because the fleet happens to be that
architecture, not because it's declared); `README.md`/`meta/main.yml` are
untouched `ansible-galaxy init` boilerplate.

## cluster-setup — 3

> **Resolved.** The role was renamed to `k3s` and rebuilt between 2026-08 and
> 2026-09 on branch `refractor/cluster-setup`. Every finding below is addressed:
> the variables are declared in `meta/argument_specs.yml` and asserted by
> `tasks/validate-variables.yml`, the `debug` task is gone, node readiness is
> read through `k3s kubectl get --raw /readyz` instead of
> `kubectl | grep | wc -l`, and ten molecule scenarios cover the topologies. It
> is the role `CLAUDE.md` rules 2, 5 and 6 were written from. The 2026-07
> finding is kept below, because it is the reason the rework happened.

**Why this is worse than it looks at a glance:** `defaults/main.yml` defines
`rancher_bootstrap_password`, `rancher_version`, `rancher_replica_count`, and
`cluster_setup_ranche_hostname` (typo) - and none of them are what
`tasks/rancher.yml` actually reads (`cluster_setup_rancher_bootstrap_password`,
`cluster_setup_rancher_version`, etc., which only exist because
`group_vars/homelab/vars.yml` happens to define them). Reading this role in
isolation gives you a wrong picture of what's configurable. There's a leftover
`debug: var: cluster_setup_k3s_token` task, node readiness is checked via
`kubectl get nodes | grep [^t]Ready.*control | wc -l` (fragile against any
change in node roles/labels), and cert-manager's Helm chart version is hardcoded
inline while Rancher's is parametrized - no consistent policy on what gets a
variable.

## wireguard — 2

> **Rework scope (locked 2026-09-18).** Split into `wireguard` and
> `ispconfig_proxy`; the shape of both is in "Cross-role decisions" above.
> `wireguard_state: absent` is in scope so a rebuild is testable. Molecule for
> `wireguard`: two containers as the two tunnel ends, and a scenario with a
> static peer. Molecule for `ispconfig_proxy`: a stub of the ISPConfig JSON API
> in a container, since the real one is not reachable from a test.

**Why it's the floor:** roughly half of `tasks/main.yml` has nothing to do with
WireGuard - it logs into an ISPConfig install over its remote JSON API and
creates a reverse-proxy vhost per external service, using a ~90-line hardcoded
payload that includes a **hardcoded backend IP (`10.0.0.2`) baked into a raw
`apache_directives` string**. That's a second infrastructure-provisioning role
hiding inside a role named after a VPN daemon, with a config value that would
need a manual template edit to ever point anywhere else. On top of that, key
generation has two `# TODO` comments admitting the `changed_when`/ordering logic
is wrong today, left unresolved rather than fixed.

This matches your own read going in - it's the clearest "split this into
multiple roles" case in the codebase, not a subjective judgment call.
