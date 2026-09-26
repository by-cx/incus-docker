#!/bin/sh
set -eu

PROGRAM_NAME=${0##*/}
IMAGE=ghcr.io/by-cx/incus-docker:latest
QUADLET_DIR=/etc/containers/systemd
ENVIRONMENT_FILE=/etc/incus-container.env
STORAGE_MARKER=${QUADLET_DIR}/incus-storage-mode

usage() {
    cat <<EOF
Usage: ${PROGRAM_NAME} [--user USER] [--adopt-bind]

Install or update the Incus Quadlet and the invoking user's client wrapper.
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

for command in cut find getent install mktemp podman rm systemctl tr; do
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

storage_mode=
if [ -f "${STORAGE_MARKER}" ]; then
    storage_mode=$(tr -d '[:space:]' < "${STORAGE_MARKER}")
    case "${storage_mode}" in
        bind|volume) ;;
        *) echo "Invalid storage mode in ${STORAGE_MARKER}" >&2; exit 1 ;;
    esac
else
    bind_has_data=false
    volume_exists=false
    if [ -d /var/lib/incus ] && [ -n "$(find /var/lib/incus -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        bind_has_data=true
    fi
    if podman volume exists incus-data; then
        volume_exists=true
    fi

    if [ "${bind_has_data}" = true ] && [ "${volume_exists}" = true ]; then
        echo "Both /var/lib/incus and the incus-data volume contain possible state." >&2
        echo "Refusing to guess. Remove the unused state or create ${STORAGE_MARKER}." >&2
        exit 1
    elif [ "${volume_exists}" = true ]; then
        storage_mode=volume
    elif [ "${bind_has_data}" = true ] && { [ -f "${QUADLET_DIR}/incus.container" ] || [ "${adopt_bind}" = true ]; }; then
        storage_mode=bind
    elif [ "${bind_has_data}" = true ]; then
        echo "/var/lib/incus is non-empty but is not marked as this container's state." >&2
        echo "Refusing to modify it. Rerun with --adopt-bind if this is intentional." >&2
        exit 1
    else
        storage_mode=volume
    fi
fi

validation_dir=$(mktemp -d)
cleanup_validation() {
    rm -rf "${validation_dir}"
}
trap cleanup_validation EXIT HUP INT TERM

install -m 0644 "${script_dir}/quadlet/incus.container" "${validation_dir}/incus.container"
install -m 0644 "${script_dir}/quadlet/incus-data.volume" "${validation_dir}/incus-data.volume"
install -d -m 0755 "${validation_dir}/incus.container.d"
install -m 0644 "${script_dir}/quadlet/incus-environment.conf" \
    "${validation_dir}/incus.container.d/20-environment.conf"
if [ "${storage_mode}" = bind ]; then
    install -m 0644 "${script_dir}/quadlet/incus-bind-storage.conf" \
        "${validation_dir}/incus.container.d/10-storage.conf"
fi

QUADLET_UNIT_DIRS="${validation_dir}" "${quadlet_generator}" --dryrun >/dev/null
cleanup_validation
trap - EXIT HUP INT TERM

echo "Pulling ${IMAGE}"
podman pull "${IMAGE}"

install -d -m 0755 "${QUADLET_DIR}"
install -m 0644 "${script_dir}/quadlet/incus.container" "${QUADLET_DIR}/incus.container"
install -m 0644 "${script_dir}/quadlet/incus-data.volume" "${QUADLET_DIR}/incus-data.volume"
install -d -m 0755 "${QUADLET_DIR}/incus.container.d"
install -m 0644 "${script_dir}/quadlet/incus-environment.conf" \
    "${QUADLET_DIR}/incus.container.d/20-environment.conf"

if [ "${storage_mode}" = bind ]; then
    install -d -m 0711 /var/lib/incus
    install -m 0644 "${script_dir}/quadlet/incus-bind-storage.conf" \
        "${QUADLET_DIR}/incus.container.d/10-storage.conf"
else
    rm -f "${QUADLET_DIR}/incus.container.d/10-storage.conf"
    podman volume exists incus-data || podman volume create incus-data >/dev/null
fi

printf '%s\n' "${storage_mode}" > "${STORAGE_MARKER}"
chmod 0644 "${STORAGE_MARKER}"

if [ ! -e "${ENVIRONMENT_FILE}" ]; then
    install -m 0644 /dev/null "${ENVIRONMENT_FILE}"
fi

install -d -m 0755 -o "${target_user}" -g "${target_group}" "${target_home}/.local/bin"
install -m 0755 -o "${target_user}" -g "${target_group}" \
    "${script_dir}/bin/incus" "${target_home}/.local/bin/incus"

if command -v restorecon >/dev/null 2>&1; then
    restorecon -RF "${QUADLET_DIR}" "${ENVIRONMENT_FILE}" "${target_home}/.local/bin/incus" || true
fi

systemctl daemon-reload
systemctl restart incus.service

if ! podman exec incus /usr/local/bin/incus-healthcheck; then
    echo "Incus did not become ready. Inspect it with:" >&2
    echo "  sudo systemctl status incus.service" >&2
    echo "  sudo journalctl -u incus.service" >&2
    exit 1
fi

echo "Incus is ready using ${storage_mode} storage."
echo "Client wrapper installed at ${target_home}/.local/bin/incus"
echo "Ensure ${target_home}/.local/bin is in ${target_user}'s PATH."
