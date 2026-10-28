# Restore test of the argo cluster on restore-test

This runbook tells you how to restore the backups of the `argo` cluster on a
second, separate cluster. The goal is to make sure that the backups are correct.
It is not a procedure for a real restore. A real restore replaces production and
is a different problem.

The test host is `heracles` (ThinkCentre, x86). During the test, it has the name
`restore-test` and is a single-node k3s cluster. See "Naming scheme" in the
project notes.

Written 2026-10-28. Not yet done one time.

## What the test restores

| Part                                           | From                          | Restore |
| ---------------------------------------------- | ----------------------------- | ------- |
| Kubernetes objects of the apps                 | Velero, schedule `daily`      | yes     |
| Volumes with `backup.velero.io/backup-volumes` | Velero file system backup     | yes     |
| Sealed Secrets key                             | Velero, `sealed-secrets-keys` | yes     |
| Databases authentik, immich, mealie, planka    | CNPG barman-cloud plugin      | yes     |
| immich library (static iSCSI PV)               | no backup, production LUN     | mounted |
| home-assistant, mqtt, zigbee2mqtt              | Velero                        | **no**  |
| copperforge                                    | no database backup            | **no**  |
| minecraft                                      | no volume backup (see below)  | **no**  |
| Rancher, cert-manager, Longhorn, Argo CD       | not in the backup scope       | **no**  |

Do not restore home-assistant, mqtt and zigbee2mqtt. zigbee2mqtt connects to the
Zigbee coordinator on `192.168.2.167:6638`. A second instance interferes with
production.

## Safety rules

The test cluster has access to the production buckets and to the production
iSCSI LUN of immich. These rules prevent writes to production:

1. **Read-only keys.** Velero and CNPG on `restore-test` use a new Garage key
   that can only read. The production keys are not used. In addition, the Velero
   backup storage location has `accessMode: ReadOnly`.
2. **No WAL archive.** The restore-test CNPG clusters have no `spec.plugins`.
   Thus they do not archive WAL and do not run the retention policy.
3. **No Argo CD on restore-test.** The Argo CD in the backup syncs from git
   `HEAD` and has auto-sync on the services. It can create objects that the test
   excludes on purpose. The test restores the objects from the backup.
4. **One kubeconfig per shell.** `~/.kube/config` points to production. In the
   shell for the test, set `KUBECONFIG=~/.kube/restore-test.yaml`. Then a
   command for production with `--context homelab` fails, because the context
   does not exist in that file. For production commands, use a second shell.
5. **immich runs only one time.** The iSCSI LUN of the library is
   `ReadWriteOnce`. Two hosts that mount the same ext4 filesystem damage it.
   Before restore-test mounts the LUN, production immich must have 0 replicas.

## Background: CNPG, Velero and Argo CD

Velero and CNPG back up different things:

- Velero backs up the Kubernetes objects of all namespaces, and the volumes with
  the annotation. The CNPG pods have no annotation. Thus Velero has the
  `Cluster` objects, but not the database data.
- The barman-cloud plugin writes base backups and WAL to the buckets
  `cnpg-<app>`. This is the database data.

Thus the test restores the database in a different way than the rest:

1. The Velero restore excludes all CNPG objects (`Cluster`, `Backup`,
   `ScheduledBackup`, `ObjectStore` and all objects with the label
   `cnpg.io/cluster`).
2. A new `Cluster` from `restore-test/cnpg/` recovers from the bucket with
   `bootstrap.recovery`.

**About Argo CD.** CNPG uses `spec.bootstrap` only one time: when it creates a
new cluster. A sync of a running cluster with a changed `bootstrap` section
changes nothing. Thus a sync cannot restore a backup over a running database by
accident. The design of the manifests for a real restore (recovery source,
`serverName` for each new generation, pinned `imageName`) is not part of this
test. It is in the backlog.

**Why `imageName` is pinned.** In production, the CNPG webhook wrote the default
image into `spec.imageName` when it created the clusters (Postgres 17.5, and
16.9 for immich). Git has no `imageName`. A new cluster from git now gets the
default image of the current operator, which can be a newer major version.
Recovery fails with a different major version. The files in `restore-test/cnpg/`
set the same image as production (checked 2026-10-28).

## Files

| File                                            | Content                                                   |
| ----------------------------------------------- | --------------------------------------------------------- |
| `ansible/restore-test.yml`                      | playbook: `common`, `lvm`, `k3s`, `longhorn_requirements` |
| `ansible/host_vars/restore-test/k3s.yml`        | single node, Cilium, local-path on                        |
| `ansible/host_vars/restore-test/lvm.yml`        | VG `data` on the partition `data`                         |
| `restore-test/velero-values.yaml`               | Velero Helm values, read-only                             |
| `restore-test/velero-change-storage-class.yaml` | `longhorn*` → `local-path`                                |
| `restore-test/cnpg/<app>.yaml`                  | read-only `ObjectStore` and recovery `Cluster`            |

`restore-test` is in the inventory group `restore_test` only. `site.yml` never
runs against it. `longhorn_requirements` is in the playbook for `open-iscsi`
only, which the immich iSCSI PV needs. Longhorn is not installed.

## Step 0: Take heracles out of olympus

**Not solved yet.** When `heracles` is a node of `olympus`, it must leave the
cluster before the reinstall (drain, delete the node, move its workloads). This
procedure is an open item in the backlog.

Now `heracles` is not a node of a cluster. Continue with step 1.

## Step 1: Prepare production

Do these steps in a shell **with the production kubeconfig**.

1. Make sure that the backups of last night are complete:

   ```bash
   velero --kubecontext homelab backup get | head -5
   kubectl --context homelab get backups.postgresql.cnpg.io -A \
     --sort-by=.metadata.creationTimestamp | tail -4
   ```

   The newest `daily-*` and `sealed-secrets-keys-*` must be `Completed`. The
   four newest CNPG backups must be `completed`.

2. Make sure that the images in `restore-test/cnpg/` are the same as in
   production. Recovery fails with a different Postgres major version (see "Why
   `imageName` is pinned").

   ```bash
   diff \
     <(kubectl --context homelab get clusters.postgresql.cnpg.io -A \
         -o jsonpath='{range .items[*]}{.metadata.namespace} {.spec.imageName}{"\n"}{end}' \
       | grep -v '^copperforge ' | sort) \
     <(for f in restore-test/cnpg/*.yaml; do
         echo "$(basename "$f" .yaml) $(grep -oP '^  imageName: \K.*' "$f")"
       done | sort)
   ```

   No difference is the expected result. If there is a difference, write the
   production value into the file. Exception: if production did a major upgrade
   after the backup that you restore, keep the old image of that backup.

3. Make a read-only Garage key on `odysseus`:

   ```bash
   ssh odysseus
   sudo garage key create restore-test-ro
   for b in velero-basebackup cnpg-authentik cnpg-immich cnpg-mealie cnpg-planka; do
     sudo garage bucket allow --read "$b" --key restore-test-ro
   done
   sudo garage key info restore-test-ro --show-secret
   ```

   Keep the key ID and the secret for step 4. Do not commit them.

4. Make sure that the key cannot write. With any S3 client, for example:

   ```bash
   AWS_ACCESS_KEY_ID=<id> AWS_SECRET_ACCESS_KEY=<secret> \
     aws --endpoint-url https://garage.cindergla.de \
     s3 cp /etc/hostname s3://velero-basebackup/restore-test-write-check
   ```

   The result must be `AccessDenied`. If the write is successful, stop. Delete
   the object and correct the key permissions.

Do the immich steps later, in step 6. Then production immich is off for the
shortest possible time.

## Step 2: Reinstall heracles as restore-test

Follow `docs/thinkcentre-ubuntu.md`, steps 1 and 2, with the host name
`restore-test`:

```bash
scripts/prepare-disk.sh /dev/sda restore-test
```

The seed is `cloud-init/restore-test/meta-data`. After the first boot,
`hostname` must show `restore-test`.

## Step 3: Ansible

```bash
cd ansible
rm -f /tmp/ansible_facts/restore-test
ansible-playbook restore-test.yml --syntax-check
ansible-playbook restore-test.yml --check
ansible-playbook restore-test.yml
# The second run must show changed=0.
ansible-playbook restore-test.yml
```

Then, in the shell for the test:

```bash
export KUBECONFIG=~/.kube/restore-test.yaml
kubectl get nodes          # only restore-test, Ready
kubectl get sc             # local-path
kubectl --context homelab get nodes   # must fail: context does not exist
```

Do all next steps in this shell.

## Step 4: Platform

1. cert-manager. The barman-cloud plugin needs it for its certificates.
   Production has v1.13.3 from Helm, which is too old for a new k3s. Use a
   current version:

   ```bash
   helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
     --version v1.19.1 -n cert-manager --create-namespace \
     --set crds.enabled=true --wait
   ```

2. Velero, read-only. First the secret with the read-only key:

   ```bash
   kubectl create namespace velero
   kubectl -n velero create secret generic velero-credentials-ro \
     --from-file=cloud=<(printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' '<id>' '<secret>')
   helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
   helm install velero vmware-tanzu/velero --version 12.2.1 -n velero \
     -f restore-test/velero-values.yaml --wait
   kubectl apply -f restore-test/velero-change-storage-class.yaml
   ```

   Velero reads the backups from the bucket. After approximately one minute:

   ```bash
   velero backup-location get     # garage, Available, ReadOnly
   velero backup get              # the same backups as in production
   ```

3. Sealed Secrets key, then the controller. The controller reads the keys at
   start, thus restore the key first:

   ```bash
   velero restore create restore-test-sealed-keys \
     --from-backup sealed-secrets-keys-<newest> --wait
   kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active
   kustomize build --enable-helm argo/infra/kube-system/sealed-secrets \
     | kubectl apply --server-side -f -
   ```

   Make sure that the controller has the production key:

   ```bash
   kubeseal --fetch-cert --controller-name sealed-secrets-controller \
     --controller-namespace kube-system | diff - misc/public-sealed-secret.pem
   ```

   No difference is the expected result.

4. CNPG operator and barman-cloud plugin, from git:

   ```bash
   kustomize build --enable-helm argo/infra/cnpg-system \
     | kubectl apply --server-side -f -
   kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg deploy/barman-cloud
   ```

## Step 5: Velero restore of the apps

Restore the apps without immich first. Use the newest `daily-*` backup.

```bash
velero restore create restore-test-apps \
  --from-backup daily-<newest> \
  --include-namespaces authentik,mealie,planka,audiobookshelf,yopass,whoami \
  --exclude-resources clusters.postgresql.cnpg.io,backups.postgresql.cnpg.io,scheduledbackups.postgresql.cnpg.io,poolers.postgresql.cnpg.io,objectstores.barmancloud.cnpg.io \
  --selector '!cnpg.io/cluster' \
  --wait
velero restore describe restore-test-apps --details
```

The include list is on purpose. With an exclude list, a new namespace in
production (for example of Rancher) is restored without a decision.

The apps with a database go into `CrashLoopBackOff` until step 7. This is
expected.

Check:

- `Phase: Completed`. Write down each warning and each error.
- Under "Pod Volume Restores", each volume of mealie, planka and audiobookshelf
  is `Completed`.
- `kubectl get pvc -A` shows `local-path` for each PVC.

## Step 6: immich

1. **Production shell.** Stop the auto-sync of the immich app, then stop the
   server. The ApplicationSet ignores changes to `syncPolicy`, thus it does not
   undo the change.

   ```bash
   kubectl --context homelab -n argocd patch application immich --type merge \
     -p '{"spec":{"syncPolicy":{"automated":null}}}'
   kubectl --context homelab -n immich scale deploy immich-server --replicas 0
   kubectl --context homelab -n immich get pods
   ```

   Only `immich-server` mounts the library. Wait until its pod is gone. Then
   make sure that no argo node has an iSCSI session to the LUN:

   ```bash
   for n in argo-1 argo-2 argo-3; do ssh $n sudo iscsiadm -m session; done
   ```

   The IQN `...:immich-library-data` must not be in the result.

2. **Test shell.** Restore immich:

   ```bash
   velero restore create restore-test-immich \
     --from-backup daily-<newest> \
     --include-namespaces immich \
     --exclude-resources clusters.postgresql.cnpg.io,backups.postgresql.cnpg.io,scheduledbackups.postgresql.cnpg.io,poolers.postgresql.cnpg.io,objectstores.barmancloud.cnpg.io \
     --selector '!cnpg.io/cluster' \
     --wait
   kubectl get pv immich-library-data-iscsi
   ```

   The PV has `Retain`, thus Velero restores it as it is, with the production
   target. If the NAS permits only known initiators, the pod stays in
   `ContainerCreating` with an iSCSI login error. Then add the initiator name of
   restore-test (`/etc/iscsi/initiatorname.iscsi`) on the NAS, and remove it
   after the test.

## Step 7: CNPG recovery

For each app (`authentik`, `immich`, `mealie`, `planka`):

```bash
app=authentik
kubectl -n $app create secret generic cnpg-garage-ro \
  --from-literal=ACCESS_KEY_ID='<id>' --from-literal=SECRET_ACCESS_KEY='<secret>'
kubectl apply -f restore-test/cnpg/$app.yaml
kubectl -n $app get pods -w     # <app>-db-1-full-recovery-*, then <app>-db-1
kubectl cnpg status $app-db -n $app
```

The recovery restores the newest base backup and then all WAL up to the end of
the archive. If the recovery pod fails, examine its log:

```bash
kubectl -n $app logs -l cnpg.io/cluster=$app-db --all-containers --prefix
```

When the database is ready, the app pods of step 5 start without a change.

## Step 8: Examine the result

Do not log in through Authentik OIDC. The redirect goes to the production URLs.
Use port-forward and a local account, or examine the data in the database.

1. **Databases.** Compare restore-test with production. Find the largest tables,
   then count their rows on both sides:

   ```bash
   kubectl cnpg psql $app-db -n $app -- -d $app -c '\dt+'
   kubectl cnpg psql $app-db -n $app -- -d $app -c 'select count(*) from <table>'
   ```

   Run the same count in production (`--context homelab`). The counts can be a
   little different, because production continued after the backup. Write down
   the time of the last restored transaction from `kubectl cnpg status`.

2. **Volumes.** Look at the files:

   ```bash
   kubectl -n mealie exec deploy/mealie -- ls -la /app/data
   kubectl -n audiobookshelf exec deploy/audiobookshelf -- du -sh /config /metadata /audiobooks /podcasts
   ```

   The sizes must agree with "Pod Volume Backups" in
   `velero backup describe daily-<newest> --details`.

3. **Apps.** For each app, for example:

   ```bash
   kubectl -n mealie port-forward svc/mealie 8080:80
   ```

   Open the app, and look for recipes, cards, photos and books that you know.

4. **immich.** The database is from the time of the backup, the library is from
   now. Make sure that photos from before the backup show.

## Step 9: Clean up

1. **Test shell.** Release the immich LUN first:

   ```bash
   kubectl -n immich scale deploy immich-server --replicas 0
   ssh restore-test sudo iscsiadm -m session    # no immich IQN
   ```

   Then shut down restore-test: `ssh restore-test sudo poweroff`.

2. **Production shell.** Start immich again and turn the auto-sync on again:

   ```bash
   kubectl --context homelab -n immich scale deploy immich-server --replicas 1
   kubectl --context homelab -n argocd patch application immich --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"enabled":true,"prune":true,"selfHeal":true}}}}'
   kubectl --context homelab -n argocd get application immich
   ```

   The app must be `Synced` and `Healthy`.

3. Delete the Garage key on `odysseus`:

   ```bash
   sudo garage key delete restore-test-ro --yes
   ```

   If you added the initiator of restore-test on the NAS, remove it.

4. Remove the files of the test from the workstation:

   ```bash
   rm -f ~/.kube/restore-test.yaml /tmp/ansible_facts/restore-test
   ssh-keygen -R restore-test; ssh-keygen -R restore-test.lan
   ```

5. Install the host again as `heracles`, see `docs/thinkcentre-ubuntu.md`.

## Known gaps (found 2026-10-28)

- **minecraft has no volume backup.** The deployment has 0 replicas. Velero file
  system backup only backs up volumes of running pods.
- **copperforge has no database backup.** Its CNPG cluster has no barman plugin.
- **immich library has no backup.** The test only mounts the production LUN.
- **The kopia repository on a read-only key is not tested.** Velero can need to
  write to the kopia repository for a restore. If the pod volume restores fail
  with an access error, write it down. Do not give the key write access. Failed
  repository maintenance jobs on restore-test are expected.

## Results

Write down the result of each test here, with the date.

| Date | Part | Result | Notes |
| ---- | ---- | ------ | ----- |
