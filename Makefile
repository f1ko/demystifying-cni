CLUSTER_NAME?=demystifying-cni

.PHONY: cluster create init setup start
cluster create init setup start:
	kind create cluster --config kind.yaml --name ${CLUSTER_NAME}
	kubectl delete deploy -n kube-system coredns
	kubectl delete deploy -n local-path-storage local-path-provisioner
	docker exec demystifying-cni-control-plane crictl pull httpd

.PHONY: cni cp copy prepare
cni cp copy prepare:
	docker cp 10-demystifying.conf demystifying-cni-control-plane:/etc/cni/net.d/10-demystifying.conf
	docker cp demystifying demystifying-cni-control-plane:/opt/cni/bin/demystifying
	docker exec demystifying-cni-control-plane chmod +x /opt/cni/bin/demystifying

.PHONY: test
test:
	kubectl apply -f test.yaml
	@sleep 5
	@echo "\n------\n"
	kubectl get pods -o wide
	@echo "\n------\n"
	docker exec demystifying-cni-control-plane curl -s 10.244.0.20

.PHONY: clean clear
clean clear:
	- kubectl delete -f test.yaml
	- docker exec demystifying-cni-control-plane rm /opt/cni/bin/demystifying
	- docker exec demystifying-cni-control-plane rm /etc/cni/net.d/10-demystifying.conf

.PHONY: delete destroy stop
delete destroy stop:
	kind delete cluster --name ${CLUSTER_NAME}
