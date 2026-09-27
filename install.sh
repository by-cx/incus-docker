#!/bin/sh
set -eu

PROGRAM_NAME=${0##*/}
IMAGE=ghcr.io/by-cx/incus-docker:latest
QUADLET_DIR=/etc/containers/systemd
ENVIRONMENT_FILE=/etc/incus-container.env
STORAGE_MARKER=${QUADLET_DIR}/incus-storage-mode
MIGRATION_MARKER=${QUADLET_DIR}/incus-volume-migration
STATE_DIR=/var/lib/incus
LEGACY_VOLUME=incus-data
HOST_ACCESS_DROPIN=${QUADLET_DIR}/incus.container.d/30-host-access.conf

usage() {
    cat <<EOF
Usage: ${PROGRAM_NAME} [--user USER] [--adopt-bind]

Install or update the Incus Quadlet and the invoking user's fallback client wrapper.
Run this script again after updating the checkout to update the deployment.
EOF
}

target_user=
adopt_bind=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --user)
            [ "$#" -ge 2 ] || { echo "--user requires a value" >&2; exit 2; }
            target_user=$2
            shift 2
            ;;
        --adopt-bind)
            adopt_bind=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    if [ -n "${target_user}" ]; then
        if [ "${adopt_bind}" = true ]; then
            exec sudo "$0" --user "${target_user}" --adopt-bind
        fi
        exec sudo "$0" --user "${target_user}"
    fi

    if [ "${adopt_bind}" = true ]; then
        exec sudo "$0" --adopt-bind
    fi
    exec sudo "$0"
fi

if [ -z "${target_user}" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != root ]; then
        target_user=${SUDO_USER}
    else
        target_user=$(id -un)
    fi
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

for command in chmod chown cp cut find getent grep groupadd install mktemp mv podman rm rmdir sha256sum stat systemctl tr usermod; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required command not found: ${command}" >&2
        exit 1
    fi
done

if ! getent passwd "${target_user}" >/dev/null; then
    echo "User does not exist: ${target_user}" >&2
    exit 1
fi

target_home=$(getent passwd "${target_user}" | cut -d: -f6)
target_group=$(id -gn "${target_user}")

if [ "${target_user}" != root ] && ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required by the client wrapper for rootful Podman." >&2
    exit 1
fi

if [ "$(podman info --format '{{.Host.CgroupsVersion}}')" != v2 ]; then
    echo "Incus Quadlet requires cgroup v2." >&2
    exit 1
fi

if [ ! -f "${STORAGE_MARKER}" ] && [ ! -f "${QUADLET_DIR}/incus.container" ] && \
    systemctl cat incus.service >/dev/null 2>&1; then
    echo "An Incus system service already exists and is not managed by this installer." >&2
    echo "Refusing to replace a possible native Incus installation." >&2
    exit 1
fi

quadlet_generator=
for candidate in \
    /usr/lib/systemd/system-generators/podman-system-generator \
    /usr/libexec/podman/quadlet; do
    if [ -x "${candidate}" ]; then
        quadlet_generator=${candidate}
        break
    fi
done

if [ -z "${quadlet_generator}" ]; then
    echo "Podman's Quadlet generator was not found." >&2
    exit 1
fi

legacy_volume=false
if [ -f "${STORAGE_MARKER}" ]; then
    storage_mode=$(tr -d '[:space:]' < "${STORAGE_MARKER}")
    case "${storage_mode}" in
        bind) ;;
        volume) legacy_volume=true ;;
        *) echo "Invalid storage mode in ${STORAGE_MARKER}" >&2; exit 1 ;;
    esac
else
    bind_has_data=false
    if [ -d "${STATE_DIR}" ] && [ -n "$(find "${STATE_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        bind_has_data=true
    fi

    if [ -f "${QUADLET_DIR}/incus.container" ] && \
       grep -q '^Volume=incus-data\.volume:/var/lib/incus$' "${QUADLET_DIR}/incus.container"; then
        legacy_volume=true
    elif podman volume exists "${LEGACY_VOLUME}"; then
        echo "Podman volume ${LEGACY_VOLUME} exists without an installer storage marker." >&2
        echo "Refusing to guess whether it contains this deployment's state." >&2
        exit 1
    fi

    if [ "${bind_has_data}" = true ] && [ ! -f "${QUADLET_DIR}/incus.container" ] && [ "${adopt_bind}" != true ]; then
        echo "${STATE_DIR} is non-empty but is not marked as this container's state." >&2
        echo "Refusing to modify it. Rerun with --adopt-bind if this is intentional." >&2
        exit 1
    fi
fi

validation_dir=$(mktemp -d)
cleanup_validation() {
    rm -rf "${validation_dir}"
}
trap cleanup_validation EXIT HUP INT TERM

install -m 0644 "${script_dir}/quadlet/incus.container" "${validation_dir}/incus.container"
install -d -m 0755 "${validation_dir}/incus.container.d"
install -m 0644 "${script_dir}/quadlet/incus-environment.conf" \
    "${validation_dir}/incus.container.d/20-environment.conf"
printf '[Container]\nEnvironment=INCUS_GID=0\n' \
    > "${validation_dir}/incus.container.d/30-host-access.conf"

QUADLET_UNIT_DIRS="${validation_dir}" "${quadlet_generator}" --dryrun >/dev/null
cleanup_validation
trap - EXIT HUP INT TERM

if ! getent group incus-admin >/dev/null; then
    groupadd --system incus-admin
fi
incus_gid=$(getent group incus-admin | cut -d: -f3)
case "${incus_gid}" in
    ''|*[!0-9]*) echo "Could not determine the host incus-admin GID." >&2; exit 1 ;;
esac

if [ "${target_user}" != root ] && \
   ! id -nG "${target_user}" | tr ' ' '\n' | grep -qx incus-admin; then
    usermod --append --groups incus-admin "${target_user}"
fi

volume_migrated=false
migration_active=false
migration_dir=

recover_legacy_service() {
    if [ "${migration_active}" = true ]; then
        [ -z "${migration_dir}" ] || rm -rf "${migration_dir}" || true
        if [ -f "${QUADLET_DIR}/incus.container" ] && \
           grep -q '^Volume=/var/lib/incus:/var/lib/incus$' "${QUADLET_DIR}/incus.container"; then
            echo "Installation did not complete; starting Incus from migrated bind storage." >&2
            if ! systemctl daemon-reload; then
                echo "Could not load the bind-backed service; Incus remains stopped." >&2
                return
            fi
        else
            echo "Migration did not complete; restarting the volume-backed service." >&2
        fi
        systemctl start incus.service || true
    fi
}

if [ "${legacy_volume}" = true ]; then
    if ! podman volume exists "${LEGACY_VOLUME}"; then
        echo "Storage mode is volume, but Podman volume ${LEGACY_VOLUME} does not exist." >&2
        exit 1
    fi

    if [ -d "${STATE_DIR}" ] && \
       [ -n "$(find "${STATE_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] && \
       [ ! -f "${MIGRATION_MARKER}" ]; then
        echo "Refusing to migrate ${LEGACY_VOLUME}: ${STATE_DIR} is not empty." >&2
        exit 1
    fi

    volume_mountpoint=$(podman volume inspect --format '{{.Mountpoint}}' "${LEGACY_VOLUME}")
    migration_dir=/var/lib/.incus-volume-migration.$$
    resume_bind_state=false
    if [ -f "${MIGRATION_MARKER}" ] && \
       [ -f "${QUADLET_DIR}/incus.container" ] && \
       grep -q '^Volume=/var/lib/incus:/var/lib/incus$' "${QUADLET_DIR}/incus.container" && \
       [ -d "${STATE_DIR}" ] && \
       [ -n "$(find "${STATE_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        resume_bind_state=true
    fi

    install -d -m 0755 "${QUADLET_DIR}"
    printf '%s\n' "${LEGACY_VOLUME}" > "${MIGRATION_MARKER}"
    chmod 0644 "${MIGRATION_MARKER}"
    trap recover_legacy_service EXIT
    trap 'exit 1' HUP INT TERM

    echo "Stopping Incus to migrate ${LEGACY_VOLUME} to ${STATE_DIR}"
    migration_active=true
    systemctl stop incus.service

    if [ "${resume_bind_state}" = true ]; then
        echo "Resuming the interrupted migration from ${STATE_DIR}"
        migration_dir=
    else
        if ! install -d -m 0700 "${migration_dir}" || \
           ! cp -a "${volume_mountpoint}/." "${migration_dir}/" || \
           ! chmod 0711 "${migration_dir}"; then
            echo "Volume migration failed." >&2
            exit 1
        fi

        if [ -d "${STATE_DIR}" ]; then
            if [ -f "${MIGRATION_MARKER}" ] && \
               [ -n "$(find "${STATE_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
                rm -rf "${STATE_DIR}"
            else
                rmdir "${STATE_DIR}"
            fi
        fi
        mv "${migration_dir}" "${STATE_DIR}"
        migration_dir=
    fi
    volume_migrated=true
fi

install -d -m 0711 "${STATE_DIR}"
install -d -m 0750 -o "${target_user}" -g "${target_group}" "${STATE_DIR}/.config"
install -d -m 0750 -o "${target_user}" -g "${target_group}" "${STATE_DIR}/.config/incus"
install -d -m 0700 -o "${target_user}" -g "${target_group}" "${STATE_DIR}/.config/incus/sockets"
chown -R "${target_user}:${target_group}" "${STATE_DIR}/.config/incus"

install -d -m 0755 "${QUADLET_DIR}"
install -m 0644 "${script_dir}/quadlet/incus.container" "${QUADLET_DIR}/incus.container"
install -d -m 0755 "${QUADLET_DIR}/incus.container.d"
install -m 0644 "${script_dir}/quadlet/incus-environment.conf" \
    "${QUADLET_DIR}/incus.container.d/20-environment.conf"
printf '[Container]\nEnvironment=INCUS_GID=%s\n' "${incus_gid}" > "${HOST_ACCESS_DROPIN}"
chmod 0644 "${HOST_ACCESS_DROPIN}"
rm -f "${QUADLET_DIR}/incus-data.volume" "${QUADLET_DIR}/incus.container.d/10-storage.conf"

storage_marker_tmp=${STORAGE_MARKER}.$$
printf '%s\n' bind > "${storage_marker_tmp}"
chmod 0644 "${storage_marker_tmp}"
mv "${storage_marker_tmp}" "${STORAGE_MARKER}"
if [ "${volume_migrated}" = true ]; then
    rm -f "${MIGRATION_MARKER}"
fi

if [ ! -e "${ENVIRONMENT_FILE}" ]; then
    install -m 0644 /dev/null "${ENVIRONMENT_FILE}"
fi

install -d -m 0755 -o "${target_user}" -g "${target_group}" "${target_home}/.local/bin"
install -m 0755 -o "${target_user}" -g "${target_group}" \
    "${script_dir}/bin/incus-container" "${target_home}/.local/bin/incus-container"

legacy_wrapper=${target_home}/.local/bin/incus
if [ -f "${legacy_wrapper}" ]; then
    legacy_wrapper_hash=$(sha256sum "${legacy_wrapper}" | cut -d' ' -f1)
    case "${legacy_wrapper_hash}" in
        54affc6ae05eebf54ade8d5aebea206bc7516be06272ce43db1182e7e3e27f63|\
        9592a861372541411bdecb1919be732f96649d7623cd7e1ad9b6bb543b595a64)
            rm -f "${legacy_wrapper}"
            echo "Removed the legacy ~/.local/bin/incus wrapper."
            ;;
        *)
            echo "Preserving existing ${legacy_wrapper}; it is not a recognized managed wrapper."
            ;;
    esac
fi

if command -v restorecon >/dev/null 2>&1; then
    restorecon -RF "${QUADLET_DIR}" "${ENVIRONMENT_FILE}" "${target_home}/.local/bin/incus-container" || true
fi

echo "Pulling ${IMAGE}"
if ! podman pull "${IMAGE}"; then
    exit 1
fi

systemctl daemon-reload
systemctl restart incus.service
if [ "${volume_migrated}" = true ]; then
    migration_active=false
    trap - EXIT HUP INT TERM
fi

if ! podman exec incus /usr/local/bin/incus-healthcheck; then
    echo "Incus did not become ready. Inspect it with:" >&2
    echo "  sudo systemctl status incus.service" >&2
    echo "  sudo journalctl -u incus.service" >&2
    exit 1
fi

if [ ! -S "${STATE_DIR}/unix.socket" ] || \
   [ "$(stat -c '%g' "${STATE_DIR}/unix.socket")" != "${incus_gid}" ]; then
    echo "Incus is ready, but ${STATE_DIR}/unix.socket does not use host incus-admin GID ${incus_gid}." >&2
    echo "Make sure the pulled image includes INCUS_GID support, then rerun the installer." >&2
    exit 1
fi

echo "Incus is ready using ${STATE_DIR}."
if [ "${volume_migrated}" = true ]; then
    echo "The previous ${LEGACY_VOLUME} volume was retained as a migration backup."
fi
echo "Fallback client wrapper installed at ${target_home}/.local/bin/incus-container"
echo "Ensure ${target_home}/.local/bin is in ${target_user}'s PATH."
echo
echo "Native Incus client setup for ${target_user}:"
echo "  sudo usermod -G incus-admin -a ${target_user}"
echo "  brew install incus"
echo "Log out and back in before using the native Incus client."
