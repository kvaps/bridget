#!/bin/sh

usage() {
cat <<EOF

  Available variables:
    - BRIDGE (example: cbr0)
    - VLAN (example: 100)
    - IFACE (example: eth0)
    - MTU (default: 1500)
    - FORCE_VLAN_CONFIG (example: 1)
    - POD_NETWORK (default: 10.244.0.0/16)
    - DIVISION_PREFIX (default: 24)"

Short workflow:

* If bridge exists it will be used, if not exist it will be created

* If VLAN and IFACE is set, the next chain will be created:
    IFACE <-- VLAN <-- BRIDGE

* If bridge have no IP-address it will be retrived from the DHCP.
  This IP-address will be used as default gateway for containers
  for make possible kubernetes-services.

EOF
}

error() {
    >&2 echo "error: $1"
    >&2 usage
    exit 1
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
    local UNUSED_GATEWAY="$(random_gateway)"
    until ! arpping -c 4 "$UNUSED_GATEWAY" 1>/dev/; do
        local UNUSED_GATEWAY="$(random_gateway)"
    done
    echo "$UNUSED_GATEWAY"
}
right_gateway() {
    local IFS=
    echo "$NETWORKS_LIST" | grep -q "$1"
    unset IFS
}

# ------------------------------------------------------------------------------------
# Configure bridge
# ------------------------------------------------------------------------------------

[ -z "$BRIDGE" ] && error "BRIDGE variable is not defined"

# Check if bridge interface exist
if ! ip link show "$BRIDGE" &> /dev/null; then
    ip link add dev "$BRIDGE" type bridge
    export FORCE_VLAN_CONFIG=1
fi

ip link set "$BRIDGE" up

# ------------------------------------------------------------------------------------
# Configure vlan
# ------------------------------------------------------------------------------------
if ([ ! -z "$VLAN" ] || [ ! -z "$IFACE" ]) && [ "$FORCE_VLAN_CONFIG" == 1 ]; then
    [ -z "$VLAN" ] && error "VLAN variable is not defined"
    [ -z "$IFACE" ] && error "IFACE variable is not defined"

    # check if vlan interface exist
    if ip link show "$IFACE.$VLAN" &> /dev/null; then

        # check vlan interface for master
        MASTERIF="$(ip -o link show "$IFACE.$VLAN" | grep -o 'master [^ ]\+' | cut -d' ' -f2)"
        case "$MASTERIF" in
            "$BRIDGE" ) : ;;
            ""        ) ip link set "$IFACE.$VLAN" master "$BRIDGE" ;;
            *         ) error "interface $IFACE.$VLAN have another master" ;;
        esac
    else
        # create vlan interface
        ip link add link "$IFACE" name "$IFACE.$VLAN" type vlan id "$VLAN"
        ip link set dev "$IFACE.$VLAN" master "$BRIDGE"
    fi
    ip link set dev "$IFACE.$VLAN" up
fi

# ------------------------------------------------------------------------------------
# Retrive network parameters
# ------------------------------------------------------------------------------------

POD_NETWORK="${POD_NETWORK:-10.244.0.0/16}"
DIVISION_PREFIX="${DIVISION_PREFIX:-24}"

export "POD_$(ipcalc -p "$POD_NETWORK")" # POD_PREFIX
export "POD_$(ipcalc -b "$POD_NETWORK")" # POD_BROADCAST
export "POD_$(ipcalc -n "$POD_NETWORK")" # POD_NETWORK

export "FIRST_$(ipcalc -n "$POD_NETWORK/$DIVISION_PREFIX" )" # FIRST_NETWORK
export "LAST_$(ipcalc -n "$POD_BROADCAST/$DIVISION_PREFIX" )" # LAST_NETWORK

NETWORKS_LIST="$(
    CUR_NETWORK="$LAST_NETWORK"
    until [ "$CUR_NETWORK" == "$FIRST_NETWORK" ]; do
        echo "$CUR_NETWORK"
        export CUR_"$(ipcalc -n "$(prev_ip "$CUR_NETWORK")/$DIVISION_PREFIX")"
    done
)"

# ------------------------------------------------------------------------------------
# Configure IP-address
# ------------------------------------------------------------------------------------

# Check ip address
IPADDR="$(ip -f inet -o addr show "$BRIDGE" | grep -o 'inet [^ /]*' | cut -d' ' -f2)"

# If ip not exist 
if [ -z "$IPADDR" ]; then
    IPADDR="$(unused_gateway)/$POD_PREFIX"
    ip addr change $siaddr/$mask dev $interface
else
    if ! right_gateway "$IPADDR"; then
        error "$BRIDGE already have IP address not from the list"
    fi
fi

# ------------------------------------------------------------------------------------
# Configure cni
# ------------------------------------------------------------------------------------

GATEWAY="$IPADDR"
SUBNET="${POD_NETWORK}/${POD_PREFIX}"
FIRST_IP="$(next_ip "${GATEWAY}")"
LAST_IP="$(prev_ip "$(ipcalc -b "${GATEWAY}/${DIVISION_PREFIX}" | cut -d= -f2)")"

cat > /etc/cni/net.d/10-br-dhcp.conf <<EOT
{
        "name": "container",
        "type": "bridge",
        "bridge": "${BRIDGE}",
        "hairpinMode": true,
        "mtu": ${MTU:-1500},
        "ipam": {
                "type": "host-local",
                "subnet": "${SUBNET}",
                "rangeStart": "${FIRST_IP}",
                "rangeEnd": "${LAST_IP}",
                "routes": [
                        { "dst": "0.0.0.0/0" }
                ]
        }
}
EOT

# ------------------------------------------------------------------------------------
# Run cni dhcp daemon
# ------------------------------------------------------------------------------------
rm -f /run/cni/dhcp.sock
/opt/cni/bin/dhcp daemon
