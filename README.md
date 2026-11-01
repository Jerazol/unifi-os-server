# UniFi OS Server on Kubernetes

Run [UniFi OS Server](https://help.ui.com/hc/en-us/articles/34210126298775) (the replacement for the
end-of-life standalone UniFi Network Server) on Kubernetes, using **only Ubiquiti's own code**:

- **No third-party image or Helm chart.** The container image is extracted from Ubiquiti's official Linux
  installer and pushed to your own registry.
- **Plain Kustomize manifests** (`kustomize/`) that reproduce what Ubiquiti's own launcher passes to `podman run`.

Ubiquiti does not officially support running UniFi OS Server on Kubernetes. It works, but you are on your own
when it comes to support.

## Credits

- [chrissnell/unifi-os-kubernetes](https://github.com/chrissnell/unifi-os-kubernetes) is a Helm chart with its own
  community-built image. It showed that UniFi OS Server can run on Kubernetes, and its manifests were the starting
  point for these. This repository takes a different approach: it uses Ubiquiti's unmodified image, extracted
  from the official installer, together with plain Kustomize.
- The script, manifests and this README were created with [Claude Code](https://claude.com/claude-code).

## How it works

The installer you download from ui.com is an ELF executable with a zip archive appended to it. The zip contains:

| File                               | What it is                                                              |
|------------------------------------|-------------------------------------------------------------------------|
| `image.tar`                        | UniFi OS Server itself, as an OCI image archive (Debian, systemd, UniFi Core, Network, MongoDB, ...) |
| `uosserver`, `uosserver-service`, `updater-service`, `discovery`, `purge`, `pasta` | Ubiquiti's tools to install and run the image with podman (not used here) |
| `portmap.json`                     | Ports the server listens on                                             |
| `mounts.json`                      | Paths that must be persistent                                           |

`extract-image.sh` unpacks the zip without running the installer, checks every image layer against its
sha256 digest, and optionally pushes the image to a registry.

The container runs systemd as PID 1 and therefore has to be **privileged**, the same as Ubiquiti's launcher runs it.

## Requirements

- An x86_64 Kubernetes cluster with cgroup v2, where the namespace may run privileged pods
- A `LoadBalancer` implementation (MetalLB, Cilium LB IPAM, kube-vip, ...) for a fixed IP that the devices can reach
- Persistent storage for two `ReadWriteOnce` volumes: 20 GiB of data and 10 GiB for MongoDB. Use block or local
  storage, not NFS.
- About 2 GiB of RAM, up to 6 GiB under load
- A private container registry the cluster can pull from. Don't publish Ubiquiti's image in a public registry.
- On your workstation: `7z` or `unzip`, `tar`, `sha256sum`, `skopeo` and `kubectl`

## Setup

### 1. Download the installer

From [ui.com/download](https://ui.com/download/software/unifi-os-server), download **UniFi OS Server** for
**Linux x64**. The file name looks like `1234-linux-x64-5.1.42-<id>.42-x64`.

### 2. Extract the image and push it to your registry

```bash
./extract-image.sh -p registry.example.com/uosserver ~/Downloads/1234-linux-x64-5.1.42-<id>.42-x64
```

This extracts into `./uos-<version>/` and pushes `registry.example.com/uosserver:<version>`. Without `-p`, the
script only extracts and verifies, and prints the `skopeo` command to push it yourself.
The version and the image digest are also written to `uos-<version>/image-info.env`.

If the registry needs authentication, run `skopeo login registry.example.com` first. If the cluster needs a
pull secret, add `imagePullSecrets` to `kustomize/deployment.yaml`.

### 3. Configure the manifests

Edit `kustomize/`:

1. **`kustomization.yaml`:** set `images` to your registry, tag and the digest the script printed.
2. **`config.env`:**
   - Set `APP_VERSION` to the same version.
   - Set `UOS_UUID` to a **version 5** UUID, generated for example with
     `uuidgen --sha1 --namespace @dns --name unifi.example.com`.
     A random (version 4) UUID makes the Network application fail to start.
3. **`service.yaml`:** pin the LoadBalancer IP with your implementation's annotation (see the comment in the file).
   The devices are told to use this IP, so it must not change.
4. **`pvc.yaml`:** set `storageClassName` if you don't want the default StorageClass.

You can also leave `kustomize/` untouched and put these changes in your own overlay that uses it as a base.

### 4. Deploy

```bash
kubectl apply -k kustomize/
kubectl -n unifi rollout status deploy/unifi --timeout=15m
```

Check that everything inside the container is up. `systemctl is-system-running` should print `running`,
and `systemctl --failed` should list nothing:

```bash
kubectl -n unifi exec deploy/unifi -c unifi -- systemctl is-system-running
kubectl -n unifi exec deploy/unifi -c unifi -- systemctl --failed
```

The Network application takes a few minutes after the first start. Then open `https://<loadbalancer-ip>/`.
It uses a self-signed certificate.

Optionally, add a DNS record for the IP, for example `unifi.example.com`.

### 5. Back up the old controller

In the old UniFi Network controller, download a backup:

- **Where:** Settings → System → Backups (called Maintenance or Backup in older versions) → **Download Backup**.
- **What to include:** choose how much history to include. "Settings only" is enough to keep sites, devices,
  WLANs and networks.

The backup file has the extension `.unf`.

The new server must run the **same or a newer** Network application version than the one that made the backup.

While you're in the old controller, write down the **device SSH credentials**. They are under Settings → System →
Advanced → **Device Authentication** (in older versions Settings → Site → Device Authentication). You need them
in step 8.

### 6. Restore the backup on UniFi OS Server

There are two ways to restore the `.unf` file:

- **During setup:** the setup wizard on the new server offers to restore from a backup.
- **After setup:** in the Network application, go to Settings → Control Plane → Backups → **Upload & Restore** and upload the file.

The restore brings across the sites, settings and the list of adopted devices, including the keys that the
devices use to authenticate to the controller. That's why the devices don't need to be reset.

After the restore, the devices are listed but show as offline or unadopted, because they still report to the
old controller.

### 7. Set the inform host on the new server

In the new Network application, go to Settings → System → Advanced and enable **Inform Host override**. Set it to
the LoadBalancer IP, or to the DNS name if you created one.

This step matters. Without it, the server tells the devices to use the pod's internal cluster IP, and they lose
contact after their next provision or reboot.

### 8. Move the devices from the old to the new server

Move the devices one at a time over SSH, using the device credentials from step 5:

```bash
ssh <device-ssh-user>@<ap-ip>
set-inform http://<loadbalancer-ip>:8080/inform
```

- Within a minute or two the device shows up in the new server. If it shows as **Pending Adoption**, click
  **Adopt**.
- If it stays at "Adopting", run the same `set-inform` command a second time. Some firmware needs it.
- Start with an AP you are **not** connected through, and check that its clients reconnect before you move the rest.

Moving devices individually over SSH lets you check each one, and you can move one back with `set-inform` to the
old server's address.

The alternative is to set Inform Host override in the **old** controller to the new address. That moves every
device at once, with no SSH needed.

### 9. Verify and retire the old controller

- Reboot one device from the new server and check that it comes back online. This confirms step 7.
- Once all devices are stable on the new server, stop the old controller.

## Upgrading

UniFi OS Server can't update itself inside Kubernetes, because the built-in updater expects Ubiquiti's podman
setup. To upgrade:

1. Download the new installer.
2. Run `extract-image.sh -p ...` again.
3. Update `images` in `kustomization.yaml` and `APP_VERSION` in `config.env`.
4. Apply the manifests again.

Before an upgrade, download a backup from the Network application.

`UOS_UUID` is only read on the first start. It is stored in `/data/uos_uuid` on the data volume, so leave it as it is.

## Ports

| Port      | Protocol | Use                                     |
|-----------|----------|-----------------------------------------|
| 443       | TCP      | Web UI and API                          |
| 8080      | TCP      | Device inform (adoption and management) |
| 3478      | UDP      | STUN                                    |
| 10003     | UDP      | Device discovery                        |
| 5514      | UDP      | Remote syslog from devices              |
| 6789      | TCP      | Mobile speed test                       |

Device discovery (10003/udp) uses layer 2 broadcasts, which generally don't reach a pod through a LoadBalancer.
That's why new or moved devices are pointed at the server with `set-inform`.

The installer's `portmap.json` also lists 8444 and 8880–8882 (hotspot portal), 5671 (AMQPS) and 9543
(Identity Hub). To use those features, add the ports to both `deployment.yaml` and `service.yaml`.

## Troubleshooting

Logs are inside the container, and services are managed by systemd:

```bash
kubectl -n unifi exec -it deploy/unifi -c unifi -- bash
systemctl --failed
journalctl -u unifi-core -u unifi -u mongodb
tail -f /data/unifi/logs/server.log    # Network application
```

- **MongoDB fails with "Attempted to create a lock file on a read-only directory".** The volumes weren't
  prepared. The `seed-volumes` init container copies the image's original files and ownership into empty
  volumes, which podman does by itself. Check its log with
  `kubectl -n unifi logs deploy/unifi -c seed-volumes`.
- **The Network application keeps restarting with "Invalid uuid version - 4".** `UOS_UUID` was a random UUID.
  Changing `config.env` doesn't help at this point, because the value was saved on the first start. Write a
  version 5 UUID to `/data/uos_uuid` in the container, then run
  `systemctl restart unifi-core && systemctl restart unifi`.
  Also change `config.env` to match.
- **`http://<ip>:8080/inform` returns 400 in a browser.** That's normal. It only accepts requests from devices.
- **Devices adopt and then disconnect.** Check the Inform Host override from step 7.
