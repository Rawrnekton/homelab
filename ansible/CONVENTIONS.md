# Ansible ground rules

Ansible is the trunk of this repo's tree: it should be the most boring, most
predictable part of the whole homelab. These rules exist so that touching a role
six months from now doesn't require re-deriving decisions that were already made
once. They come out of a review of every role under `roles/` in 2026-07 (see
`ROADMAP.md`). Each rule below traces back to something that role review
actually punished.

Not covered here: the variable contract, testing, and the per-role docs
(`meta/argument_specs.yml`, `molecule/`, `README.md`, `meta/main.yml`). Those
have their own document now: `ROLE-STANDARD.md`. It was written out of the `k3s`
refactor, which is the first role to satisfy all of it.

## 1. One role, one responsibility

If a task file starts doing something that isn't in the role's name, that's a
new role. Naming a role after the tool it happens to install (`wireguard`) and
then also using it to provision unrelated infrastructure (an ISPConfig
reverse-proxy vhost via a raw JSON API call) is exactly the failure mode to
avoid. By the time I'm back in that file for a WireGuard change, half of it is
unrelated I have to read past.

Rule of thumb: Can I explain the role in one sentence without an "and also"? If
not, split it.

## 2. Variables: design the shape before writing tasks

Pick what a single list item in your variable _represents_ before you loop over
it. `haproxy`'s `haproxy_https_backends` is the cautionary tale: one object is
simultaneously "a routing rule" (domains -> ACL), "a server pool"
(port/ssl/health_check shared by all servers in it), and "the default route" (an
`is_default: true` flag with an unenforced invariant that exactly one entry must
set). Adding anything that doesn't fit that shape — a second port, a per-domain
backend or a redirect means fighting the schema instead of extending it.

Before adding a list-of-dicts default var, ask: what is the one noun this
represents? If you need two nouns, use two variables (or a nested structure that
keeps them separately named), not one object wearing both hats.

## 3. Every variable in `defaults/main.yml` must be real

If a task or template references `role_foo_bar`, `role_foo_bar` must exist in
`defaults/main.yml` with a usable example value (or be clearly documented as
required, with an `assert` early in `tasks/main.yml`). Dead defaults that no
longer match what the tasks use are worse than no defaults: They lie about
what's configurable. (`cluster-setup/defaults/main.yml` currently defines
`rancher_bootstrap_password` and `cluster_setup_ranche_hostname` that nothing
reads; the tasks actually use `cluster_setup_rancher_*`, defined only in
`group_vars`, invisible to anyone reading the role in isolation.)

Corollary: no placeholder junk as a default
(`cluster_setup_node_labels: [foo, bar]`). If there's no sane default, leave the
list empty and document that.

## 4. Prefer the real module over shell/command

`kubectl ... | grep | wc -l`, string-matching `stdout`/`stderr` to decide
`changed_when`, and re-implementing what a module already does correctly are all
signals to stop and check for a module first (`kubernetes.core.k8s_info`,
`kubernetes.core.helm`, `community.general.open_iscsi`, etc.). `garage`'s use of
`json-api` + `from_json` + `selectattr` to check for existing buckets/keys
before creating them is the standard to match: idempotency against structured
state, not scraped text.

When a module genuinely doesn't exist (helm plugin install, ISPConfig REST
calls) and `command`/`shell`/`uri` is unavoidable, that's fine — but say so in a
comment, and don't let it become the default reach for things that do have
modules (two roles in this repo drive Helm two different ways: one via
`kubernetes.core.helm`, one via raw `helm` shell-outs.).

## 5. Idempotency is not optional

`changed_when: false # i am too lazy rn to check this properly` is a marker to
fix before merging, not a place to leave a shrug. Every task's changed/failed
state should reflect what actually happened on the host. If that's genuinely
hard to determine, that's a sign the task should be restructured (check state
first, act only if needed) rather than have its reporting faked.

Related: don't reach for a destructive-by-default operation when a
non-destructive one exists and the difference matters. (`iscsi-client` avoids
`iscsiadm discovery sendtargets` specifically because it clobbers CHAP
credentials and `node.startup` on every run. That kind of "what does this
actually do to existing state on a second run" thinking is what separates the
good role in this repo from the rest.)

## 6. No dead code, no deferred cleanup

Commented-out task blocks, leftover `debug:` tasks, `# TODO: fix this properly`
comments describing a known-broken mechanism (see `wireguard`'s key-generation
TODOs) — these don't get to ship. If it's worth keeping as a note, it's worth a
real comment explaining _why_ the current code is the way it is (see
`iscsi-client/tasks/main.yml` for the standard: comments explain non-obvious
constraints, not narrate what the next line does). If it's not worth keeping,
delete it. Half-finished isn't a valid end state for a commit.

## 7. One cross-role concept, one definition

"A service this homelab exposes" is currently defined independently in at least
two places with two different shapes: the global `services` var (`name`,
`dns_target`, `is_external`, consumed by `dns` and `wireguard`) and
`haproxy_https_backends[].domains` (a bare list of short names, consumed only by
`haproxy` and indirectly by `certbot`'s cert-domain list). Adding a service
means remembering to update both, in different formats, with no enforcement that
they stay in sync. When a concept spans roles, it gets one variable, one shape,
defined once (`group_vars`), and every role reads from it. It doesn't get
reinvented locally because that's more convenient for one role's template.

## 8. Match the codebase's language and tooling consistently

Comments, error messages, and script output are English throughout, even in
one-off shell scripts (`certbot/files/new_cert.sh` is currently German — an
outlier, not a pattern to repeat). Same for boilerplate: `meta/main.yml` and
`README.md` get filled in for real, or the boilerplate gets removed. An
untouched `galaxy_info: author: your name` block is a tell that the role was
never really finished, and it advertises that to the very next person who opens
the file.

## 9. Prettier formats everything under `ansible/`

Every file in this tree that Prettier understands — Markdown, YAML, JSON — is
formatted by it before the commit. The configuration is `.prettierrc` at the
repo root (`proseWrap: always`, `printWidth: 80`), so the rest of the repo can
adopt it later; the rule itself covers `ansible/` for now. The config is the
whole argument: nobody re-wraps a paragraph by hand, and nobody reviews a diff
that is half content and half re-indentation.

```
prettier --write "ansible/**/*.{md,yml,yaml,json}"
```

Jinja templates (`.j2`) are not covered. Prettier does not know the extension
and must not be pointed at it — it would parse the Jinja delimiters as content.

Nothing enforces this yet: no CI job, no pre-commit hook. It is a rule you
follow, not a gate that catches you. `CONVENTIONS.md`, `ROADMAP.md` and
`ROLE-STANDARD.md` satisfy it. The role files do **not** yet — 27 of them still
fail `prettier --check`. Format a role's files as part of reworking that role,
in its own branch. A repo-wide reformat now would collide with every role branch
that is open.
