# bridget

![](images/logo.svg)

Simple bridge network for kubernetes 

![](https://img.shields.io/docker/build/kvaps/bridget.svg)

## How it works

bridget - it's short shell script, that helps you for organise simple bridge network for Kubernetes.
There is no overlays, no politics. Just flat L2-network across all your hosts and pods.

In addition bridget can automatically configure VLAN and bridge interfaces for that. See the picture:

![](images/scheme.svg)

bridget automatically retrieves IP-addresses from your pod-network, and configures cni for use it. Collision check is carried out each new run by arping tool.

## Parameters

 - **BRIDGE** *(example: `cbr0`)* - Bridge name. Mandatory option.
 - **VLAN** *(example: `100`)* - VLAN id. If set, the new vlan-interface under IFACE will be created, then added to BRIDGE.
 - **IFACE** *(example: `eth0`)* - Physical interface for connect to bridge. Mandatory if VLAN is set, but can be used singly.
 - **MTU** *(default: `1500`)* - MTU value for cni config
 - **CHECK_SLAVES** *(example: `1`)* - Make bridget for configure slave interfaces, if bridge already exists.
 - **POD_NETWORK** *(default: `10.244.0.0/16`)* - Your pod network.
 - **DIVISION_PREFIX** *(default: `24`)* - Network CIDR prefix for devide your POD_NETWORK.
 - **DEBUG** *(example: `1`)* - Enable verbose output.
