# homelab

## ansible

Every host is listed in my ~/.ssh/config, and my SSH public key has already been installed on each one.  
The public key has to be copied over manually for now, because doing this initially with ansible (different users, different passwords) is more work than just running ssh-copy-id.

The users listed there have passwordless sudo. This is automated via ansible.

This (and the ansible.cfg) makes it possible to run ansible with just
```
ansible-playbook site.yml
```

### initial setup

If the ssh user of the targeted servers is different from your local users these need to be set up (either via group_vars or host_vars).
The .vaultpw needs to be created.

### remote access (off-site, no port-forwarding)

Zagreus joins the existing `naglfar`&harr;`odysseus` WireGuard tunnel as a third
peer.

Steps not covered by ansible, to be run on zagreus:
1. `wg genkey | tee laptop-private.key | wg pubkey > laptop-public.key`.
2. `ansible-vault edit ansible/group_vars/vps/vault`, set `vault_wireguard_laptop_public_key`.
3. `ansible-playbook site.yml --tags wireguard --limit vps`.
4. Bring up `wg-quick` on the laptop: `Address = 10.0.0.3/32`, peer = `naglfar`, `AllowedIPs = 10.0.0.1/32,10.0.0.2/32`.
5. Uncomment `Include config.d/homelab-remote` in `~/.ssh/config`
6. Run ansible as usual: `ansible-playbook site.yml`.
