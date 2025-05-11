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
