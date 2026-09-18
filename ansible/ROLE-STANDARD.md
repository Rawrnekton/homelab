# Role standard

`CONVENTIONS.md` says how the tasks inside a role must be written. This file
says what a role must **ship** before it counts as done: a declared variable
contract, tests that prove the contract, and docs that stop the next reader from
re-deriving the decisions.

It is written out of the `k3s` refactor (2026-08 to 2026-09), which is the first
role in this repo to satisfy all of it. Where a rule below sounds oddly
specific, it is because that role paid for it. Read `roles/k3s/CLAUDE.md` for
the worked example; everything role-specific stays there, and everything general
is here.

Apply this to a role **while** refractoring it, not as a later pass. The 2026-07
review (`ROADMAP.md`) deliberately did not score any of this, because no role
had it. That gap is what this document closes.

## 1. Lock the scope before writing tasks

Write the in-scope and out-of-scope list first, date it, and keep it in the
role's `CLAUDE.md`. Not as a wish list — as a boundary you refuse to cross
during the refractor.

The out list is the half that does the work. "External datastore HA, air-gapped
install, node role changes, firewall, custom CA" as an explicit **out** for
`k3s` is what kept that role finishable. Without it every interesting question
re-opens the design.

A role with no written scope has no definition of done, so it never reaches one.

## 2. `meta/argument_specs.yml` is the variable contract

Every variable the role accepts is declared there, with a type, a description,
and `required` or a default. This is the only list that counts.

- **`defaults/main.yml` and the arg spec must agree.** Every variable with a
  default in the spec appears uncommented in `defaults/main.yml` with the same
  value. This supersedes `CONVENTIONS.md` rule 3: the spec is now the thing that
  must be real, and the defaults file must match it.
- **A variable is implemented only when it changes the state of the host.**
  Accepted and ignored is worse than not accepted. Keep a table in the role's
  `CLAUDE.md` that maps every variable to the file where it takes effect. If a
  row cannot be filled in, the variable is not done.
- **Validate the inputs in the role, early.** A dedicated
  `tasks/validate-variables.yml` that asserts types, mutual exclusions and
  allowed values fails the run in seconds with a useful message, instead of half
  way through an install with a Jinja error.

Ansible validates the spec for you on every run, which makes this the cheapest
guard rail in the list.

## 3. Molecule, with one scenario per shape

A role is done when it is **proven**, not when it worked once by hand.

- **One scenario per topology and one per variable group.** For `k3s` that is
  ten: `local`, `default`, `features`, `cilium`, `workers`, `ha`, `add-node`,
  `uninstall`, `upgrade`, `cluster`. A simpler role needs fewer. The set, not
  the count, is the point: every shape the role claims to support gets one.
- **Put everything that needs no host in a scenario with no host.** The `local`
  scenario uses molecule's `default` driver, starts no container, and covers 33
  cases in 27 seconds: the input contract, and what the config template renders.
  Every other scenario costs minutes. Contract tests belong in the cheap one.
- **Idempotence is a test step, not a claim.** Molecule's `idempotence` step
  runs in every scenario. `CONVENTIONS.md` rule 5 asks for idempotency; this is
  where you find out whether you got it.
- **Assert the effect, not the rendering.** Where the contract leaves the
  mechanism open, read the live object, `/proc`, or the certificate — not the
  config file the role just wrote. Reading back your own template proves
  nothing. Assert the config only where the upstream tool dictates the key.
- **Uninstall and re-run are scenarios too.** `uninstall` runs twice and then
  checks for leftovers. `add-node` proves that a new host joins and the running
  hosts are **not** restarted. Those two catch the failures that a green first
  run hides.
- **Share the playbooks.** `molecule/resources/` holds `prepare.yml`,
  `converge.yml` and `collections.yml`; scenarios point at them through
  `provisioner.playbooks`. Do not copy a converge playbook ten times.
- **Tally where a run checks many independent things; fail fast where it does
  not.** A contract or feature scenario should run every check and report one
  table, because stopping at the first gap hides the rest. A topology scenario
  stays fail-fast: once the cluster is broken, the assertions behind the break
  mean nothing.
- **Give the run a short and a long form.** `mise run fast` for the two cheap
  scenarios while iterating, `mise run full` for all of them. A test suite you
  only run at the end is one you stop running.

## 4. Write down what you must not rediscover

Every refractor turns up facts that cost hours and are invisible in the finished
code — an API that answers 401, an option that does not do what its name says, a
container image with a trap in it. These are the most expensive lines in the
role and the easiest to lose.

Each role carries:

- **`CLAUDE.md`** — why the role is shaped the way it is. The design decisions,
  the variable-to-effect table, the traps, and a **"verified non-issues — do not
  fix these again"** section. That last heading is worth copying verbatim. It is
  what stops the next pass from re-opening a question that was already measured
  and settled.
- **`HANDOFF.md`** — where the work stopped, what the last full test run looked
  like, and what is open. Delete it when the role is merged and finished; it is
  a baton, not documentation.
- **`README.md` and `meta/main.yml`** — filled in for real, or the
  `ansible-galaxy init` boilerplate removed. `CONVENTIONS.md` rule 8 already
  says this. An untouched `author: your name` block advertises that the role was
  never finished.

Record open points as numbered questions with the answer named, not as `# TODO`.
`CONVENTIONS.md` rule 6 forbids the TODO; this is where the content goes
instead.

## 5. Lint, and explain every remaining failure

`ansible-lint --offline .` runs clean, or every remaining failure is listed in
the role's `CLAUDE.md` with the reason it is not a defect. `k3s` has four, all
of them environment artefacts — a stale platform list, two collections the
linter cannot see, a template rendered without its variables.

An unexplained lint failure is indistinguishable from a real one, so the next
person either fixes nothing or fixes the wrong thing.

## Checklist

Before a role branch is ready for review:

- [ ] Scope list written, dated, and the **out** half is real
- [ ] `meta/argument_specs.yml` complete; `defaults/main.yml` agrees with it
- [ ] Every variable maps to the file where it takes effect
- [ ] `tasks/validate-variables.yml` asserts the inputs early
- [ ] One molecule scenario per supported shape; the cheap contract scenario
      exists
- [ ] Idempotence passes in every scenario
- [ ] Uninstall and re-run/add-node are covered
- [ ] `CLAUDE.md` holds the design notes, the traps, and the non-issues
- [ ] `README.md` and `meta/main.yml` are real, not boilerplate
- [ ] `ansible-lint` clean, or every failure explained
