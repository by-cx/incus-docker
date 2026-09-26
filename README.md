# Incus container

Run the Incus daemon and web UI in a privileged container managed by rootful
Podman, Quadlet, and systemd. The image is based on Debian 13 (Trixie) and the
[Zabbly Incus packages](https://github.com/zabbly/incus).

The maintained installation path is `install.sh`. It creates a system service,
keeps Incus state outside the image, installs a matching client wrapper, and
provides enough time for Incus to shut down its instances during service or
host shutdown.

## Images

Images are published for `linux/amd64` and `linux/arm64`:

| Image | Zabbly channel | Purpose |
| --- | --- | --- |
| `ghcr.io/by-cx/incus-docker:latest` | `stable` | Current stable Incus feature release |
| `ghcr.io/by-cx/incus-docker:daily` | `daily` | Development builds; not recommended for production |
| `ghcr.io/by-cx/incus-docker:lts` | `lts-7.0` | Incus 7.0 LTS |

The installer uses `:latest`. All channels are built from
`debian-version/Dockerfile` on the `main` branch. Builds run after changes to
`main`, once per day, and when manually dispatched.

The Zabbly package supplies Incus, QEMU, the Incus agent, the web UI, and VM
firmware. A host OVMF mount is not required.

## Security model

Incus manages system containers, virtual machines, storage, and networking.
Running it inside another container still requires extensive host access:

- The outer container is privileged.
- It shares the host network, PID namespace, and cgroup namespace.
- It can use host devices exposed by privileged Podman.
- It mounts `/lib/modules` read-only so loaded modules match the host kernel.
- An Incus administrator can effectively gain root access to the host.

Only grant Incus access to users who are trusted as host administrators. A
native Incus package is preferable when the host operating system supports it.

## Requirements

- Linux with cgroup v2
- systemd
- Rootful Podman with Quadlet support
- `sudo` when installing for or operating as a non-root user

## Install

Clone the repository and run:

```sh
sudo ./install.sh
```

When run through `sudo`, the installer places the client wrapper in the
invoking user's `~/.local/bin/incus`. Select a different user with:

```sh
sudo ./install.sh --user USER
```

Ensure `~/.local/bin` is in that user's `PATH`, then initialize Incus if this
is a new deployment:

```sh
incus admin init
```

### What the installer does

The script is safe to run repeatedly. On each run it:

1. Elevates itself with `sudo` when necessary and identifies the user who
   should receive the client wrapper.
2. Checks required commands, cgroup v2, and the Podman Quadlet generator.
3. Refuses to replace an existing `incus.service` that it does not manage,
   protecting a possible native Incus installation.
4. Selects persistent storage and refuses ambiguous state locations.
5. Validates the assembled Quadlet configuration before changing the installed
   service.
6. Pulls `ghcr.io/by-cx/incus-docker:latest`.
7. Installs the Quadlet files under `/etc/containers/systemd` and creates
   `/etc/incus-container.env` if it does not exist.
8. Installs or updates `~/.local/bin/incus` for the selected user.
9. Reloads systemd, restarts `incus.service`, and checks that Incus becomes
   ready.

The installer does not update its own Git checkout and does not overwrite an
existing `/etc/incus-container.env`.

### Persistent storage

A clean installation creates the Podman volume `incus-data` and mounts it at
`/var/lib/incus`. Image replacement therefore does not remove Incus databases,
storage pools, instance data, or configuration.

Older deployments might already use the host directory `/var/lib/incus`. The
installer continues using that bind mount when a previous installation has
recorded it. To adopt an existing directory intentionally on the first run:

```sh
sudo ./install.sh --adopt-bind
```

The installer will not automatically adopt an unmarked, non-empty
`/var/lib/incus`, because it might belong to a native installation. It also
stops if both that directory and the `incus-data` volume could contain state.
The selected mode is recorded in
`/etc/containers/systemd/incus-storage-mode` and reused on future runs.

Back up Incus before upgrades. Incus can migrate its database schema forward,
and an older image might not be able to read the upgraded database.

### Environment options

Optional settings belong in `/etc/incus-container.env`:

```ini
# Needed only on Docker hosts whose DOCKER-USER rules block Incus bridges.
SETIPTABLES=true

# Match a host kvm group ID when device ownership requires it.
KVM_GID=36
```

`SETIPTABLES=true` inserts unrestricted `ACCEPT` rules into existing
`DOCKER-USER` chains. It is normally unnecessary with Podman.

After changing the environment file, restart the service:

```sh
sudo systemctl restart incus.service
```

## Updating

Update the checkout, pull the current image, reinstall any changed Quadlet
files, and restart the service with:

```sh
git pull --ff-only
sudo ./install.sh
```

The installer always pulls the current `:latest` image before restarting the
service. The Quadlet uses `Pull=never` so service starts use that explicitly
pulled local image rather than performing an uncontrolled pull during boot.

An update has these effects:

1. The existing service receives `SIGTERM`.
2. Incus gracefully shuts down its running instances.
3. Podman replaces the outer container with the newly pulled image.
4. Incus starts against the same persistent state.
5. Instances start according to `boot.autostart`; its default `last-state`
   behavior restores instances that were running.
6. The installer waits for `incus admin waitready` before reporting success.

Updating therefore causes an outage for running instances; it is not a live
daemon replacement. Schedule production updates accordingly. Running only
`systemctl restart incus.service` does not pull a new image.

## Shutdown behavior

A normal host shutdown or reboot stops `incus.service` through systemd. The
shutdown sequence is:

1. Podman sends `SIGTERM` to the image entrypoint.
2. The entrypoint runs `incus admin shutdown`.
3. Incus applies each instance's `boot.host_shutdown_action`, which defaults to
   `stop`.
4. Incus requests a graceful shutdown and waits for
   `boot.host_shutdown_timeout`, which defaults to 30 seconds per instance,
   before force-stopping an instance that has not exited.
5. After the instances stop, the entrypoint terminates `incusd` and `lxcfs` and
   unmounts the LXCFS filesystem.
6. Podman stops the outer container and systemd continues shutting down the
   host.

The entrypoint allows `incus admin shutdown` up to 300 seconds. Podman allows
330 seconds and systemd allows 360 seconds, so the inner shutdown has time to
finish before either outer layer forces termination.

Increase the timeout for a VM that needs longer to shut down cleanly:

```sh
incus config set VM_NAME boot.host_shutdown_timeout 120
```

Use `boot.stop.priority` to control instance shutdown order. The same shutdown
path runs for `systemctl stop`, `systemctl restart`, installer updates, and
normal host reboots. It cannot protect instances from power loss, a forced host
reset, or a guest that fails to stop before all configured timeouts expire.

## Client access

The installed wrapper runs the image's matching Incus client inside the outer
container:

```sh
incus list
incus launch images:debian/13 c1
incus info c1
```

Because Podman is rootful, the wrapper uses `sudo podman exec` for non-root
users. It preserves interactive terminals and supports pipelines.

Host paths passed to commands such as `incus file push` are not visible unless
they are also mounted inside the outer container. If native host path access is
needed, use the official static client from the
[Incus releases](https://github.com/lxc/incus/releases/latest) and connect over
HTTPS. Copying `/usr/bin/incus` from this image is insufficient because the
Zabbly wrapper depends on files under `/opt/incus`.

## Service management

```sh
sudo systemctl status incus.service
sudo systemctl restart incus.service
sudo journalctl -u incus.service
sudo podman inspect incus
```

The health check runs `incus admin waitready`. A persistently unhealthy outer
container is killed by Podman and restarted by systemd. The Podman log driver
is disabled; use the systemd journal and Incus logs for diagnostics.

## Custom host mounts

The default service does not mount `/dev`, a home directory, host firmware, or
a fixed host state directory on clean installations. Privileged Podman exposes
the required devices, and `/lib/modules` is mounted read-only because modules
must match the running host kernel.

Host paths used as sources for Incus disk devices must also exist at the same
path inside the outer container. Add deployment-specific mounts with a Quadlet
drop-in under `/etc/containers/systemd/incus.container.d/` rather than editing
the installed base file. OpenVSwitch users can add
`/run/openvswitch:/run/openvswitch` in the same way. Hosts using AppArmor might
also need `/sys/kernel/security` and host profile changes.

After adding a drop-in:

```sh
sudo systemctl daemon-reload
sudo systemctl restart incus.service
```

## Repository layout

- `debian-version/`: image definition, entrypoint, and health check
- `quadlet/`: portable Quadlet source files
- `bin/incus`: host client wrapper installed by `install.sh`
- `install.sh`: idempotent install and update script

The installer is preferred over manual Quadlet installation because it handles
storage selection, state protection, image pulls, validation, service updates,
and the client wrapper together.

## License

Licensed under the Apache License 2.0. See `LICENSE`.
