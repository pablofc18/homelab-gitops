#!/usr/bin/env bash
# Render every ArgoCD Application in apps/ the way ArgoCD would and validate
# the result against Kubernetes (and CRD) JSON schemas with kubeconform.
#
# Requires: helm, yq (mikefarah v4), kubeconform.
set -euo pipefail

KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.37.0}"
REPO_URL="https://github.com/pablofc18/homelab-gitops"

kubeconform_args=(
  -strict
  -summary
  -kubernetes-version "$KUBERNETES_VERSION"
  # The upstream schema repo has no schema for CRD definitions themselves.
  # They ship unmodified with third-party charts, so skipping them loses little.
  -skip CustomResourceDefinition
  -schema-location default
  # Community schemas for CRDs (ArgoCD Application, Traefik IngressRoute, ...).
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

failed=0

validate() {
  local label="$1"; shift
  echo "::group::$label"
  if ! kubeconform "${kubeconform_args[@]}" "$@"; then
    echo "::error::$label failed validation"
    failed=1
  fi
  echo "::endgroup::"
}

# 1. The Application objects themselves.
validate "Applications" bootstrap/root-app.yaml apps/

# 2. What each Application deploys.
for app in apps/*.yaml; do
  name="$(yq '.metadata.name' "$app")"
  repo="$(yq '.spec.source.repoURL' "$app")"
  chart="$(yq '.spec.source.chart // ""' "$app")"
  path="$(yq '.spec.source.path // ""' "$app")"
  namespace="$(yq '.spec.destination.namespace // "default"' "$app")"

  if [[ -n "$chart" ]]; then
    version="$(yq '.spec.source.targetRevision' "$app")"
    values="$workdir/$name-values.yaml"
    # Inline values can be a string (helm.values) or an object (helm.valuesObject).
    yq '.spec.source.helm.values // ""' "$app" > "$values"
    yq '.spec.source.helm.valuesObject // {}' "$app" > "$workdir/$name-values-object.yaml"

    rendered="$workdir/$name.yaml"
    helm template "$name" "$chart" \
      --repo "$repo" --version "$version" --namespace "$namespace" \
      --include-crds \
      -f "$values" -f "$workdir/$name-values-object.yaml" > "$rendered"
    validate "$name (chart $chart@$version)" "$rendered"

  elif [[ "${repo%.git}" == "$REPO_URL" && -n "$path" ]]; then
    validate "$name (path $path)" "$path"

  else
    echo "::warning::$name: source not supported by this script, skipped"
  fi
done

exit "$failed"
