CLUSTER_NAME := homelab
ARGOCD_VERSION := v3.5.5

.PHONY: up destroy status argocd-ui argocd-password

up:
	kind create cluster --name $(CLUSTER_NAME) --config bootstrap/kind-config.yaml
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
	kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
	kubectl apply -f bootstrap/root-app.yaml

destroy:
	kind delete cluster --name $(CLUSTER_NAME)

status:
	kubectl get nodes
	kubectl get applications -n argocd
	kubectl get pods -A

argocd-ui:
	kubectl port-forward svc/argocd-server -n argocd 8080:443

argocd-password:
	argocd admin initial-password -n argocd
