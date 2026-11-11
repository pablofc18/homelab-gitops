CLUSTER_NAME := homelab
# age private key used by sops-secrets-operator to decrypt SopsSecrets. Never commit it.
SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt

.PHONY: up destroy status argocd-ui argocd-password sops-key lint validate scan test-rules

up:
	kind create cluster --name $(CLUSTER_NAME) --config bootstrap/kind-config.yaml
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	# Same manifests that apps/argocd.yaml keeps in sync afterwards (ArgoCD manages itself).
	kubectl apply --server-side -k manifests/argocd
	kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
	$(MAKE) sops-key
	kubectl apply -f bootstrap/root-app.yaml

# The "secret zero": the only secret not managed from Git. Server-side apply avoids
# copying the key into a last-applied-configuration annotation.
sops-key:
	@test -f $(SOPS_AGE_KEY_FILE) || { echo "age key not found at $(SOPS_AGE_KEY_FILE), see README (Secrets)"; exit 1; }
	kubectl create namespace sops-secrets-operator --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic sops-age-key -n sops-secrets-operator \
		--from-file=keys.txt=$(SOPS_AGE_KEY_FILE) --dry-run=client -o yaml \
		| kubectl apply --server-side --field-manager=make-sops-key -f -

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

lint:
	yamllint --strict .

validate:
	./scripts/validate-manifests.sh

scan:
	RENDER_DIR=.rendered ./scripts/validate-manifests.sh
	trivy config --skip-version-check --exit-code 1 --severity HIGH,CRITICAL --ignorefile .trivyignore.yaml .rendered/manifests

test-rules:
	./scripts/test-prometheus-rules.sh
