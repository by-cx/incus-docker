# Incus container

Run the Incus daemon and web UI in a privileged Podman or Docker container.
The image is based on Debian 13 (Trixie) and the packages maintained by
[Zabbly](https://github.com/zabbly/incus).

This is a maintained fork of
[cmspam/incus-docker](https://github.com/cmspam/incus-docker). It removes the
Alpine variants and keeps one Debian image definition for all release channels.

## Images

Images are published for `linux/amd64` and `linux/arm64`:

| Image | Zabbly channel | Purpose |
| --- | --- | --- |
| `ghcr.io/by-cx/incus-docker:latest` | `stable` | Current Incus feature release |
| `ghcr.io/by-cx/incus-docker:daily` | `daily` | Untested daily Incus build |
| `ghcr.io/by-cx/incus-docker:lts` | `lts-7.0` | Incus 7.0 LTS |

All three images are built from `debian-version/Dockerfile` on the `main`
branch. The Zabbly `incus` package includes QEMU, the Incus agent, and the
firmware under `/opt/incus/share/qemu`; host OVMF mounts are not required.

## Security model

Incus is a system container and virtual-machine manager. Running it inside
another container still requires broad access to the host:

- The outer container is privileged.
- It shares the host network, PID namespace, and cgroup namespace.
- It can load host kernel modules through a read-only `/lib/modules` mount.
- Anyone with Incus administrator access can effectively gain root access to
  the host.

Use this only on a host where the Incus administrators are trusted as host
administrators. Native Incus packages are preferable when the host operating
system provides them.

## Install with Podman

Requirements:

- Linux with cgroup v2
- systemd
- rootful Podman with Quadlet support
- `sudo`

Clone the repository and run:

```sh
sudo ./install.sh
```

When invoked through `sudo`, the script installs the client wrapper into
`~/.local/bin/incus` for the user who invoked `sudo`. To select another user:

```sh
sudo ./install.sh --user USER
```

An unmarked, non-empty `/var/lib/incus` is not adopted automatically because
it might belong to a native Incus installation. If it is intentionally the
state of an older container deployment, use `sudo ./install.sh --adopt-bind`.

The installer:

- validates Podman and the Quadlet files;
- pulls `ghcr.io/by-cx/incus-docker:latest`;
- installs the Quadlet under `/etc/containers/systemd`;
- reloads systemd and starts or replaces `incus.service`;
- waits for the daemon health check;
- installs or updates the client wrapper.

It is idempotent. To update the repository configuration and running image:

```sh
git pull --ff-only
sudo ./install.sh
```

The script intentionally does not update its own Git checkout.

### Persistent storage

Clean installations use the Podman volume `incus-data` for `/var/lib/incus`.
If the installer finds a non-empty host `/var/lib/incus`, it keeps that bind
mount when an existing Quadlet or `--adopt-bind` confirms ownership. It refuses
ambiguous cases where both the host directory and named volume might contain
state. The decision is recorded in
`/etc/containers/systemd/incus-storage-mode` and reused on later runs.

Back up Incus before image upgrades. Incus can migrate its database schema
forward, and an older daemon might not be able to use the upgraded database.

### Environment

The installer creates `/etc/incus-container.env` if it does not exist and never
overwrites an existing file. Supported compatibility options include:

```ini
# Needed only for Docker hosts whose DOCKER-USER rules block Incus bridges.
SETIPTABLES=true

# Optional host kvm group ID if device ownership needs to be matched.
KVM_GID=36
```

`SETIPTABLES=true` inserts an unrestricted `ACCEPT` rule into the host's
`DOCKER-USER` chain. It is normally unnecessary with Podman.

## Client access

The installed `~/.local/bin/incus` wrapper runs the matching client inside the
daemon container:

```sh
incus admin init
incus list
incus launch images:debian/13 c1
```

Because the deployment uses rootful Podman, the wrapper invokes Podman through
`sudo`. It preserves interactive terminals and also works in pipelines.

Paths passed to commands such as `incus file push` are interpreted inside the
outer container, not on the host. For native host path handling, download the
official static Linux client from the
[Incus releases](https://github.com/lxc/incus/releases/latest) and connect to
the daemon over HTTPS. Copying `/usr/bin/incus` out of this image is not
sufficient: the Zabbly wrapper expects `/opt/incus/bin` and `/opt/incus/lib`.

## Service management

```sh
sudo systemctl status incus.service
sudo systemctl restart incus.service
sudo journalctl -u incus.service
sudo podman inspect incus
```

The Podman log driver is disabled intentionally. Incus writes daemon and
instance logs under `/var/log/incus` and its persistent state directory.
Disabling the outer log pipe lets the daemon container be replaced while
long-lived instance monitor processes continue running.

The image health check uses `incus admin waitready`. An unhealthy daemon is
terminated by Podman and restarted by systemd.

## Manual Quadlet installation

The portable source files are in `quadlet/`:

- `incus.container`
- `incus-data.volume`
- `incus-environment.conf`
- `incus-bind-storage.conf`

The installer is recommended because it handles storage selection, environment
configuration, image updates, validation, and the host wrapper consistently.

## Host resources

The default Quadlet does not mount `/dev`, a home directory, host firmware, or
a fixed host state directory on clean installations. Privileged Podman exposes
the required devices. `/lib/modules` remains host-mounted because modules must
match the running host kernel.

Additional host paths are deployment-specific. For example, a host directory
used as the source of an Incus disk device must also be visible at the same
path inside the outer container. Add such mounts through a Quadlet drop-in
rather than modifying the installed file.

OpenVSwitch users can similarly add `/run/openvswitch:/run/openvswitch` through
a drop-in. Hosts using AppArmor may need to expose `/sys/kernel/security` and
adjust their host profiles.

## Docker

Podman Quadlet is the maintained deployment path. The image can still run with
Docker using equivalent privileged, host-network, host-PID, host-cgroup, state,
and `/lib/modules` options. Set `SETIPTABLES=true` only when Docker's forwarding
rules block traffic from Incus bridges.

## License

Licensed under the Apache License 2.0. See `LICENSE`.
