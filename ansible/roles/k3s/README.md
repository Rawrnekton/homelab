<!-- BEGIN_ANSIBLE_DOCS -->
# Ansible Role: k3s
provision a bare k3s cluster

Tags: k3s, kubernetes, cluster, homelab

## Requirements

| Platform | Versions |
| -------- | -------- |
| Ubuntu | 24.04 |

## Role Arguments


### Entrypoint: main

Provision a bare k3s cluster node.

Installs and configures a single k3s node — either a control-plane (server) or a worker (agent) — selected by `k3s_node_role`.

|Option|Description|Type|Required|Default|
|---|---|---|---|---|
| k3s_state | The desired state of k3s on this node. `present` installs k3s. `absent` removes k3s. | str | no | present |
| k3s_node_role | Role this node plays in the cluster. `control` installs a k3s server (control-plane). `worker` installs a k3s agent that joins an existing cluster. | str | no | control |
| k3s_release_channel | K3s release channel to track (e.g. "stable", "latest"). Mutually exclusive with k3s_version. | str | no |  |
| k3s_version | K3s version to install or to upgrade to (e.g. "v1.36.2+k3s1"). Mutually exclusive with k3s_release_channel. | str | no |  |
| k3s_upgrade | Re-run the installation script if set to true. This is mainly used to either reinstall the server or upgrade. | bool | no | False |
| k3s_snapshotter | The containerd snapshotter that k3s uses for container images. When unset, k3s keeps its own default (`overlayfs`). Set `native` when the node itself runs in a container, because overlayfs does not work when it is nested. | str | no |  |
| k3s_cni | The CNI the cluster should be using. `flannel` is the built in CNI. `cilium` switches flannel and the built-in network policy off and installs Cilium from a HelmChart CR in the manifests directory of the bootstrap node, before any other node joins. | str | no | flannel |
| k3s_cilium_version | The Chart version of cilium to install. Only valid when `k3s_cni` is set to `cilium`. Cilium is installed ONCE, when the cluster is bootstrapped. After the chart is up the role writes a `.skip` marker next to the manifest and stops managing it, so that a GitOps tool can take the chart over. A later change of this value therefore does not upgrade a running cluster. | str | no |  |
| k3s_cilium_values | A dictionary of Helm values for the HelmChart CR. Only valid when `k3s_cni` is set to `cilium`. Read once, at bootstrap; see `k3s_cilium_version`. | dict | no |  |
| k3s_kube_proxy_replacement | Whether Cilium fully replaces kube-proxy. Sets the related Cilium Helm value and adds `disable-kube-proxy` to the k3s config. Only valid when k3s_cni is set to cilium. | bool | no |  |
| k3s_tls_san | Additional hostnames or IPv4/IPv6 addresses as Subject Alternative Names on the TLS cert. | list of 'str' | no |  |
| k3s_node_labels | List of labels to apply to this node in `key=value` format. | list of 'str' | no |  |
| k3s_node_taints | List of taints to apply to this node in `key=value:Effect` format. Valid effects are `NoSchedule`, `PreferNoSchedule`, and `NoExecute`. | list of 'str' | no |  |
| k3s_kubelet_args | Extra arguments passed through to the kubelet. Written WITHOUT the leading dashes, in `key` or `key=value` format (e.g. `max-pods=110`). | list of 'str' | no |  |
| k3s_extra_server_args | Extra arguments passed through to `k3s server`. Written WITH the leading dashes, in `--flag` or `--flag=value` format (e.g. `--etcd-expose-metrics=true`). An argument that names a key the role already writes to `config.yaml` is merged into that key. Only valid when `k3s_node_role` is `control`. | list of 'str' | no |  |
| k3s_extra_agent_args | Extra arguments passed through to `k3s agent`. Written WITH the leading dashes, in `--flag` or `--flag=value` format (e.g. `--node-ip=10.10.0.5`). An argument that names a key the role already writes to `config.yaml` is merged into that key. | list of 'str' | no |  |
| k3s_kubeconfig_fetch | Whether to fetch the kubeconfig from the control-plane node to the Ansible controller. | bool | no | False |
| k3s_kubeconfig_dest | Local path on the Ansible controller where the kubeconfig is written. Required when `k3s_kubeconfig_fetch` is `true`. | path | no |  |
| k3s_sysctl_settings | Dictionary of sysctl key/value pairs to apply on the node (e.g. `fs.inotify.max_user_instances: 512`). | dict | no |  |
| k3s_local_path_provisioner_enabled | Whether to enable the k3s built-in local-path provisioner. | bool | no | False |
| k3s_spegel_enabled | Whether to enable Spegel, the k3s embedded OCI registry mirror. Switches `embedded-registry` on in the server configuration and writes a `registries.yaml` that mirrors every registry through it on every node. | bool | no | False |

#### Choices for main > k3s_state

|Choice|
|---|
| present |
| absent |

#### Choices for main > k3s_node_role

|Choice|
|---|
| control |
| worker |

#### Choices for main > k3s_snapshotter

|Choice|
|---|
| overlayfs |
| native |
| fuse-overlayfs |
| stargz |

#### Choices for main > k3s_cni

|Choice|
|---|
| flannel |
| cilium |



## Dependencies
None.

## Example Playbook

```
- hosts: all
  tasks:
    - name: Importing role: k3s
      ansible.builtin.import_role:
        name: k3s
      vars:
```

## License

MIT

## Author and Project Information
Jonathan Gerdes

<!-- END_ANSIBLE_DOCS -->

## Usage

```yaml
- name: Provision the k3s cluster
  hosts: k3s_cluster
  become: true
  roles:
    - role: k3s
```

The role bootstraps the whole cluster in one run. It takes the first host in
the play with `k3s_node_role: control` as the bootstrap node, starts the
cluster there, and joins every other host to it. Re-running the role joins
hosts that were added to the inventory since the last run, and leaves the
hosts that already run k3s alone.

Upgrades never happen by surprise: a newer `k3s_release_channel` or
`k3s_version` only takes effect when `k3s_upgrade` is `true`, and the role
cordons and drains a node before it moves it.

Set `k3s_state: absent` to take k3s off a node again.

## Testing

The role is covered by ten Molecule scenarios. One of them runs on the Ansible
controller, the other nine in Docker.

| Task | Covers |
| --- | --- |
| `mise run fast` | `local`, then a single control-plane node on the role defaults. |
| `mise run full` | All ten scenarios: every topology and every variable. |
| `mise run scenario <name>...` | The named scenarios, for iterating. |

`CLAUDE.md` holds the full scenario table and the reasons behind it.

## License

MIT
