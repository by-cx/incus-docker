# syntax=docker/dockerfile:1

FROM debian:trixie-slim

ARG INCUS_CHANNEL=stable
ARG ZABBLY_KEY_FINGERPRINT=4EFC590696CB15B87C73A3AD82CC8797C838DCFD

ENV HOME=/var/lib/incus \
    INCUS_AGENT_PATH=/opt/incus/agent/ \
    INCUS_DOCUMENTATION=/opt/incus/doc/ \
    INCUS_EDK2_PATH=/opt/incus/share/qemu/ \
    INCUS_LXC_HOOK=/opt/incus/share/lxc/hooks/ \
    INCUS_LXC_TEMPLATE_CONFIG=/opt/incus/share/lxc/config/ \
    INCUS_UI=/opt/incus/ui/ \
    LD_LIBRARY_PATH=/opt/incus/lib/ \
    PATH=/opt/incus/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    case "${INCUS_CHANNEL}" in \
        stable|daily|lts-7.0) ;; \
        *) echo "Unsupported Incus channel: ${INCUS_CHANNEL}" >&2; exit 1 ;; \
    esac; \
    printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/systemctl; \
    chmod 0755 /usr/local/bin/systemctl; \
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; \
    chmod 0755 /usr/sbin/policy-rc.d; \
    sed -i 's/^Components: main$/Components: main contrib/' /etc/apt/sources.list.d/debian.sources; \
    apt-get update; \
    apt-get install --no-install-recommends -y ca-certificates curl gnupg; \
    mkdir -m 0700 /tmp/gnupg; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc; \
    test "$(gpg --batch --homedir /tmp/gnupg --show-keys --with-colons /etc/apt/keyrings/zabbly.asc | grep '^fpr:' | cut -d: -f10 | head -n1)" = "${ZABBLY_KEY_FINGERPRINT}"; \
    rm -rf /tmp/gnupg; \
    printf '%s\n' \
        'Enabled: yes' \
        'Types: deb' \
        "URIs: https://pkgs.zabbly.com/incus/${INCUS_CHANNEL}" \
        'Suites: trixie' \
        'Components: main' \
        "Architectures: $(dpkg --print-architecture)" \
        'Signed-By: /etc/apt/keyrings/zabbly.asc' \
        > /etc/apt/sources.list.d/zabbly-incus.sources; \
    apt-get update; \
    apt-get install --no-install-recommends -y \
        arptables \
        btrfs-progs \
        ebtables \
        fuse3 \
        incus \
        incus-ui-canonical \
        iproute2 \
        iptables \
        kmod \
        lvm2 \
        nftables \
        openvswitch-switch \
        passwd \
        thin-provisioning-tools \
        zfsutils-linux; \
    rm -f /usr/local/bin/systemctl /usr/sbin/policy-rc.d; \
    rm -rf /var/lib/apt/lists/*; \
    test -x /opt/incus/bin/incusd; \
    test -x /opt/incus/bin/lxcfs; \
    test -d /opt/incus/share/qemu

COPY incus-entrypoint /usr/local/sbin/incus-entrypoint
COPY incus-healthcheck /usr/local/bin/incus-healthcheck

RUN chmod 0755 /usr/local/sbin/incus-entrypoint /usr/local/bin/incus-healthcheck

STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/incus-healthcheck"]

ENTRYPOINT ["/usr/local/sbin/incus-entrypoint"]
