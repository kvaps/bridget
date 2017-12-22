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
