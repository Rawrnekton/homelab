# k3s role

Ansible role to provision a bare k3s cluster, for the user's homelab.

## Goal

Refactor this role so it's easily usable, testable, and follows Ansible best
practices — for real use in the homelab, and as a hands-on exercise for
learning to write a good Ansible role.

## Working agreement

- **Avoid `ansible.builtin.command`/`shell`** when a dedicated module exists for
  the job. Prefer declarative modules (e.g. `service_facts` over
  `systemctl is-active`, `stat` over `ls`, `slurp` over `cat`).

## How the role is put together

`tasks/main.yml` is the whole story in ten lines. Everything below it exists
because of one of these decisions:

- **`config.yaml` is the single place where a variable becomes node state.**
  `templates/config.yaml.j2` renders on every run, and a change to the result
  notifies the rolling-restart handler. Pass-through arguments
  (`k3s_extra_server_args`, `k3s_extra_agent_args`) go there too rather than
  into `INSTALL_K3S_EXEC`: the exec line is baked into the unit file at install
  time, so an argument put there would only change on a re-install, and a
  change to it would be invisible to the handler.
- **Pass-through arguments are parsed, not pasted.** `tasks/parse-extra-args.yml`
  turns `--key=value` into `key: value`, `--key` into `key: true`, and the same
  key twice into a YAML list. An argument whose key is one of
  `k3s_config_list_keys` (`node-label`, `node-taint`, `tls-san`, `kubelet-arg`,
  `disable`) is merged into the list the template writes from the matching role
  variable, so `k3s_node_labels` and a `--node-label` in the extra args both end
  up on the node.
- **One install path.** `tasks/install.yml` installs, starts and upgrades every
  node. The differences between a bootstrap server, a joining server and an
  agent come out of `vars/main.yml` (`k3s_service_name`, `k3s_install_exec`)
  and out of the template, which decides on its own whether the node writes
  `cluster-init: true` or `server:` + `token:`.
- **Two branches in `main.yml`, not three.** The bootstrap node has to finish
  before the others start, because they read its join token out of its facts.
  `tasks/control-init.yml` is `install.yml` plus that token read.
- **The bootstrap node is picked, not configured.** `pre-flight-checklist.yml`
  takes the first control host out of `ansible_play_hosts`. It also refuses to
  run when k3s is up on some other node but not on that one.
- **Cilium goes in between the two branches, not after them.** A node that
  joins a cluster without a CNI stays NotReady, so `tasks/cilium.yml` runs on
  the bootstrap node after `control-init.yml` and before the other nodes are
  installed. It waits for the DaemonSet, so the network is up before anything
  else arrives.

### Design notes

- `k3s_token` is gathered in `tasks/control-init.yml` after bootstrap, from
  `/var/lib/rancher/k3s/server/node-token`. It is not user-supplied. Joining
  nodes read it out of `hostvars[k3s_first_control_node]['k3s_token']`, not out
  of a bare `k3s_token`: the `set_fact` is host-scoped, so the bare name is
  undefined everywhere except on the bootstrap node itself.
- `write-kubeconfig-mode`, `disable`, `tls-san`, `embedded-registry` and the
  Cilium keys are emitted only when `k3s_node_role == 'control'`. They are
  server-only flags, and `k3s agent` exits with
  `flag provided but not defined` on any of them.
- **Readiness is checked with `k3s kubectl get --raw /readyz`, not with an
  HTTP request.** k3s turns anonymous authentication off, so `/readyz`,
  `/livez`, `/healthz` and `/version` answer `401` to an unauthenticated
  caller. Only `/ping` and `/cacerts` are open, and `/ping` says nothing about
  the API being ready. `kubernetes.core` is no help either: it needs the python
  kubernetes client on the target.
- **The rolling restart is `throttle: 1`, and that is not a strict roll.**
  Ansible's linear strategy finishes a task on every host before it starts the
  next one, so the two handlers run "restart A, restart B, restart C" and only
  then "wait for A, wait for B, wait for C". A strict one-node-at-a-time roll
  needs `serial:` on the play, which a role cannot set. Handlers cannot be
  blocks either — a block in `handlers/` takes neither a name nor a `listen`,
  so the pair is two tasks on one `listen` topic.
- **The handler stays quiet on a first install.** It is guarded by
  `k3s_already_running`, the state of the node *before* this run. The install
  path starts the service itself, and restarting it again would break the
  promise that adding a node leaves the running nodes alone.
- **Cordon and drain happen before an upgrade only**, not before a
  configuration change. A k3s restart is short, and draining on every change
  would move every workload twice for nothing. The drain is delegated to the
  first control node, because a worker has no API of its own. `throttle: 1`
  keeps the API from being hit by every node at once; it does not make the
  upgrade a rolling one, for the reason above.
- **`delegate_to` is templated before `when` is evaluated.** `tasks/verify.yml`
  delegates a task to `k3s_first_control_node`, and that fact only exists on
  the `k3s_state: present` path. `main.yml` therefore pulls `verify.yml` in
  with `include_tasks`, not `import_tasks`: a dynamic include is skipped
  whole, while an import would still resolve the delegation and fail the
  uninstall path with "'k3s_first_control_node' is undefined".
- **Cilium is installed once and then handed over.** `tasks/cilium.yml`
  writes a HelmChart CR into `k3s_manifests_dir` and, after the DaemonSet is
  ready, touches `cilium.yaml.skip` next to it. Three facts from the k3s
  documentation drive that shape:
  - k3s applies a manifest **when the server starts and when the file
    changes**. A file left under the role's control would be re-applied on
    every restart of every server, and would overwrite whatever manages
    Cilium afterwards (ArgoCD, in this homelab).
  - **Deleting a manifest file does not delete the objects it created**, and a
    `.skip` file is treated "as if the manifest did not exist". Neither
    removes anything. That is what makes the handover safe.
  - **Deleting the HelmChart resource is not safe.** helm-controller runs
    `helm delete` in a job when the CR goes away, and that takes the CNI down.
    Remove the file, never the CR.
  The marker is also the guard on the write: once it exists, the role does not
  render the manifest again. A change to `k3s_cilium_version` on a cluster
  that already runs Cilium therefore does nothing, by design.
- **The CR carries `bootstrap: true`.** Without it, helm-controller schedules
  its install job like any other pod, and the job waits for the network that
  this very chart has to bring up. With it, the job runs on the host network
  and tolerates a NotReady node.
- **`tasks/verify.yml` waits for the nodes to be Ready.** Two waits, because
  the failures mean different things: a node that never registers has a token,
  address or firewall problem; a node that registers and stays NotReady has a
  CNI problem. Both retry loops carry `ignore_errors: true`, because a
  retry loop that runs out of attempts fails the task whatever `failed_when`
  says, and the assert behind it is where the useful message lives.
- `defaults/main.yml` and `meta/argument_specs.yml` must agree. Every variable
  with a default in the arg spec is uncommented in `defaults/main.yml` with the
  same value. The `local` scenario loads `defaults/main.yml` through
  `vars_files` to render the template, so a default that drifts shows up as a
  failing case there.

## Implementation status (2026-09-11)

Scope boundary: `meta/argument_specs.yml`. A variable counts as done only when
it changes the state of the node.

**All 21 variables are fully implemented.**

| Variable | Where it takes effect |
|---|---|
| `k3s_state` | `tasks/uninstall.yml`, branched in `tasks/main.yml` |
| `k3s_node_role` | `vars/main.yml` (unit name, install exec) and the server-only guard in the template |
| `k3s_release_channel` | `INSTALL_K3S_CHANNEL` in `tasks/install.yml` |
| `k3s_version` | `INSTALL_K3S_VERSION` in `tasks/install.yml` |
| `k3s_upgrade` | install re-run, drain, restart and uncordon in `tasks/install.yml` |
| `k3s_snapshotter` | `snapshotter` in the config |
| `k3s_cni` | `flannel-backend: none` + `disable-network-policy` in the config, and the HelmChart CR from `tasks/cilium.yml` |
| `k3s_cilium_version` | `spec.version` of the HelmChart CR |
| `k3s_cilium_values` | `spec.valuesContent` of the HelmChart CR |
| `k3s_kube_proxy_replacement` | `disable-kube-proxy` in the config plus `kubeProxyReplacement` in the Helm values |
| `k3s_tls_san` | `tls-san` in the config |
| `k3s_node_labels` | `node-label` in the config |
| `k3s_node_taints` | `node-taint` in the config |
| `k3s_kubelet_args` | `kubelet-arg` in the config |
| `k3s_extra_server_args` | parsed into config keys by `tasks/parse-extra-args.yml` |
| `k3s_extra_agent_args` | same |
| `k3s_kubeconfig_fetch` | `tasks/post-install.yml`, slurp + rewrite + copy to the controller |
| `k3s_kubeconfig_dest` | same |
| `k3s_sysctl_settings` | `tasks/common.yml` |
| `k3s_local_path_provisioner_enabled` | `disable: local-storage` in the config when false |
| `k3s_spegel_enabled` | `embedded-registry` in the config plus `registries.yaml` on every node |

### Verified non-issues — do not "fix" these again

- **The `.skip` handover works, and it was measured.** On a live scenario
  node: annotate the HelmChart CR the way ArgoCD would, change the version in
  `cilium.yaml`, restart k3s. With `cilium.yaml.skip` in place the CR keeps
  the running version; with the marker removed the same restart writes the
  file back over the CR. Nothing is deleted in either case.
- `default(omit)` inside `environment:` **does** remove the key. Tested on
  ansible-core 2.21.3: with `k3s_release_channel` undefined, the child process
  has no `INSTALL_K3S_CHANNEL` in its environment at all.
- `changed_when: true` on the install task **does not** break idempotence. The
  `when: not (k3s_already_running | bool) or k3s_upgrade` guard skips the task
  on a re-run, so molecule's idempotence step never reaches it. The one
  remaining wart is narrow and intended: with `k3s_upgrade: true`, every run
  reports changed even when the version already matches.
- `daemon_reload: true` on `ansible.builtin.systemd` **does not** report
  changed on its own (checked in the module source), so it is safe inside an
  idempotent task.
- `tasks/main.yml`: the bootstrap branch runs when the host is the first
  control node, but it does not test `k3s_node_role == 'control'`. Pre-flight
  makes this safe. The implicit guard is a deliberate choice — leave it.

### Linting

`ansible-lint --offline .` reports four failures. None of them is a defect in
the role, and all four predate or follow from the environment:

- `schema[meta]` on `Ubuntu 24.04` — ansible-lint carries a stale Galaxy
  platform list. The role really does target 24.04.
- `syntax-check[unknown-module]` on `ansible.posix.sysctl` and
  `community.crypto.x509_certificate_info` — ansible-lint runs in its own
  virtualenv without the collections. Both are declared in
  `molecule/resources/collections.yml` and resolve at run time.
- `jinja[invalid]` in `molecule/local/tasks/expect-rejected.yml` — the linter
  renders the template with no variables in scope, so `case_expect` is
  undefined. It is defined by every caller.

### Environment notes

- The multi-node scenarios put their containers on a user-defined Docker
  network, where Docker's embedded DNS answers with AAAA records although the
  container has no IPv6 route. `molecule/resources/prepare.yml` writes
  `Acquire::ForceIPv4` before it touches apt; without it, the prepare step
  stalls for many minutes on every multi-node scenario.
- **The `cilium` scenario is the one that depends on the host kernel.** Cilium
  needs a private cgroup namespace, bpffs and `/lib/modules`; the header of
  `molecule/cilium/molecule.yml` lists the whole set. Two traps came out of
  building it:
  - `geerlingguy/docker-ubuntu2204-ansible` declares `/sys/fs/cgroup` as a
    `VOLUME`, so Docker puts an anonymous **ext4** volume there. systemd then
    finds no hierarchy and the container exits with 255 and no log line at
    all. The other scenarios hide this by bind-mounting the cgroup tree of the
    host, which only works with `cgroupns_mode: host`. The `cilium` scenario
    mounts cgroup2 in its entry point instead, the way kind does.
  - Docker mounts the `/run` tmpfs **private**, and systemd sets the
    propagation of `/` but not of `/run`. The cilium-agent container then
    never starts: "path /var/run/netns is mounted on /run but it is not a
    shared or slave mount". The entry point runs `mount --make-rshared /run`
    before systemd, and the flag survives the boot.
  - With `/lib/modules` mounted, `kmod-static-nodes.service` fails and systemd
    reports `degraded`. Nothing k3s needs is in that unit.

### Last full run (2026-09-11)

All ten scenarios pass end to end, idempotence included. `cilium` was run on
its own (`molecule test -s cilium`), the other nine through
`scripts/molecule-tally.sh`.

| Scenario | Time |
|---|---|
| `local` | 0m27s |
| `default` | 1m50s |
| `features` | 2m04s |
| `workers` | 2m43s |
| `ha` | 3m58s |
| `add-node` | 2m50s |
| `uninstall` | 2m21s |
| `upgrade` | 4m18s |
| `cluster` | 3m44s |
| `cilium` | ~9m — the image pull from quay.io is most of it |

## Open points

Nothing in `meta/argument_specs.yml` is unimplemented. What is left is
housekeeping, and one decision the homelab will answer:

1. `meta/main.yml` claims Ubuntu 24.04 while the scenarios run
   `geerlingguy/docker-ubuntu2204-ansible`. The homelab is the authority.
2. The handover leaves the role unable to upgrade Cilium. That is the design
   (see the design notes). If the homelab ever wants the role to own the chart
   again, the answer is to remove `cilium.yaml.skip` by hand, not to add a
   variable.
3. No scenario runs Cilium on more than one node. The `cilium` scenario is a
   single control-plane node, and the multi-node scenarios use flannel. What
   is untested is therefore a worker that joins a Cilium cluster and waits for
   its agent. The homelab is the first place that combination runs. A
   `cilium` variant of `workers` would cost five more image pulls per run.

## Testing

Molecule, ten scenarios. Nine run on Docker; `local` runs on the Ansible
controller and needs no container at all. Every mise task goes through
`scripts/molecule-tally.sh`, which runs the scenarios one after the other,
keeps going when one fails, and prints a pass/fail table with times. Its exit
status is 0 only when every scenario passed.

| Task | Scenarios | Covers |
|---|---|---|
| `mise run fast` | `local`, `default` | Input contract and config rendering, then a single control-plane node on role defaults. |
| `mise run full` | all ten | Every topology and every in-scope variable. |
| `mise run scenario <name>...` | the named ones | One or a few, for iterating. |

### The scenarios

| Scenario | Shape | Covers |
|---|---|---|
| `local` | no node at all | 33 cases: 22 against `tasks/validate-variables.yml`, 11 against what `templates/config.yaml.j2` renders. Seconds, where every other scenario takes minutes. |
| `default` | 1 control | Config templating, service state, single-node readiness, idempotence, `local-path` off by default. |
| `features` | 1 control | The per-node variable surface at once: labels, taints, kubelet args, extra server args, sysctl, local-path on, Spegel, kubeconfig fetch. |
| `cilium` | 1 control | `flannel-backend: none`, `disable-network-policy`, `disable-kube-proxy`, the HelmChart CR, the Cilium DaemonSet rolled out, the node Ready, and the `.skip` handover marker. The only scenario that needs a kernel surface of its own. |
| `workers` | 1 control + 2 workers | Agent join, agent-only variables (`k3s_extra_agent_args`, worker labels), no server unit on a worker. |
| `ha` | 3 control | Server join, etcd quorum, TLS SANs on the API certificate, the rolling restart after a config change. |
| `add-node` | 1 control + 2 workers | Converges two nodes, then adds the third: the new node joins and the running nodes are never restarted. |
| `uninstall` | 1 control + 1 worker | `k3s_state: absent` on both kinds of node, run twice, then no leftovers. |
| `upgrade` | 1 control + 1 worker | Opt-in upgrades: newer channel with `k3s_upgrade` off changes nothing, with it on moves a minor version, and no node is left cordoned. |
| `cluster` | 3 control + 2 workers | The homelab shape. Server join and agent join against the same cluster. Heaviest scenario — `ha` and `workers` are its two halves, so run those first. |

### How the scenarios are written

- **Everything that does not need a node runs in `local`.** It uses molecule's
  `default` driver, so there is no container to build, start or throw away.
  Two things live there: the input contract, and the rendering of
  `config.yaml.j2` — which is where ten of the role's variables turn into node
  state. `tasks/expect-config.yml` runs the real `parse-extra-args.yml` and the
  real template through the `template` lookup, so the cases cannot drift away
  from the role. The inventory carries a second host, `k3s-render-peer`, that
  no play ever runs on: the "joining node" cases need a bootstrap node in
  `hostvars` to point at.
- **Tally inside the verify, where it pays.** `local`, `features` and `cilium`
  check many independent things, so every check runs and one report task at the
  end fails with the whole table. Stopping at the first gap would hide the
  rest. The topology scenarios stay fail-fast: once a cluster is broken, the
  assertions behind the break mean nothing.
- **Effect over rendering.** Where the contract leaves the mechanism open, the
  assertion reads the live node object, `/proc`, or the API certificate rather
  than `config.yaml`. `k3s_extra_server_args` carries a `--node-label` so that
  its effect shows up on the node; whether the role puts the argument in
  `config.yaml` or in `INSTALL_K3S_EXEC` is not asserted. Where k3s dictates the
  key (`flannel-backend`, `embedded-registry`), the assertion reads the config.
  The `local` scenario is the deliberate exception: rendering is all it can
  see, and checking it there is far cheaper than booting a node for it.
- **Shared playbooks.** `molecule/resources/` holds `prepare.yml`,
  `converge.yml` and `collections.yml`. Scenarios point at the first two through
  `provisioner.playbooks`; `collections.yml` is symlinked into each scenario,
  because molecule looks for it in the scenario directory and ignores a
  `requirements-file` option pointing elsewhere.
- **Docker everywhere else.** The `cluster` scenario used to run real VMs
  through Multipass on the delegated driver. Docker keeps every remaining
  scenario on the same host tooling. The cost is fidelity: no kernel isolation
  between "nodes", and `k3s_snapshotter` must be `native` because overlayfs does
  not nest. The `cilium` scenario buys a part of that fidelity back with the
  mounts and the namespace listed in its header, which is what lets it assert
  the dataplane.
- **No taint assertions in the multi-node scenarios.** Auto-tainting control
  nodes when a worker is present is **not** a feature of this role. An earlier
  version of the `cluster` scenario tested for it.
- **Version pins to keep current.** `cilium/molecule.yml` pins
  `k3s_cilium_version`, and `upgrade/molecule.yml` pins two adjacent k3s minor
  channels. Both carry a comment saying so.

## v1.0.0 scope (locked 2026-08-16)

Full details in memory (`k3s-role-v1-scope.md`). Summary:

### In scope

- Single-node (SQLite) + embedded HA (etcd), full cluster bootstrap
- Install via `get.k3s.io`, channel tracking or version pinning
- Opt-in upgrades (`k3s_upgrade`), cordon & drain before restart
- Cilium CNI via HelmChart CR in manifests dir (with `--disable-kube-proxy`
  support)
- Spegel (enable-able)
- TLS SANs, node labels, node taints
- Pass-through: kubelet args, extra server/agent args
- Sysctl tuning (inotify)
- Config-change rolling restart (handler + `throttle: 1`)
- Join new nodes on re-run
- Uninstall mode (`k3s_state: absent`)
- Idempotent re-runs, verify step

### Explicitly out of scope

External datastore HA, air-gapped install, node role changes, node name
override, firewall/kernel/swap, custom CA, cert rotation, private registries,
SELinux, Longhorn/storage (separate role + ArgoCD), disabling individual k3s
built-ins beyond Cilium needs.
