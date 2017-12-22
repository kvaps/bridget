#!/bin/sh

CNI_CONFIG="${CNI_CONFIG:-/etc/cni/net.d/10-bridget.conf}"

usage() {
cat <<EOF

  Available variables:
    - BRIDGE (example: cbr0)
    - VLAN (example: 100)
    - IFACE (example: eth0)
    - MTU (default: 1500)
    - CHECK_SLAVES (example: 1)
    - POD_NETWORK (default: 10.244.0.0/16)
    - DIVISION_PREFIX (default: 24)"
    - DEBUG (example: 1)

Short workflow:

* If bridge exists it will be used, if not exist it will be created

* If VLAN and IFACE is set, the next chain will be created:
    IFACE <-- VLAN <-- BRIDGE

* If bridge have no IP-address it will be retrived automatically
  This IP-address will be used as default gateway for containers
  for make possible kubernetes-services.

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
    if [ "$DEBUG" == 1 ]; then
        echo -en "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:\t"
        echo "$1"
    fi
}

next_ip() {
    local IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $1 | sed -e 's/\./ /g'`)
    local NEXT_IP_HEX=$(printf %.8X `echo $(( 0x$IP_HEX + 1 ))`)
    local NEXT_IP=$(printf '%d.%d.%d.%d\n' `echo $NEXT_IP_HEX | sed -r 's/(..)/0x\1 /g'`)
    echo $NEXT_IP
}

prev_ip() {
    local IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $1 | sed -e 's/\./ /g'`)
    local PREV_IP_HEX=$(printf %.8X `echo $(( 0x$IP_HEX - 1 ))`)
    local PREV_IP=$(printf '%d.%d.%d.%d\n' `echo $PREV_IP_HEX | sed -r 's/(..)/0x\1 /g'`)
    echo $PREV_IP
}

random_gateway() {
    local IFS=
    local NETWORKS_NUM="$(echo "$NETWORKS_LIST" | wc -l)"
    local RANDOM_NETWORK_NUM="$(shuf -i "1-$NETWORKS_NUM" -n 1)"
    local RANDOM_NETWORK="$(echo "$NETWORKS_LIST" | head -n "$RANDOM_NETWORK_NUM" | tail -n 1)"
    unset IFS
    local RANDOM_GATEWAY="$(next_ip $RANDOM_NETWORK)"
    echo "$RANDOM_GATEWAY"
}

unused_gateway() {
    [ -f "$CNI_CONFIG" ] && local UNUSED_GATEWAY=$(sed -n 's/.*"gateway": "\(.*\)",/\1/p' "$CNI_CONFIG")
    if [ -z $UNUSED_GATEWAY ] || ! right_gateway "$UNUSED_GATEWAY"; then
        UNUSED_GATEWAY="$(random_gateway)"
    fi

    while arping -i "$BRIDGE" -S 0.0.0.0 -c 4 "$UNUSED_GATEWAY" 1>/dev/null; do
        local UNUSED_GATEWAY="$(random_gateway)"
    done
    echo "$UNUSED_GATEWAY"
}
right_gateway() {
    (IFS= echo "$NETWORKS_LIST") | grep -q "$(prev_ip $1)"
}

# ------------------------------------------------------------------------------------
# Configure bridge
# ------------------------------------------------------------------------------------

log "Starting bridge configuration"
[ -z "$BRIDGE" ] && error "BRIDGE variable is not defined"

# Check if bridge interface exist
if ! ip link show "$BRIDGE" &> /dev/null; then

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

if ([ ! -z "$VLAN" ] || [ ! -z "$IFACE" ]) && [ "$CHECK_SLAVES" == 1 ]; then

    log "Starting VLAN configuration"
    [ -z "$IFACE" ] && error "IFACE variable is not defined"

    if [ ! -z "$VLAN" ]; then
        # check if vlan interface exist
        if ip link show "$IFACE.$VLAN" &> /dev/null; then
            log "VLAN interface $IFACE.$VLAN already exist"
        else
            log "Adding new VLAN interface $IFACE.$VLAN"
            ip link add link "$IFACE" name "$IFACE.$VLAN" type vlan id "$VLAN"
        fi
        log "Setting vlan $IFACE.$VLAN up"
        ip link set dev "$IFACE.$VLAN" up
    fi
fi

# ------------------------------------------------------------------------------------
# Configure slaves
# ------------------------------------------------------------------------------------

if ([ ! -z "$VLAN" ] || [ ! -z "$IFACE" ]) && [ "$CHECK_SLAVES" == 1 ]; then

    log "Starting configuring slave interfaces"

    if [ ! -z "$VLAN" ]; then
        SLAVEIF="$IFACE.$VLAN"
    else
        SLAVEIF="$IFACE"
    fi

    if ! ip link show "$SLAVEIF" &> /dev/null; then
        error "$SLAVEIF does not exist"
    fi

    # check if slave interface contains right master
    MASTERIF="$(ip -o link show "$SLAVEIF" | grep -o -m1 'master [^ ]\+' | cut -d' ' -f2 )"

    case "$MASTERIF" in
        "$BRIDGE" ) log "$SLAVEIF already member of $BRIDGE" ;;
        ""        ) log "Adding $SLAVEIF as member to $BRIDGE"
                    ip link set "$SLAVEIF" master "$BRIDGE" ;;
        *         ) error "interface $SLAVEIF have another master" ;;
    esac
fi

# ------------------------------------------------------------------------------------
# Retrive network parameters
# ------------------------------------------------------------------------------------

log "Starting retriving parameters"

POD_NETWORK="${POD_NETWORK:-10.244.0.0/16}"
DIVISION_PREFIX="${DIVISION_PREFIX:-24}"

log "POD_NETWORK=$POD_NETWORK"
log "DIVISION_PREFIX=$DIVISION_PREFIX"

set -e

export "POD_$(ipcalc -p "$POD_NETWORK")" # POD_PREFIX
export "POD_$(ipcalc -b "$POD_NETWORK")" # POD_BROADCAST
export "POD_$(ipcalc -n "$POD_NETWORK")" # POD_NETWORK
export "FIRST_$(ipcalc -n "$POD_NETWORK/$DIVISION_PREFIX" )" # FIRST_NETWORK
export "LAST_$(ipcalc -n "$POD_BROADCAST/$DIVISION_PREFIX" )" # LAST_NETWORK

set +e

debug "POD_PREFIX=$POD_PREFIX"
debug "POD_BROADCAST=$POD_BROADCAST"
debug "POD_NETWORK=$POD_NETWORK"
debug "FIRST_NETWORK=$FIRST_NETWORK"
debug "LAST_NETWORK=$LAST_NETWORK"

NETWORKS_LIST="$(
    CUR_NETWORK="$LAST_NETWORK"
    until [ "$CUR_NETWORK" == "$FIRST_NETWORK" ]; do
        echo "$CUR_NETWORK"
        export CUR_"$(ipcalc -n "$(prev_ip "$CUR_NETWORK")/$DIVISION_PREFIX")"
    done
)"

debug "NETWORKS_LIST=\"$(echo "$NETWORKS_LIST" | tr '\n' ' ' )\""

# ------------------------------------------------------------------------------------
# Configure IP-address
# ------------------------------------------------------------------------------------

log "Starting configuring IP-address"

# Check ip address
IPADDR="$(ip -f inet -o addr show "$BRIDGE" | grep -o -m1 'inet [^ /]*' | cut -d' ' -f2)"

# If ip not exist 
if [ -z "$IPADDR" ]; then

    log "Retrieving IP-address"
    IPADDR="$(unused_gateway)"
    log "Successful retrived $IPADDR"

    log "Configuring $IPADDR/$POD_PREFIX on $BRIDGE"
    ip addr change "$IPADDR/$POD_PREFIX" dev "$BRIDGE"

else

    if ! right_gateway "$IPADDR"; then
        error "$BRIDGE already have IP address not from the list"
    fi
    log "IP-address $IPADDR already set, use it"

fi

# ------------------------------------------------------------------------------------
# Configure cni
# ------------------------------------------------------------------------------------

log "Starting generating CNI configuration"

set -e

GATEWAY="$IPADDR"
SUBNET="${POD_NETWORK}/${POD_PREFIX}"
FIRST_IP="$(next_ip "${GATEWAY}")"
LAST_IP="$(prev_ip "$(ipcalc -b "${GATEWAY}/${DIVISION_PREFIX}" | cut -d= -f2)")"

set +e

debug "GATEWAY=$GATEWAY"
debug "SUBNET=$SUBNET"
debug "FIRST_IP=$FIRST_IP"
debug "LAST_IP=$LAST_IP"

log "Writing $CNI_CONFIG"

cat > $CNI_CONFIG <<EOT
{
        "name": "bridget",
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
debug "$(cat "$CNI_CONFIG")"

# ------------------------------------------------------------------------------------
# Sleep gently
# ------------------------------------------------------------------------------------
tail -f /dev/null
