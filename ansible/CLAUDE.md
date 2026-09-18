# Ansible roles: the rules

Every role under `roles/` is written and reworked against this file. It came out
of the 2026-07 review of every role (`ROADMAP.md`, which also holds the rework
order and the per-role findings) and the `k3s` rework of 2026-08/09, the first
role to satisfy all of it. Where a rule sounds oddly specific, a role paid for
it.

Two more documents exist, and the split is by audience, not by topic:

- `ROADMAP.md` — the dated review. Read it to pick the next role and to see what
  the review found in it. It is not re-scored; a reworked role gets a status
  line instead.
- `roles/<name>/CLAUDE.md` — everything that applies to one role only: its
  scope, design decisions, variable-to-effect table, traps.
  `roles/k3s/CLAUDE.md` (on `refractor/cluster-setup` until merged) is the
  worked example.

General knowledge goes here. Role knowledge goes there. Apply the rules
**while** reworking a role, not as a later pass; the checklist at the end is the
definition of done.

## Branches

```
main -> refractor/2026 -> refractor/<role>
```

`refractor/2026` is the trunk: these docs and the inventory, never role code. A
rework branches off it, follows this file, and is rebased onto it once, at
review time. Do not merge a role branch to refresh the docs; edit them on the
trunk. GitHub deletes the head branch on merge, so a branch that is still needed
after its PR has to be pushed again.

A change to `group_vars`, `host_vars` or `site.yml` that a rework needs (a
renamed role, a renamed or reshaped variable) goes on the role branch, next to
the role that needs it. The trunk only owns the inventory files that no rework
is touching. This keeps the trunk mergeable into every role branch at any time,
and keeps a variable rename in the same commit as the tasks that read it.

## Starting a rework

The prompt for a fresh session is one line: "Rework the `<role>` role as listed
in `ansible/ROADMAP.md` and `ansible/CLAUDE.md`." Everything else the session
needs is in those two files: the rules here, the per-role scope block and the
cross-role decisions in `ROADMAP.md`. The standing instructions for every rework
are:

- Branch off `refractor/2026` into `refractor/<role>`, in its own worktree under
  `/home/jona/workspace/homelab.worktrees/refractor/<role>`, and push it.
- Rename the role if ansible-lint needs it (no hyphens). Move `site.yml` and the
  `group_vars` file with it, on the role branch.
- Molecule expects no outside infrastructure. Build what the tests need in
  Docker (a second container for a peer, a target, an API stub).
- When the scope has a question the code cannot answer, pick the option that
  adds nothing and list it under "Open points" in the role's `CLAUDE.md`.
- Run the full molecule suite, ansible-lint and prettier before the commit.
  Commit on the role branch, push, add the status line to `ROADMAP.md` on the
  trunk, and update the memory file for the branch strategy.
- Report at the end: what changed, what the tests found, what is open for the
  user.

## 1. Lock the scope before writing tasks

Write the in-scope and out-of-scope lists first, date them, and keep them in the
role's `CLAUDE.md`. The **out** list is the half that does the work: it is what
kept `k3s` finishable, because every interesting question stopped re-opening the
design. A role with no written scope has no definition of done, so it never
reaches one.

One role, one responsibility. If the role cannot be explained in one sentence
without an "and also", split it. `wireguard` also provisioning ISPConfig vhosts
is the failure mode.

## 2. `meta/argument_specs.yml` is the variable contract

Every variable the role accepts is declared there with a type, a description,
and `required` or a default. This is the only list that counts, and Ansible
validates it on every run.

- **`defaults/main.yml` agrees with the spec.** Every variable with a default
  appears there, uncommented, with the same value. No defaults that no task
  reads (`cluster-setup` had four), no placeholder values (`[foo, bar]`). If
  there is no sane default, leave it empty and say so.
- **A variable is implemented only when it changes the state of the host.**
  Accepted and ignored is worse than not accepted. The role's `CLAUDE.md` maps
  every variable to the file where it takes effect. A row that cannot be filled
  in means the variable is not done.
- **Validate the inputs early.** `tasks/validate-variables.yml` asserts types,
  mutual exclusions and allowed values, so a bad input fails in seconds with a
  useful message instead of half way through an install with a Jinja error.
- **Design the shape before writing tasks.** Decide what one list item
  _represents_ before looping over it. Two nouns need two variables, not one
  object wearing both hats. `haproxy_https_backends` is a routing rule, a server
  pool and a default-route flag at once, and every extension fights it.
- **One cross-role concept, one definition.** "A service this homelab exposes"
  is declared once, in one shape, in `group_vars`, and every role reads it. It
  is not re-declared locally because that suits one template. Today it exists as
  `services` and again as `haproxy_https_backends[].domains`, and nothing keeps
  them in sync.

## 3. Prefer the real module over `command` and `shell`

`service_facts` over `systemctl is-active`, `stat` over `ls`, `slurp` over
`cat`, `kubernetes.core.k8s_info` over `kubectl | grep | wc -l`. Idempotency
comes from checking structured state, not scraped text; `garage` checking
`ListBuckets` before it creates a bucket is the pattern.

Where no module exists (helm plugin install, a REST API), `command`, `shell` or
`uri` is fine. Say so in a comment, and do not let it become the default reach.
One tool, one way: Helm is driven through `kubernetes.core.helm` in one role and
through `helm` shell-outs in another, and that is one way too many.

## 4. Idempotency is tested, not claimed

Every task's changed and failed state reflects what happened on the host.
`changed_when: false` with a shrug comment is a marker to fix before the commit.
If the state is genuinely hard to determine, restructure the task (check first,
act only if needed) instead of faking the report. Molecule's `idempotence` step
runs in every scenario; that is where you find out.

Prefer the non-destructive operation when the difference shows on a second run.
`iscsi-client` avoids `sendtargets` discovery because it clobbers CHAP
credentials and `node.startup`, and its comment says so.

## 5. Molecule, one scenario per shape

A role is done when it is **proven**, not when it worked once by hand.

- **One scenario per topology and one per variable group.** `k3s` has ten; a
  simpler role needs fewer. Every shape the role claims to support gets one.
- **Everything that needs no host runs in a scenario with no host:** the input
  contract and what the templates render. Seconds, where every other scenario
  costs minutes. Contract tests belong there.
- **Assert the effect, not the rendering.** Read the live object, `/proc` or the
  certificate, not the config file the role just wrote. Assert the config only
  where the upstream tool dictates the key.
- **Uninstall and re-run are scenarios too.** Uninstall runs twice and then
  checks for leftovers. Add-node proves that a new host joins and the running
  hosts are **not** restarted. Those two catch what a green first run hides.
- **Share the playbooks.** `molecule/resources/` holds `prepare.yml`,
  `converge.yml` and `collections.yml`; scenarios point at them through
  `provisioner.playbooks`.
- **Tally where a run checks many independent things; fail fast where it does
  not.** A contract scenario runs every check and reports one table. A topology
  scenario stops at the first break, because the assertions behind it mean
  nothing.
- **Give the run a short and a long form.** `mise run fast` for the cheap
  scenarios while iterating, `mise run full` for all of them. A suite you only
  run at the end is one you stop running.

## 6. Write down what you must not rediscover

Every rework turns up facts that cost hours and are invisible in the finished
code: an API that answers 401, an option that does not do what its name says, a
container image with a trap in it. Each role carries:

- **`CLAUDE.md`** — the scope lists, the design decisions, the
  variable-to-effect table, the traps, and a **"verified non-issues — do not fix
  these again"** section. Copy that heading verbatim; it is what stops the next
  pass from re-opening a settled question. The global gitignore on this machine
  ignores `CLAUDE.md`, so add a new one with `git add -f` once; a tracked file
  stays tracked.
- **`HANDOFF.md`** — where the work stopped, the last full test run, what is
  open. A baton, not documentation: delete it when the role is merged.
- **`README.md` and `meta/main.yml`** — filled in for real, or the
  `ansible-galaxy init` boilerplate removed. An untouched `author: your name`
  advertises that the role was never finished.

No dead code, no deferred cleanup. Commented-out task blocks, leftover `debug`
tasks and `# TODO` comments do not ship. A constraint worth keeping becomes a
comment that explains _why_ (`iscsi-client/tasks/main.yml` is the standard). An
open point becomes a numbered question in `CLAUDE.md` with the answer named.
Comments, messages and scripts are English throughout; `certbot`'s German
`new_cert.sh` is the outlier.

## 7. Lint, and explain every remaining failure

`ansible-lint --offline .` runs clean, or every remaining failure is listed in
the role's `CLAUDE.md` with the reason it is not a defect. An unexplained
failure is indistinguishable from a real one, so the next person either fixes
nothing or fixes the wrong thing.

## 8. Prettier formats everything under `ansible/`

Every Markdown, YAML and JSON file under `ansible/` is formatted before the
commit. The configuration is `.prettierrc` at the repo root
(`proseWrap: always`, `printWidth: 80`), so the rest of the repo can adopt it
later.

```
prettier --write "ansible/**/*.{md,yml,yaml,json}"
```

Jinja templates (`.j2`) are not covered; prettier would parse the delimiters as
content. Nothing enforces this yet. The trunk docs satisfy it, the role files do
not: format a role's files while reworking it, on its branch. A repo-wide
reformat now would collide with every open role branch.

## Checklist

Before a role branch is ready for review:

- [ ] Scope lists written and dated, and the **out** half is real
- [ ] `meta/argument_specs.yml` complete; `defaults/main.yml` agrees with it
- [ ] Every variable maps to the file where it takes effect
- [ ] `tasks/validate-variables.yml` asserts the inputs early
- [ ] One molecule scenario per supported shape; the no-host scenario exists
- [ ] Idempotence passes in every scenario
- [ ] Uninstall and re-run/add-node are covered
- [ ] `CLAUDE.md` holds the scope, the design notes, the traps, the non-issues
- [ ] `README.md` and `meta/main.yml` are real, not boilerplate
- [ ] `ansible-lint` clean, or every failure explained
- [ ] `prettier --check` passes for the role
