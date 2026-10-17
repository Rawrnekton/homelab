<!-- BEGIN_ANSIBLE_DOCS -->

# Ansible Role: k3s_rpi_host

prepare the boot configuration of a Raspberry Pi that runs k3s

Tags: raspberrypi, boot, k3s, homelab

## Requirements

| Platform | Versions |
| -------- | -------- |
| Debian   | trixie   |

## Role Arguments

### Entrypoint: main

Prepare the boot configuration of a Raspberry Pi that runs k3s.

Only for Raspberry Pis that run k3s. Apply it to the inventory group
`k3s_rpi_host`, never to all Raspberry Pis.

Adds kernel parameters to `/boot/firmware/cmdline.txt` and writes lines into a
managed block at the end of `/boot/firmware/config.txt`. Reboots the host when
one of the two files changed, then checks that the running kernel got every
parameter.

The role only adds kernel parameters. It never removes one, because it cannot
tell a parameter it added from one the image shipped with.

| Option                      | Description                                                                                                                                                                                                                                                                                                                                                     | Type          | Required | Default |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- | -------- | ------- |
| k3s_rpi_host_cmdline_params | Kernel parameters that must be in `cmdline.txt`, for example `cgroup_enable=memory`. A parameter that is already in the file, as the same exact token, is not added again. A missing one is appended to the end of the line, in list order. For most kernel parameters the last one wins. Removing a parameter from this list does not remove it from the file. | list of `str` | no       | `[]`    |
| k3s_rpi_host_config_lines   | Lines for `config.txt`, for example `kernel=kernel8.img`. They go into one managed block at the end of the file, under an `[all]` section filter, so they apply to every Pi model and override earlier settings of the same name. The block holds exactly this list. A line taken out of the list leaves the file; an empty list removes the block.             | list of `str` | no       | `[]`    |
| k3s_rpi_host_reboot         | Reboot the host when `cmdline.txt` or `config.txt` changed, then check that `/proc/cmdline` holds every parameter of `k3s_rpi_host_cmdline_params`. With `false` the role only edits the files. The change takes effect at the next boot, and the check is skipped.                                                                                             | bool          | no       | `True`  |

## Dependencies

None.

## Example Playbook

```yaml
- hosts: all
  tasks:
    - name: Importing role: k3s_rpi_host
      ansible.builtin.import_role:
        name: k3s_rpi_host
      vars:
```

## License

MIT

## Author and Project Information

Jonathan Gerdes

<!-- END_ANSIBLE_DOCS -->

## Usage

```yaml
- name: Prepare the boot of the Raspberry Pis that run k3s
  hosts: k3s_rpi_host
  become: true
  roles:
    - role: k3s_rpi_host
```

```yaml
# host_vars/argus.yml
k3s_rpi_host_cmdline_params:
  - cgroup_enable=memory
  - cgroup_memory=1
k3s_rpi_host_config_lines:
  - kernel=kernel8.img
```

The role appends every missing kernel parameter to the one line of
`/boot/firmware/cmdline.txt`, and writes the `config.txt` lines into a managed
block at the end of `/boot/firmware/config.txt`, under `[all]`. When one of the
files changed, it reboots the host and checks that `/proc/cmdline` holds every
parameter. A re-run with the same values changes nothing and does not reboot.

The role never removes a kernel parameter: it cannot tell one it added from one
the image shipped with. The `config.txt` block is its own, so a line taken out
of the list leaves the file, and an empty list removes the block.

Make a backup of the SD card before the first run on a host. A wrong
`config.txt` can stop the Pi from booting.

## Testing

The role is covered by four Molecule scenarios. One runs on the Ansible
controller, the other three in a Debian trixie container with the stock boot
files of a Raspberry Pi OS trixie Pi 5. The containers cannot reboot, so the
scenarios set `k3s_rpi_host_reboot: false`.

| Task                          | Covers                                                                  |
| ----------------------------- | ----------------------------------------------------------------------- |
| `mise run fast`               | `local` (the input contract), then the argus values on the stock files. |
| `mise run full`               | All four: also a re-run with longer lists, and removing the lines.      |
| `mise run scenario <name>...` | The named scenarios, for iterating.                                     |

## License

MIT
