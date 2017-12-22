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

All parameters passing as environment variables:

 - **BRIDGE** *(example: `cbr0`)* - Bridge name. Mandatory option.
 - **VLAN** *(example: `100`)* - VLAN id. If set, the new vlan-interface under IFACE will be created, then added to BRIDGE.
 - **IFACE** *(example: `eth0`)* - Physical interface for connect to bridge. Mandatory if VLAN is set, but can be used singly.
 - **MTU** *(default: `1500`)* - MTU value for cni config
 - **CHECK_SLAVES** *(example: `1`)* - Make bridget for configure slave interfaces, if bridge already exists.
 - **POD_NETWORK** *(default: `10.244.0.0/16`)* - Your pod network.
 - **DIVISION_PREFIX** *(default: `24`)* - Network CIDR prefix for devide your POD_NETWORK.
 - **DEBUG** *(example: `1`)* - Enable verbose output.

## Quick start

* Instantiate your kubernetes with `--pod-network-cidr=10.244.0.0/16` flag.

* Download yaml file:
```
curl -o https://raw.githubusercontent.com/kvaps/bridget/master/bridget.yaml
```

* Edit wanted parameters:
```
vim bridget.yaml
```

By default bridget uses `cbr0` bridge that nowhere connected, so you need to set IFACE and VLAN parameters.
Or make sure that your bridge is already configured for use some physical interface.
Please make sure that you have no any IP-address on bridge, because will be configured automatcally.

* Run daemonset:
```
kubectl create -f bridget.yaml
```
