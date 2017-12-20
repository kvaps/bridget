#!/bin/sh

usage() {
cat <<EOF

  Available variables:
    - BRIDGE (example: cbr0)
    - VLAN (example: 100)
    - IFACE (example: eth0)
    - MTU (default: 1500)
    - FORCE_VLAN_CONFIG (example: 1)

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
# Configure IP-address
# ------------------------------------------------------------------------------------

# Check ip address
IPADDR="$(ip -f inet -o addr show "$BRIDGE" | grep -o 'inet [^ /]*' | cut -d' ' -f2)"

# If ip not exist 
if [ -z "$IPADDR" ]; then
    echo -e '#!/bin/sh\nip addr change $siaddr/$mask dev $interface' > /tmp/udhcpc-script.sh
    chmod +x /tmp/udhcpc-script.sh
    if ! udhcpc -q -i "$BRIDGE" -s /tmp/udhcpc-script.sh; then
        error "Can not rerive IP for the bridge interface"
    fi
fi

IPADDR="$(ip -f inet -o addr show "$BRIDGE" | grep -o 'inet [^ /]*' | cut -d' ' -f2)"
#IPADDR6="$(ip -f inet6 -o addr show "$BRIDGE" | grep -o 'inet6 [^ /]*' | cut -d' ' -f2)"

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
# Configure cni
# ------------------------------------------------------------------------------------
cat > /etc/cni/net.d/10-br-dhcp.conf <<EOT
{
        "name": "br-dhcp",
        "type": "bridge",
        "bridge": "${BRIDGE}",
        "hairpinMode": true,
        "mtu": ${MTU:-1500},
        "ipam": {
                "type": "dhcp",
                "gateway": "${IPADDR}"
        }
}
EOT

# ------------------------------------------------------------------------------------
# Run cni dhcp daemon
# ------------------------------------------------------------------------------------
rm -f /run/cni/dhcp.sock
/opt/cni/bin/dhcp daemon
