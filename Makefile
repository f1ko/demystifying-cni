CLUSTER_NAME?=demystifying-cni

.PHONY: cluster create init setup start up
cluster create init setup start up:
	kind create cluster --config kind.yaml --name ${CLUSTER_NAME}
	kubectl delete deploy -n kube-system coredns
	kubectl delete deploy -n local-path-storage local-path-provisioner
	docker exec demystifying-cni-control-plane crictl pull httpd > /dev/null

.PHONY: cni cp copy
cni cp copy:
	docker cp 10-demystifying.conf demystifying-cni-control-plane:/etc/cni/net.d/10-demystifying.conf
	docker cp demystifying demystifying-cni-control-plane:/opt/cni/bin/demystifying
	docker exec demystifying-cni-control-plane chmod +x /opt/cni/bin/demystifying

.PHONY: daemonset ds
daemonset ds:
	docker build -t demystifying-cni:0.0.1 .
	kind load docker-image demystifying-cni:0.0.1 --name demystifying-cni
	kubectl apply -f cni-daemonset.yaml

.PHONY: test
test:
	kubectl apply -f test.yaml
	@sleep 5
	@echo "\n------\n"
	kubectl get pods -o wide
	@echo "\n------\n"
	docker exec demystifying-cni-control-plane curl -m 5 -s 10.244.0.20

.PHONY: bpf-prepare
bpf-prepare:
	docker exec demystifying-cni-control-plane apt update -y > /dev/null
	docker exec demystifying-cni-control-plane apt install -y clang llvm libbpf-dev libelf-dev gcc make > /dev/null
	docker exec demystifying-cni-control-plane ln -s /usr/include/aarch64-linux-gnu/asm /usr/include/asm || true

.PHONY: bpf-compile
bpf-compile: bpf-prepare
	docker cp bpf_xdp.c demystifying-cni-control-plane:/root/bpf_xdp.c
	docker exec demystifying-cni-control-plane clang -O2 -g -target bpf -Wall -c /root/bpf_xdp.c -o /root/bpf_xdp.o

.PHONY: bpf-unload bpf-clean
bpf-unload bpf-clean:
	- docker exec demystifying-cni-control-plane ip link set dev veth_host xdp off

.PHONY: bpf-load
bpf-load: bpf-unload bpf-compile
	docker exec demystifying-cni-control-plane ip link set dev veth_host xdp obj /root/bpf_xdp.o sec xdp

.PHONY: clean clear
clean clear: bpf-unload
	- kubectl delete -f test.yaml --ignore-not-found
	- docker exec demystifying-cni-control-plane rm /opt/cni/bin/demystifying
	- docker exec demystifying-cni-control-plane rm /etc/cni/net.d/10-demystifying.conf
	- kubectl delete -f cni-daemonset.yaml --ignore-not-found

.PHONY: delete destroy down stop
delete destroy down stop:
	kind delete cluster --name ${CLUSTER_NAME}
