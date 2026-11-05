#!/usr/bin/env bash
# Check every PrometheusRule in manifests/ with promtool and run the unit tests in
# tests/prometheus/, which feed simulated series to the rules and assert which alerts fire.
#
# Requires: yq (mikefarah v4), promtool.
set -euo pipefail

# promtool reads plain rule files (the "groups" list), which is the spec of a PrometheusRule.
# The tests load them from this fixed path.
rules_dir=".rendered/prometheus-rules"
rm -rf "$rules_dir"
mkdir -p "$rules_dir"

for manifest in manifests/*/*.yaml; do
  [[ "$(yq 'select(.kind == "PrometheusRule") | .kind' "$manifest")" == "PrometheusRule" ]] || continue
  yq 'select(.kind == "PrometheusRule") | .spec' "$manifest" > "$rules_dir/$(basename "$manifest")"
done

promtool check rules "$rules_dir"/*.yaml
promtool test rules tests/prometheus/*.test.yaml
