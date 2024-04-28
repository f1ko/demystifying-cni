CLUSTER_NAME?=demystifying-cni

.PHONY: cluster create init setup start
cluster create init setup start:
	kind create cluster --config kind.yaml --name ${CLUSTER_NAME}
	kubectl delete deploy -n kube-system coredns
	kubectl delete deploy -n local-path-storage local-path-provisioner

.PHONY: delete destroy stop
delete destroy stop:
	kind delete cluster --name ${CLUSTER_NAME}
