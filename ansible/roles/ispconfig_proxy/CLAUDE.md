# ispconfig_proxy role

Ansible role that creates the reverse-proxy site on the VPS, in ISPConfig, for
every service the homelab marks `external`. The site proxies to the gateway
through the WireGuard tunnel and carries the Let's Encrypt certificate ISPConfig
issues for its names.

Read `../../CLAUDE.md` first; this file only holds what applies to this role.

## Scope (locked 2026-09-18)

This role is the second half of the old `wireguard` role, which scored 2 of 10
in the 2026-07 review because it logged in to ISPConfig from a role named after
a VPN daemon, with a hardcoded backend address in a raw string. The shape was
decided in `../../ROADMAP.md`, "The `wireguard` split" and "The `services`
shape".

### In

- Runs on the `vps` host and calls the ISPConfig JSON API there, with plain
  `uri` tasks; no delegation to the controller
- Reads `services` from `group_vars/all`; every entry with `external: true` is a
  name on the site
- **One site** for all external names: the first as the domain, the rest as
  alias domains. Let's Encrypt on, so ISPConfig issues one certificate for all
  of them
- Read first, create when missing, update when the Apache directives or the
  alias list differ. Aliases that left the list are removed
- The upstream is `ispconfig_proxy_upstream`, a variable in `group_vars/vps`
  with a comment. It is not derived from the `wireguard` variables
- A name that exists in ISPConfig as something this role does not own (a site of
  its own, an alias of another site) fails the run with a message that names it
- One API session per run, closed in `always`
- Input contract in `meta/argument_specs.yml` plus the cross-field rules in
  `tasks/validate-variables.yml`

### Out

- Deleting the site, even when the last external service leaves the list
- Taking over or deleting sites the role did not create (the old layout, one
  site per service, is removed by hand once)
- One site per service
- Anything else in ISPConfig: clients, DNS, mail, the panel itself
- Variables for the vhost parameters other than the upstream and the ids
  (`vars/main.yml` holds them, fixed)
- A `state: absent`

## How the role is put together

`tasks/main.yml` validates, collects the external names, and imports
`tasks/vhost.yml` when there is at least one. `vhost.yml` is one block: log in,
read the site, create or update it, read its aliases, check the ones to add are
free, add and remove, log out in `always`. What the API does was read from the
ISPConfig 3.3.2 source (`interface/lib/classes/remoting.inc.php`,
`remote.d/sites.inc.php`, `sites/form/*.tform.php`), not guessed:

- **The API answers HTTP 200 to everything.** Errors come back in the body as
  `{"code": "remote_fault", "message": ..., "response": false}`. Every `uri`
  task has `failed_when: json.code != 'ok'`; the module's own status check adds
  nothing.
- **`sites_web_domain_get` with an object as `primary_id` is a query.** It
  filters `web_domain` by equality on every key and returns a list, empty when
  nothing matches. With an integer it returns one record. The role only queries:
  by `domain` for the site and for every alias name to add, by
  `parent_domain_id` + `type: alias` for the current aliases.
- **`sites_web_domain_update` merges the old record with the params**, so a
  partial update would keep the other fields. It also resets an empty
  `pm_max_children`, `pm_start_servers` and friends to its own defaults before
  the merge, so a partial update would change them. The role sends the full
  parameter set on update, the same dictionary as on create.
- **An alias domain is a `web_domain` row with `type: alias` and
  `parent_domain_id`.** `sites_web_aliasdomain_add` uses the `web_childdomain`
  form, whose `type` default is not a valid type, so the role sends
  `type: alias` itself. Apache gets a `ServerAlias` per active alias, and the
  Let's Encrypt request includes every active alias without
  `ssl_letsencrypt_exclude: y`. Nothing else has to be done for the certificate
  to cover the aliases.
- **The domain column is unique across sites, aliases and subdomains**
  (`domain_error_unique`). That is why a name to add is looked up first: the
  error ISPConfig would give says nothing about what is in the way.
- **`proxy_protocol: n`**, as before: counter-intuitive, but `y` breaks the
  proxy. The whole vhost dictionary lives in `vars/main.yml` with the reason for
  every deliberate value; the keys are the fields of the `web_vhost_domain`
  form, and the two keys the old payload sent that are not fields
  (`is_subdomainwww`, `tideways_sample_rate`) are gone.
- **The first external name is the site's domain, by order of `services`.**
  Reordering the list so that another name comes first makes the role look for a
  site by that name, find none, try to create it, and fail on the alias check
  (the old first name is a site of its own). That is the conflict message, not a
  silent second site. See open point 3.
- **Line endings are normalised before the directives are compared.** The panel
  saves CRLF when a person edits the field there; the API saves what it gets.

### Design notes

- `defaults/main.yml` and `meta/argument_specs.yml` must agree. Two variables
  have a default (`server_id` 1, `client_id` 0); the API URL, the credentials,
  the upstream and `services` have none, because there is nothing sane to point
  at.
- `services` is declared in the argument spec with its full shape, although the
  role reads only `name` and `external`. The shape is one cross-role definition;
  a typo in any key fails in every consumer, and `is_external` (the old key) is
  rejected as unknown.
- `ispconfig_proxy_password` is `no_log` in the spec; the login task and the
  session fact are `no_log` as well. The other API tasks are not: their bodies
  hold the session id, which dies with the logout.
- The alias check reads only the names to add. Aliases already on the site are
  by definition the role's own.

## Implementation status (2026-09-18)

Scope boundary: `meta/argument_specs.yml`. Every variable changes what the API
receives.

| Variable                                            | Where it takes effect                                                     |
| --------------------------------------------------- | ------------------------------------------------------------------------- |
| `ispconfig_proxy_api_url`                           | the URL of every `uri` task in `tasks/vhost.yml`                          |
| `ispconfig_proxy_username`                          | the login body                                                            |
| `ispconfig_proxy_password`                          | the login body                                                            |
| `ispconfig_proxy_upstream`                          | `ProxyPass` and `ProxyPassReverse` in `vars/main.yml`, through the params |
| `ispconfig_proxy_server_id`                         | `server_id` of the site and of every alias                                |
| `ispconfig_proxy_client_id`                         | `client_id` of every add and update call                                  |
| `services[].name`                                   | the site's `domain` (first) or an alias `domain` (rest)                   |
| `services[].external`                               | whether the name is on the site at all                                    |
| `services[].mode`                                   | the tcp-cannot-be-external rule in `tasks/validate-variables.yml`         |
| `services[].dns_target`, `.backend`, `.listen_port` | validated as part of the shape; read by other roles                       |

### Verified non-issues — do not "fix" these again

- **The role does not log in when no service is external.** By design: no site
  is created for nothing, and no site is deleted when the last service left, so
  there is nothing to say to the API. A wrong URL or password is then not
  noticed on that run; it is noticed on the first run with an external service.
- **Sending the full parameter set on update is not laziness.** See the
  `pm_max_children` reset above. The `update` scenario asserts that the value
  survives the update.
- **The stub is not ISPConfig.** It answers the seven methods the role calls the
  way the 3.3.2 source does, and refuses a duplicate domain with ISPConfig's own
  message. It does not validate the vhost fields, and it does not run the Apache
  or Let's Encrypt side. Open point 1 is where that is covered.

### Linting

`ansible-lint --offline .` reports two failures. Neither is a defect in the
role, and both have the same causes as in the other reworked roles:

- `schema[meta]` on `Ubuntu 22.04` — ansible-lint carries a stale Galaxy
  platform list. The role runs on 22.04 (molecule) and 24.04 (the VPS).
- `jinja[invalid]` in `molecule/local/tasks/expect-rejected.yml` — the linter
  renders the template with no variables in scope, so `case_expect` is
  undefined. It is defined by every caller.

### Environment notes

- The Docker scenarios run one container that is the VPS: the role runs in it,
  and so does the stand-in for the panel,
  `molecule/resources/files/ispconfig_stub.py`, as a systemd service on
  `127.0.0.1:8080`. The stub keeps its rows and a call counter per method in
  `/var/lib/ispconfig-stub/state.json`; the verifies read that file. The
  counters are how a scenario proves that a re-run did not create the site a
  second time, which `changed` alone cannot show.
- The `conflict` scenario has a converge of its own that expects the role to
  fail, so it has no idempotence step.

### Last full run (2026-09-18)

All four scenarios pass end to end, idempotence included, through
`scripts/molecule-tally.sh`.

| Scenario   | Time  |
| ---------- | ----- |
| `local`    | 0m09s |
| `default`  | 1m01s |
| `update`   | 1m07s |
| `conflict` | 0m54s |

## Open points

1. **The role has not been run against the real panel.** The stub answers as the
   source says ISPConfig does, and the vhost dictionary is the one the old role
   sent successfully; the alias calls are new. The first run on the VPS is the
   verification, with `-v` and a look at the panel afterwards.
2. **The old layout has to be removed by hand first.** The VPS has one site per
   external service today. `mealie.cindergla.de` is the first external name and
   stays as the site; `argocd`, `auth`, `todo`, `memories`, `copperforge` and
   `vorleser` are sites of their own and the role refuses to add them as aliases
   until they are deleted in the panel. ISPConfig then re-issues the certificate
   of the mealie site with every alias in it.
3. The site's domain follows the order of `services`. If the first external
   service ever leaves, the answer is to make its name an alias in the panel and
   the new first name the site, by hand, once; the role does not rename a site.
   A variable naming the site explicitly was considered and not added.
4. The two vault variables of the old role, `vault_wireguard_ispconfig_username`
   and `..._password`, live in `group_vars/homelab/vault`, which the VPS does
   not see. `group_vars/vps/vars.yml` reads `vault_ispconfig_proxy_username` and
   `..._password` from `group_vars/vps/vault`. Moving them is a vault edit that
   this rework could not do (see `HANDOFF.md`).
5. `meta/main.yml` claims Ubuntu 22.04 and 24.04. The scenarios run
   `geerlingguy/docker-ubuntu2204-ansible`; the VPS is the authority for its
   release.

## Testing

Molecule, four scenarios. Three run on Docker; `local` runs on the Ansible
controller and needs no container at all. Every mise task goes through
`scripts/molecule-tally.sh`.

| Task                          | Scenarios          | Covers                                               |
| ----------------------------- | ------------------ | ---------------------------------------------------- |
| `mise run fast`               | `local`, `default` | Input contract, then the homelab shape.              |
| `mise run full`               | all four           | The update in place and the name that is in the way. |
| `mise run scenario <name>...` | the named ones     | One or a few, for iterating.                         |

### The scenarios

| Scenario   | Shape                   | Covers                                                                                                                                                                                                                     |
| ---------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `local`    | no host at all          | 16 cases against the input contract: 7 against the argument spec (including the old `is_external` key), 6 against the cross-field rules, 3 inputs that must pass. Seconds.                                                 |
| `default`  | one container, the stub | Six services, three external, one tcp. After converge and idempotence: one site with the directives and Let's Encrypt, two aliases, nothing for the other names, `sites_web_domain_add` called once, both sessions closed. |
| `update`   | one container, the stub | Converges, then re-runs with another upstream, one alias dropped and one added. Same `domain_id`, new directives, `pm_max_children` intact, one add and one update call.                                                   |
| `conflict` | one container, the stub | prepare seeds a site for the second external name. The role fails and names it with its type and id; nothing was added or removed.                                                                                         |
