#!/bin/sh

CNI_CONFIG="${CNI_CONFIG:-/etc/cni/net.d/10-bridget.conf}"

usage() {
    cat <<EOF

  Available variables:
    - BRIDGE (example: cbr0)
    - VLAN (example: 100)
    - IFACE (example: eth0)
    - MTU (default: 1500)
    - CHECK_SLAVES (default: 1)
    - POD_NETWORK (default: 10.244.0.0/16)
    - DEBUG (default: 0)

Short workflow:

* If the bridge exists it will be used, otherwise it will be created

* If VLAN and IFACE are set, the following chain will be created:
    IFACE <-- VLAN <-- BRIDGE

* IP-address will be set automatically. This IP-address
  will be used as default gateway for containers
  to make kubernetes services work.

EOF
}

error() {
    >&2 echo -en "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:\t"
    >&2 echo "$1"
    >&2 usage
    exit 1
}

log() {
    echo -en "[$(date '+%Y-%m-%d %H:%M:%S')] INFO:\t"
    echo "$1"
}

debug() {
    if [ "${DEBUG:-0}" = 1 ]; then
        >&2 echo -en "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:\t"
        >&2 echo "$1"
    fi
}

next_ip() {
    local IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' $(echo $1 | sed -e 's/\./ /g'))
    local NEXT_IP_HEX=$(printf %.8X $(echo $((0x$IP_HEX + 1))))
    local NEXT_IP=$(printf '%d.%d.%d.%d\n' $(echo $NEXT_IP_HEX | sed -r 's/(..)/0x\1 /g'))
    echo $NEXT_IP
}

prev_ip() {
    local IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' $(echo $1 | sed -e 's/\./ /g'))
    local PREV_IP_HEX=$(printf %.8X $(echo $((0x$IP_HEX - 1))))
    local PREV_IP=$(printf '%d.%d.%d.%d\n' $(echo $PREV_IP_HEX | sed -r 's/(..)/0x\1 /g'))
    echo $PREV_IP
}

getnodecidr() {
    CA_CERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
    curl -sS -m 5 --cacert $CA_CERT -H "Authorization: Bearer $TOKEN" "https://${KUBERNETES_PORT#*//}/api/v1/nodes/$1" | jq -r .spec.podCIDR
}

# ------------------------------------------------------------------------------------
# Configure bridge
# ------------------------------------------------------------------------------------

log "Starting bridge configuration"
[ -z "$BRIDGE" ] && error "BRIDGE variable is not defined"
[ -z "$NODE_NAME" ] && error "NODE_NAME variable is not defined"

# Check if bridge interface exist
if ! ip link show "$BRIDGE" 1>/dev/null 2>/dev/null; then

    log "Adding new bridge $BRIDGE"
    ip link add dev "$BRIDGE" type bridge
    export CHECK_SLAVES=1

else

    log "Bridge $BRIDGE already exist, use it"

fi

log "Setting bridge $BRIDGE up"
ip link set "$BRIDGE" up

# ------------------------------------------------------------------------------------
# Configure vlan
# ------------------------------------------------------------------------------------

if ([ ! -z "$VLAN" ] || [ ! -z "$IFACE" ]) && [ "${CHECK_SLAVES:-1}" = 1 ]; then

    log "Starting VLAN configuration"
    [ -z "$IFACE" ] && error "IFACE variable is not defined"

    if [ ! -z "$VLAN" ]; then
        # check if vlan interface exist
        if ip link show "$IFACE.$VLAN" 1>/dev/null 2>/dev/null; then
            log "VLAN interface $IFACE.$VLAN already exist"
        else
            log "Adding new VLAN interface $IFACE.$VLAN"
            ip link add link "$IFACE" name "$IFACE.$VLAN" mtu "${MTU}" type vlan id "$VLAN"
        fi
        log "Setting vlan $IFACE.$VLAN up"
        ip link set dev "$IFACE.$VLAN" up
    fi
fi

# ------------------------------------------------------------------------------------
# Configure slaves
# ------------------------------------------------------------------------------------

if ([ ! -z "$VLAN" ] || [ ! -z "$IFACE" ]) && [ "${CHECK_SLAVES:-1}" = 1 ]; then

    log "Starting configuring slave interfaces"

    if [ ! -z "$VLAN" ]; then
        SLAVEIF="$IFACE.$VLAN"
    else
        SLAVEIF="$IFACE"
    fi

    if ! ip link show "$SLAVEIF" 1>/dev/null 2>/dev/null; then
        error "$SLAVEIF does not exist"
    fi

    # check if slave interface contains right master
    MASTERIF="$(ip -o link show "$SLAVEIF" | grep -o -m1 'master [^ ]\+' | cut -d' ' -f2)"

    case "$MASTERIF" in
    "$BRIDGE") log "$SLAVEIF already member of $BRIDGE" ;;
    ""       ) log "Adding $SLAVEIF as member to $BRIDGE"
               ip link set "$SLAVEIF" master "$BRIDGE"  ;;
    *        ) error "interface $SLAVEIF have another master" ;;
    esac
fi

# ------------------------------------------------------------------------------------
# Retrive network parameters
# ------------------------------------------------------------------------------------

log "Starting retriving parameters"

POD_NETWORK="${POD_NETWORK:-10.244.0.0/16}"
NODE_NETWORK="$(getnodecidr "${NODE_NAME}")"
if [ -z "$NODE_NETWORK" ] || [ "$NODE_NETWORK" = "null" ]; then
    error "Failed to get node cidr"
fi

set -e

export "POD_$(ipcalc -b "$POD_NETWORK")"    # POD_BROADCAST
export "POD_$(ipcalc -p "$POD_NETWORK")"    # POD_PREFIX
export "POD_$(ipcalc -n "$POD_NETWORK")"    # POD_NETWORK
export "NODE_$(ipcalc -p "$NODE_NETWORK")"  # NODE_PREFIX
export "NODE_$(ipcalc -b "$NODE_NETWORK")"  # NODE_BROADCAST
export "NODE_$(ipcalc -n "$NODE_NETWORK")"  # NODE_NETWORK
export "NODE_IP=$(next_ip "$NODE_NETWORK")" # NODE_IP

set +e

debug "POD_BROADCAST=$POD_BROADCAST"
debug "POD_PREFIX=$POD_PREFIX"
debug "POD_NETWORK=$POD_NETWORK"
debug "NODE_PREFIX=$NODE_PREFIX"
debug "NODE_BROADCAST=$NODE_BROADCAST"
debug "NODE_NETWORK=$NODE_NETWORK"
debug "NODE_IP=$NODE_IP"

# ------------------------------------------------------------------------------------
# Configure IP-address
# ------------------------------------------------------------------------------------

log "Configuring $NODE_IP/$POD_PREFIX on $BRIDGE"
ip -o addr show "$BRIDGE" | grep -o 'inet [^ ]\+' | while read _ IP; do
    # Remove bridge addresses from the same subnet, don't touch other addresses
    if [ "$(ipcalc -b "$IP")" = "BROADCAST=${POD_BROADCAST}" ] && [ "$IP" != "$NODE_IP/$POD_PREFIX" ]; then
        ip addr del "$IP" dev "$BRIDGE"
    fi
done
ip addr change "$NODE_IP/$POD_PREFIX" dev "$BRIDGE"

# ------------------------------------------------------------------------------------
# Configure cni
# ------------------------------------------------------------------------------------

log "Starting generating CNI configuration"

set -e

GATEWAY="${NODE_IP}"
SUBNET="${POD_NETWORK}/${POD_PREFIX}"
FIRST_IP="$(next_ip "${NODE_IP}")"
LAST_IP="$(prev_ip "${NODE_BROADCAST}")"

set +e

debug "GATEWAY=$GATEWAY"
debug "SUBNET=$SUBNET"
debug "FIRST_IP=$FIRST_IP"
debug "LAST_IP=$LAST_IP"

log "Writing $CNI_CONFIG"

cat >$CNI_CONFIG <<EOT
{
        "name": "bridget",
        "cniVersion": "0.2.0",
        "type": "bridge",
        "bridge": "${BRIDGE}",
        "ipMasq": true,
        "mtu": ${MTU:-1500},
        "ipam": {
                "type": "host-local",
                "subnet": "${SUBNET}",
                "rangeStart": "${FIRST_IP}",
                "rangeEnd": "${LAST_IP}",
                "gateway": "${GATEWAY}",
                "routes": [
                        { "dst": "0.0.0.0/0" }
                ]
        }
}
EOT

# Display config
cat "$CNI_CONFIG"

# ------------------------------------------------------------------------------------
# Sleep gently
# ------------------------------------------------------------------------------------
exec tail -f /dev/null
