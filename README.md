# Introduction

The Cilium project recently became a graduated CNCF project and is the only graduated project in the CNCF Cloud Native Networking category.
While Cilium can do many things - Ingress, Service Mesh, Observability, Encryption - its popularity initially soared as a pure CNI: a high-performance feature-rich Container Network plugin.
However, we may actually take for granted what CNI actually means.
In this repository, we will demistify what a CNI does and even build a CNI from scratch.
By the end of this repository, you will have built your own homemade alternative to Cilium.

## What Is a Container Network Interface (CNI)?

The Container Network Interface (CNI) is a CNCF project that specifies the relationship between a Container Runtime Interface (CRI), such as containerd, responsible for container creation, and a CNI plugin tasked with configuring network interfaces within the container upon execution.
Ultimately, it's the CNI plugin that performs the substantive tasks of configuring the network, while CNI primarily denotes the interaction framework.
However, it's common practice to simply refer to the CNI plugin as "CNI", a convention we'll adhere to in this repository.

## Container Networking Explained

Containers do not possess their own kernel, instead they rely on the kernel of the host system on which they are running.
This design choice renders containers more lightweight but less isolated compared to Virtual Machines (VMs).
To provide some level of isolation, containers utilize a kernel feature known as namespaces.
These namespaces allocate system resources, such as interfaces, to specific namespaces, preventing those resources from being visible in other namespaces of the same type.

> Note that namespaces are referring to Linux namespaces, a Linux kernel feature and have nothing to do with Kubernetes namesapces.

While containers consist of various namespaces, we will concentrate on the network namespace for the purposes of this repository.
Typically each container has its own network namespace.
This isolation ensures that interfaces outside of the container's namespace are not visible within the container's namespace and processes can bind to the same port without conflict.

To facilitate networking, containers employ a specialized device known as a virtual ethernet device (veth).
Veth devices are always created in interconnected pairs, ensuring that packets reaching one end are transmitted to the other, similar to two systems being linked via a cable.

To enable communication between a container and the host system one of the veth interfaces resides within the container's network namespace, while the other resides within the host's network namespace.
This configuration allows seamless communication between the container and the host system.
As a result containers on the same node are able to communicate with each other through the host system.

![Node with two container](node-with-two-container.png)

## How does a CNI work?

Picture a scenario where a user initiates the creation of a Pod and submits the request to the kube-apiserver.
Following the scheduler's determination of the node where the Pod should be deployed, the kube-apiserver contacts the corresponding kubelet.
The kubelet, rather than directly creating containers, delegates this task to a CRI.
The CRI's responsibility encompasses container creation, including the establishment of a network namespace, as previously discussed.
Once this setup is complete, the CRI calls upon a CNI plugin to generate and configure virtual ethernet devices and necessary routes.

![High level dependencies that invoke a CNI](cni-high-level.png)

> Please note that a that CNIs typically do not handle traffic forwarding or load balancing.
> By default, kube-proxy serves as the default network proxy in Kubernetes which utilizes technologies like iptables or IPVS to direct incoming network traffic to the relevant Pods within the cluster.
> However, Cilium offers a superior alternative by loading eBPF programs directly into the kernel, achieving the same tasks with significantly higher speed.
> For more information on this topic see "[What is Kube-Proxy and why move from iptables to eBPF?](https://isovalent.com/blog/post/why-replace-iptables-with-ebpf/)".

## Writing a CNI from scratch

A common misconception suggests that Kubernetes-related components must be coded exclusively in Go.
However, CNI dispels this notion by being language agnostic, focusing solely on defining the interaction between the CRI and a CNI plugin.
The language used is inconsequential, what matters is that the plugin is executable.
To demonstrate this flexibility, we'll develop a CNI plugin using bash.

Before delving into the implementation, let's examine the steps in more detail:

1. Following the CRI's creation of a network namespace, it will load the first file located in `/etc/cni/net.d/`. Therefore, we'll generate a file named `/etc/cni/net.d/10-demystifying.conf`. This file must adhere to a specific JSON structure outlined in the CNI specification. The line `"type": "demystifying"` indicates the presence of an executable file named demystifying, which the CRI will execute in the next step.

![First step](cni-step-1.png)

2. The CRI will search in the directory `/opt/cni/bin/` and execute our CNI plugin, `demystifying`. For that reason we will create our bash script at `/opt/cni/bin/demystifying`. When the CRI invokes a CNI plugin, it passes data to the executable: the JSON retrieved from the previous step is conveyed via STDIN, while details about the container, including the relevant network namespace indicated by `CNI_NETNS`, are conveyed as environment variables.

![Second step](cni-step-2.png)

3. The first task our CNI plugin has to achieve is to create a virtual ethernet device. This action results in the creation of two veth interfaces, which we'll subsequently configure. One of the interfaces will be named `veth_netns` and the other one `veth_host` to make it easier to follow further steps.

![Third step](cni-step-3.png)

4. Next, we'll move one of the veth interfaces, `veth_netns`, into the container's network namespace. This allows for a connection between the container's network namespace and the host's network namespace.

![Fourth step](cni-step-4.png)

5. While the veth interfaces are automatically assigned MAC addresses, they lack an IP address. Typically, each node possesses a dedicated CIDR range, from which an IP address is selected. Assigning an IP to the veth interface inside the container network namespace is what is considered to be the Pod IP. For simplicity, we'll statically set `10.244.0.20` as the IP address and rename the interface based on the `CNI_IFNAME` environment variable. Keep in mind that Pod IPs must be unique in order to not create routing issues further down the line. In reality one would therefore keep track of all assigned IPs, a detail that we are skipping for simplicity reasons.

![Fifth step](cni-step-5.png)

6. The veth interface on the host will receive another IP address, serving as the default gateway within the container's network namespace.We'll statically assign `10.244.0.101` as the IP address. Irrespective of the number of Pods created on the node this IP can stay the same as its sole purpose is to serve as a destination for a route within the container's network namespace.

![Sixth step](cni-step-6.png)

7. Now it is time to add routes. Inside the container's network namespace, we need to specify that all traffic should be routed through `10.244.0.101`, directing it to the host. On the host side all traffic destined for `10.244.0.20` must be directed through `veth_host`. This configuration achieves bidirectional communication between the container and the host.

![Seventh step](cni-step-7.png)

8. Finally, we need to inform the CRI of our actions. To accomplish this, we'll print a JSON via STDOUT containing various details about the configuration performed, including the interfaces and IP addresses created.

![Eighth step](cni-step-8.png)

Now it is time to incorporate the above steps.
The easiest way to follow along is by using the kind setup provided in this repository.
Create a test cluster by executing `make cluster`.

As previously outlined we will now have to create two files on the node.

The first one will be `/etc/cni/net.d/10-demystifying.conf`:
```
{
  "cniVersion": "1.0.0",
  "name": "fromScratch",
  "type": "demystifying"
}
```

The second one being the executable CNI plugin `/opt/cni/bin/demystifying`:
```
#!/usr/bin/env bash

# create veth
VETH_HOST=veth_host
VETH_NETNS=veth_netns
ip link add ${VETH_HOST} type veth peer name ${VETH_NETNS}

# put one of the veth interfaces into the new network namespace
NETNS=$(basename ${CNI_NETNS})
ip link set ${VETH_NETNS} netns ${NETNS}

# assign IP to veth interface inside the new network namespace
IP_VETH_NETNS=10.244.0.20
CIDR_VETH_NETNS=${IP_VETH_NETNS}/32
ip -n ${NETNS} addr add ${CIDR_VETH_NETNS} dev ${VETH_NETNS}

# assign IP to veth interface on the host
IP_VETH_HOST=10.244.0.101
CIDR_VETH_HOST=${IP_VETH_HOST}/32
ip addr add ${CIDR_VETH_HOST} dev ${VETH_HOST}

# rename veth interface inside the new network namespace
ip -n ${NETNS} link set ${VETH_NETNS} name ${CNI_IFNAME}

# ensure all interfaces are up
ip link set ${VETH_HOST} up
ip -n ${NETNS} link set ${CNI_IFNAME} up

# add routes inside the new network namespace so that it knows how to get to the host
ip -n ${NETNS} route add ${IP_VETH_HOST} dev eth0
ip -n ${NETNS} route add default via ${IP_VETH_HOST} dev eth0

# add route on the host to let it know how to reach the new network namespace
ip route add ${IP_VETH_NETNS}/32 dev ${VETH_HOST} scope host

# return a JSON via stdout
RETURN_TEMPLATE='
{
  "cniVersion": "1.0.0",
  "interfaces": [
    {
      "name": "%s",
      "mac": "%s"
    },
    {
      "name": "%s",
      "mac": "%s",
      "sandbox": "%s"
    }
  ],
  "ips": [
    {
      "address": "%s",
      "interface": 1
    }
  ]
}'

MAC_HOST_VETH=$(ip link show ${VETH_HOST} | grep link | awk '{print$2}')
MAC_NETNS_VETH=$(ip -netns $nsname link show ${CNI_IFNAME} | grep link | awk '{print$2}')

RETURN=$(printf "${RETURN_TEMPLATE}" "${VETH_HOST}" "${MAC_HOST_VETH}" "${CNI_IFNAME}" "${mac_netns_veth}" "${CNI_NETNS}" "${CIDR_VETH_NETNS}")
echo ${RETURN}
```

As the CNI plugin must be executable, we'll need to modify the file mode using `chmod +x /opt/cni/bin/demystifying`.
With that, we've constructed an operational CNI.

These steps can be achieved by executing `make cni`.

The next time a Pod is created on the node, it will follow the outlined steps, and our CNI will be invoked.
Once a Pod is started we should see the following:
```
$ kubectl get pods -o wide
NAME            READY   STATUS    RESTARTS   AGE   IP            NODE                             NOMINATED NODE   READINESS GATES
best-app-ever   1/1     Running   0          11s   10.244.0.20   demystifying-cni-control-plane   <none>           <none>
```

As evident, the Pod is running as expected.
Note that the Pod's IP address is `10.244.0.20`, as set by our CNI.
With everything configured correctly, the node can successfully reach the Pod and receive a response:
```
$ curl 10.244.0.20
<html><body><h1>It works!</h1></body></html>
```

To perform such a test we can execute `make test`:
```
$ make test
kubectl apply -f test.yaml
pod/best-app-ever created

------

kubectl get pods -o wide
NAME            READY   STATUS    RESTARTS   AGE   IP            NODE                             NOMINATED NODE   READINESS GATES
best-app-ever   1/1     Running   0          6s    10.244.0.20   demystifying-cni-control-plane   <none>           <none>

------

docker exec demystifying-cni-control-plane curl -s 10.244.0.20
<html><body><h1>It works!</h1></body></html>
```

So far, this demonstrates the simplest deployment of a CNI.
However, modern CNIs are usually deployed as Pods, enabling centralized management and dynamic scaling across cluster nodes.
To illustrate how this can be done, let’s first remove our existing CNI by running `make clean`.

Until now, the CNI setup requires manual steps on every node.
This means that each time a new node is added, the necessary CNI files must be copied onto it manually.
A more scalable approach is to use a Kubernetes DaemonSet, which ensures that each node automatically receives one Pod running the CNI.
This Pod will then copy the required files into each node's appropriate directories, making sure the CNI is installed and ready to use.

![CNI running as DaemonSet](cni-daemonset.png)

To deploy the CNI as a DaemonSet, we first need to create a Docker image containing the necessary files:
```
FROM alpine:3

COPY 10-demystifying.conf /cni/10-demystifying.conf
COPY demystifying /cni/demystifying
COPY entrypoint.sh /cni/entrypoint.sh
RUN chmod +x /cni/demystifying
RUN chmod +x /cni/entrypoint.sh

ENTRYPOINT [/cni/entrypoint.sh]
```

This Dockerfile creates an image with `10-demystifying.conf` and `demystifying` — the same files we used in our previous setup - alongside an `entrypoint.sh` script that will act as the container's entry point.

The entrypoint.sh script executes the following commands when the container starts:
```
#!/usr/bin/env bash

cp /cni/10-demystifying.conf /etc/cni/net.d/
cp /cni/demystifying /opt/cni/bin/
sleep infinity
```

These commands replicate the manual installation steps within the container, copying configuration and executable files to the appropriate directories on each node.

Next, build the Docker image locally:
```
docker build -t demystifying-cni:0.0.1 .
```

In the real world the image would reside in a registry and the node would pull it from there.
Since we built it locally we will have to load the image onto the kind cluster:
```
kind load docker-image demystifying-cni:0.0.1 --name demystifying-cni
```

With the image available on the cluster, we can deploy the DaemonSet:
```
kubectl apply -f cni-daemonset.yaml
```

To automate these steps, you can simply run `make daemonset`.

Finally, test that everything works as expected using the DaemonSet architecture:
```
$ make test
kubectl apply -f test.yaml
pod/best-app-ever created

------

kubectl get pods -o wide
NAME            READY   STATUS    RESTARTS   AGE   IP            NODE                             NOMINATED NODE   READINESS GATES
best-app-ever   1/1     Running   0          5s    10.244.0.20   demystifying-cni-control-plane   <none>           <none>

------

docker exec demystifying-cni-control-plane curl -s 10.244.0.20
<html><body><h1>It works!</h1></body></html>
```

Keep in mind that this setup isn't suitable for production environments and comes with limitations as real-world scenarios require additional steps.
For instance, assigning different IP addresses to the veth interface within the container network namespace and ensuring unique names for the veth interfaces on the host namespace are essential to support multiple Pods.
Additionally, adding network configuration is only one aspect of the tasks a CNI plugin must support.
These tasks are triggered by the CRI setting the `CNI_COMMAND` environment variable to `DEL` or `CHECK` respectively when invoking the CNI plugin.
There are several other tasks, the specific requirements for full compatibility vary across versions and are outlined in the [CNI specification](https://github.com/containernetworking/cni/blob/main/SPEC.md).
Nevertheless, the concepts outlined in this repository hold true regardless of version and offer valuable insights into the workings of a CNI.

## Summary

At the heart of Kubernetes networking lies the Container Network Interface (CNI) specification which defines the exchange between the Container Runtime Interface (CRI) and the executable CNI plugin which resides on every node within the Kubernetes cluster.
While the CRI establishes a container's network namespace, it is the CNI plugin's role to execute intricate network configurations.
These configurations involve creating virtual ethernet interfaces and managing network settings, ensuring seamless connectivity both to and from the newly established container network namespace.

Cilium is as an advanced networking solution adhering to the CNI specification and further elevating the capabilities of Kubernetes networking within complex environments.
