<!-- BEGIN_ANSIBLE_DOCS -->

# Ansible Role: ispconfig_proxy

create the reverse-proxy vhost for the external services in ISPConfig

Tags: ispconfig, proxy, homelab

## Requirements

| Platform | Versions     |
| -------- | ------------ |
| Ubuntu   | 22.04, 24.04 |

## Role Arguments

### Entrypoint: main

Create the reverse-proxy vhost for the external services in ISPConfig.

Runs on the host that serves ISPConfig and talks to its JSON API there. One
vhost carries every service with `external` set, the first name as the domain
and the others as alias domains, with Apache directives that proxy everything to
`ispconfig_proxy_upstream` and a Let's Encrypt certificate that ISPConfig issues
for all of them.

The vhost is read first, created when missing, and updated when its directives
or its alias list differ. It is never deleted, not even when the last external
service leaves the list.

| Option                    | Description                                                                                                                                                                                                                                      | Type                                | Required | Default |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------- | -------- | ------- |
| ispconfig_proxy_api_url   | The JSON endpoint of the ISPConfig remote API, for example `https://panel.example.com/remote/json.php`. The method name is appended as the query string.                                                                                         | str                                 | yes      |         |
| ispconfig_proxy_username  | Remote user of the ISPConfig API (System > Remote Users).                                                                                                                                                                                        | str                                 | yes      |         |
| ispconfig_proxy_password  | Password of that remote user.                                                                                                                                                                                                                    | str                                 | yes      |         |
| ispconfig_proxy_upstream  | Where the vhost proxies to, as a URL with a trailing slash, for example `https://10.0.0.2/`. In the homelab this is the tunnel address of the gateway; it is written down here on purpose and not derived from the wireguard variables.          | str                                 | yes      |         |
| ispconfig_proxy_server_id | The `server_id` in ISPConfig that hosts the vhost.                                                                                                                                                                                               | int                                 | no       | 1       |
| ispconfig_proxy_client_id | The ISPConfig client the vhost belongs to. `0` is the admin.                                                                                                                                                                                     | int                                 | no       | 0       |
| services                  | The services this homelab exposes, declared once in `group_vars/all` and read by every role that needs them. This role reads `name` and `external` and ignores the rest; the shape is declared in full so that a typo in any key fails here too. | list of dicts of 'services' options | yes      |         |

#### Options for main > services

| Option      | Description                                                                                           | Type | Required | Default |
| ----------- | ----------------------------------------------------------------------------------------------------- | ---- | -------- | ------- |
| name        | The full FQDN of the service.                                                                         | str  | yes      |         |
| dns_target  | The A record the dns role writes. Not read here.                                                      | str  | yes      |         |
| backend     | The haproxy pool the service points at. Not read here.                                                | str  | yes      |         |
| mode        | `https` when omitted. A `tcp` service cannot be external, because the vhost is an HTTP reverse proxy. | str  | no       |         |
| listen_port | The haproxy frontend port of a `tcp` service. Not read here.                                          | int  | no       |         |
| external    | `false` when omitted. `true` means exactly that the vhost carries this name.                          | bool | no       |         |

#### Choices for main > services > mode

| Choice |
| ------ |
| https  |
| tcp    |

## Dependencies

None.

## Example Playbook

```
- hosts: all
  tasks:
    - name: Importing role: ispconfig_proxy
      ansible.builtin.import_role:
        name: ispconfig_proxy
      vars:
        ispconfig_proxy_api_url: # required, type: str
        ispconfig_proxy_username: # required, type: str
        ispconfig_proxy_password: # required, type: str
        ispconfig_proxy_upstream: # required, type: str
        services: # required, type: list of dicts of 'services' options
```

## License

MIT

## Author and Project Information

Jonathan Gerdes

<!-- END_ANSIBLE_DOCS -->

## Usage

```yaml
- name: Publish the external services through the VPS
  hosts: vps
  become: true
  roles:
    - role: ispconfig_proxy
```

The role runs on the host that serves ISPConfig and talks to its JSON API there.
It reads the `services` list from `group_vars/all` and puts every service with
`external: true` on one site: the first name is the domain of the site, every
further name an alias domain of it. The site proxies everything to
`ispconfig_proxy_upstream` and carries a Let's Encrypt certificate for all of
its names, issued by ISPConfig.

```yaml
# group_vars/vps/vars.yml
ispconfig_proxy_api_url: https://panel.example.com/remote/json.php
ispconfig_proxy_username: "{{ vault_ispconfig_proxy_username }}"
ispconfig_proxy_password: "{{ vault_ispconfig_proxy_password }}"
ispconfig_proxy_upstream: https://10.0.0.2/
```

The site is read first, created when missing, and updated when its Apache
directives or its alias list differ. It is never deleted. A name that already
exists in ISPConfig as a site of its own, or as an alias of another site, stops
the run with a message that names it; the person decides in the panel.

## Testing

The role is covered by four Molecule scenarios. One of them runs on the Ansible
controller, the other three in Docker, against a stand-in for the ISPConfig JSON
API that the scenarios start themselves.

| Task                          | Covers                                                                   |
| ----------------------------- | ------------------------------------------------------------------------ |
| `mise run fast`               | `local`, then the homelab shape: one site, two aliases, created once.    |
| `mise run full`               | All four scenarios: the update in place and the name that is in the way. |
| `mise run scenario <name>...` | The named scenarios, for iterating.                                      |

`CLAUDE.md` holds the full scenario table, what the stub answers, and the
reasons behind it.

## License

MIT
