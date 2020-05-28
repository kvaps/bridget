# bridget

![](images/logo.svg)

Simple bridge network for kubernetes

![](https://img.shields.io/docker/build/kvaps/bridget.svg)

## How it works

bridget is a short shell script that helps you to organise simple bridged network for Kubernetes.
There are no overlays, no policies. Just a flat L2-network across all your hosts and pods.

In addition bridget can automatically configure VLAN and bridge interfaces for that. See the picture:

![](images/scheme.svg)

bridget automatically retrieves node cidr from your pod-network and configures cni to use it.

## Parameters

All parameters are passed as environment variables:

 - **BRIDGE** *(example: `cbr0`)* - Bridge name. Mandatory option.
 - **VLAN** *(example: `100`)* - VLAN id. If set, a new vlan-interface under IFACE will be created and added to BRIDGE.
 - **IFACE** *(example: `eth0`)* - Physical interface to connect bridge to. Mandatory if VLAN is set, but can also be used alone.
 - **MTU** *(default: `1500`)* - MTU value for cni config
 - **CHECK_SLAVES** *(default: `1`)* - Make bridget configure slave interfaces if the bridge already exists.
 - **POD_NETWORK** *(default: `10.244.0.0/16`)* - Your pod network.
 - **DEBUG** *(default: `0`)* - Enable verbose output.

## Quick start

* Instantiate your kubernetes with `--pod-network-cidr=10.244.0.0/16` flag.

* Download yaml file:
```
curl -O https://raw.githubusercontent.com/kvaps/bridget/master/bridget.yaml
```

* Edit desired parameters:
```
vim bridget.yaml
```

By default bridget uses `cbr0` bridge that isn't connected anywhere, so you need to either set IFACE and VLAN parameters
or configure your host system to connect the physical interface to this bridge manually.

Please make sure that you have no IP address on the bridge because it will be configured automatically.

* Run daemonset:
```
kubectl create -f bridget.yaml
```

## Update

* Check your `bridget.yaml` for changes.

* Run:
```
kubectl delete -f bridget.yaml
kubectl create -f bridget.yaml
```

## Alternatives

There aren't a lot of alternatives if you want to use flat L2-network with kubernetes.

Even with most of the existing solutions like [flannel](https://github.com/coreos/flannel)'s or
[romana](https://github.com/romana/romana)'s L2 modes it's still quite difficult to use your own rules
for NATing and routing. So you gain flexible policies and some other things, but lose simplicity and
productivity of a simple L2-network.

Bridget was created under [pipework](https://github.com/kvaps/kube-pipework)'s inspiration.
pipework allows you to add single interfaces to your containers, but with additional manual actions,
and Kubernetes doesn't know anything about your manual changes.

Unlike pipework, bridget uses [CNI](https://github.com/containernetworking/cni) to configure pod interfaces.
As a result all configuration occurs automatically and kubernetes gets right IP-addresses.

Another alternative is to сreate your own CNI configuration with [bridge](https://github.com/containernetworking/plugins/tree/master/plugins/main/bridge)
or [macvlan](https://github.com/containernetworking/plugins/tree/master/plugins/main/macvlan) plugin for each of your hosts.

## Contact

* Author: [kvaps](mailto:kvapss@gmail.com)
* Bugs: [issues](https://github.com/kvaps/bridget/issues)

## Contributing

Use Pull Requests to contribute bugfixes or new features. It is assumed that your code and documentation are contributed under the Apache License 2.0.

## Reporting bugs

Please use github issue-tracker to submit bugs

## License

bridget is distributed under the Apache 2.0 license. See the [LICENSE](LICENSE) file for details.
