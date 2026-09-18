# Ansible role roadmap

A scored snapshot of every role under `roles/`, taken 2026-07, to use when
deciding what to rework and in what order. Scores are subjective on purpose. The
scores below are the 2026-07 reading and are **not** re-scored as roles are
reworked; a reworked role gets a status line instead.

Explicitly **not** scored: presence/quality of `tests/`, `README.md`, and
`meta/main.yml`. Every role scored here ships the unedited `ansible-galaxy init`
boilerplate for those. That is no longer "a later pass": it is now
`ROLE-STANDARD.md`, and it applies while a role is reworked. The `k3s` role is
the first one to satisfy it.

## Status

| Role                        | State                                                                                                                          |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `k3s` (was `cluster-setup`) | Reworked, feature-complete for v1.0.0, 10 molecule scenarios. On branch `refractor/cluster-setup`, not yet reviewed or merged. |
| everything else             | As scored below.                                                                                                               |

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

See `CONVENTIONS.md` for the rules these questions are checking against.

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

---

## iscsi-client — 8

**Still the one to imitate among the roles that have not been reworked.** It is
not the overall reference any more — `k3s` is, because it ships a declared
contract and a test suite that `iscsi-client` does not have. What `iscsi-client`
still teaches, and `ROLE-STANDARD.md` does not, is taste: modelling the domain
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

**Why:** `blockinfile` + a restart-and-wait-for-port-53 handler is exactly the
right amount of mechanism for "render some lines into a file."

**Dings:** entirely inherits
[ground rule 7](CONVENTIONS.md#7-one-cross-role-concept-one-definition)'s
problem - `dns_services` is one of at least two independently-shaped definitions
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
should have certs - see `CONVENTIONS.md` rule 7; this is the other place that
duplication actually bites, since a domain added here but forgotten in the
global `services` list silently keeps its self-signed cert forever.

This is the role you called out by name, and the read here agrees with your
instinct: the mechanism (HAProxy config generation) is fine, the data model
bolted onto it isn't.

## certbot — 3

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
> is the role `ROLE-STANDARD.md` was written from. The 2026-07 finding is kept
> below, because it is the reason the rework happened.

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
