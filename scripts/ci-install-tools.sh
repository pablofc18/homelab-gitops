#!/usr/bin/env bash
# Install pinned CLI tools for CI into $HOME/bin and add it to the job PATH.
# Usage: ci-install-tools.sh helm yq kubeconform trivy
set -euo pipefail

HELM_VERSION=v4.2.2
YQ_VERSION=v4.54.1
KUBECONFORM_VERSION=v0.8.0
TRIVY_VERSION=0.75.0

bin="$HOME/bin"
mkdir -p "$bin"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for tool in "$@"; do
  case "$tool" in
    helm)
      curl -sSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
        | tar xz -C "$bin" --strip-components=1 linux-amd64/helm
      ;;
    yq)
      curl -sSL -o "$bin/yq" \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
      chmod +x "$bin/yq"
      ;;
    kubeconform)
      curl -sSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
        | tar xz -C "$bin" kubeconform
      ;;
    trivy)
      # Trivy's release pipeline was compromised in March 2026: install the binary
      # directly (no third-party action) and verify it against the release checksums.
      archive="trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
      base="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}"
      curl -sSL -o "$tmp/$archive" "$base/$archive"
      curl -sSL -o "$tmp/checksums.txt" "$base/trivy_${TRIVY_VERSION}_checksums.txt"
      (cd "$tmp" && grep " ${archive}\$" checksums.txt | sha256sum -c -)
      tar xzf "$tmp/$archive" -C "$bin" trivy
      ;;
    *)
      echo "unknown tool: $tool" >&2
      exit 1
      ;;
  esac
done

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$bin" >> "$GITHUB_PATH"
fi
