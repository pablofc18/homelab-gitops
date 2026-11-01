# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project purpose

`homelab-gitops` is a **personal learning project**: a local Kubernetes homelab managed with GitOps. The goal is to learn (and demonstrate) the whole DevOps / platform engineering toolbox: Kubernetes, ArgoCD, Helm, ingress, TLS, observability, secrets management, CI, supply-chain security, and later IaC (Terraform, Ansible).

Because the goal is learning, **explaining matters as much as the result**:

- Explain *why* a change is made, not just what. Mention the underlying concept (reconciliation loop, taints/tolerations, hostPort vs LoadBalancer, etc.) when relevant.
- Prefer the idiomatic / production-like approach over a shortcut, and say when a shortcut is kind-specific.
- Offer small, incremental steps the owner can follow and understand. Don't scaffold large amounts of config at once.
- The owner talks to you in Spanish; reply in Spanish. Repository content (docs, comments, commit messages, YAML) is written in **English**.

## Core principle: Git is the source of truth

- Anything running in the cluster must be declared in this repo. **Never** fix things with `kubectl apply/edit/patch` against ArgoCD-managed resources: `selfHeal` will revert it, and it breaks the GitOps lesson.
- Deploying = commit + push to `main`. ArgoCD pulls and syncs (polls roughly every 3 min).
- The cluster is disposable: `make destroy && make up` must always rebuild everything from Git.
- Never commit secrets in plain text (the repo is public). Secrets go in Git as `SopsSecret` resources in `manifests/<app>/*.sops.yaml`, encrypted with `sops -e -i` (rules in `.sops.yaml`, only `data`/`stringData` values are encrypted) and decrypted in-cluster by sops-secrets-operator. Always check a `*.sops.yaml` file is encrypted (has a `sops:` block and `ENC[...]` values) before committing; `scripts/validate-manifests.sh` also fails on any unencrypted one. Never print decrypted values or Secrets (`-o yaml`, `-o json`, go-templates/jsonpath errors dump the whole object); to verify, extract one field and pipe it to a command that does not echo it. Reference example: `manifests/whoami/whoami-test-secret.sops.yaml`. The age private key (`~/.config/sops/age/keys.txt`) is loaded by `make up` / `make sops-key` and is never committed.

## Repository layout

| Path | Purpose |
|---|---|
| `bootstrap/kind-config.yaml` | kind cluster definition (1 control-plane labelled `ingress-ready=true` + 2 workers, host ports 80/443 mapped). Not a K8s resource; applied by `make up`. |
| `bootstrap/root-app.yaml` | ArgoCD `root` Application (app-of-apps), watches `apps/` on `main`. Applied once by `make up`. |
| `apps/` | **One ArgoCD `Application` per file**, each is picked up automatically by `root`. |
| `manifests/<app>/` | Raw manifests / extra values referenced by an app in `apps/`. |
| `docs/architecture.md` | Detailed design, flows, trade-offs. |
| `Makefile` | `up`, `destroy`, `status`, `argocd-ui`, `argocd-password`. |

Current state: `apps/traefik.yaml`, `apps/cert-manager.yaml` (controller and CRDs) and `apps/cert-manager-issuers.yaml` (local CA: `selfsigned` → `homelab-ca` Certificate → `homelab-ca` ClusterIssuer, manifests in `manifests/cert-manager-issuers/`) and `apps/whoami.yaml` (smoke test for ingress + TLS at `https://whoami.localhost`; use `manifests/whoami/` as the reference for plain manifests: pinned image digest, restricted securityContext, resources, `cert-manager.io/cluster-issuer` annotation on the Ingress) and `apps/kube-prometheus-stack.yaml` (Prometheus, Alertmanager, node-exporter, kube-state-metrics and Grafana at `https://grafana.localhost` in namespace `monitoring`; Grafana uses a namespaced Role, so its dashboards must be ConfigMaps in `monitoring`; kind-unreachable control-plane targets disabled) and `apps/monitoring.yaml` (own resources for the monitoring stack in `manifests/monitoring/`: the Grafana admin `SopsSecret` and dashboards as ConfigMaps labelled `grafana_dashboard: "1"`, e.g. `dashboard-traefik-services.yaml` with per-service SLIs from Traefik metrics, and `PrometheusRule`s labelled `release: kube-prometheus-stack`, e.g. `slo-availability.yaml` with burn-rate alerts) and `apps/sops-secrets-operator.yaml` (decrypts `SopsSecret`s with the age key from Secret `sops-age-key`) and `apps/vaultwarden.yaml` (first stateful app at `https://vaultwarden.localhost`; use `manifests/vaultwarden/` as the reference for stateful apps: single-replica StatefulSet on a PVC declared in Git, admin token as an Argon2id hash in a `SopsSecret`, signups closed; test data only, no backups yet) and `apps/gitea.yaml` (Gitea chart at `https://gitea.localhost` with SQLite instead of the chart's PostgreSQL HA/Valkey defaults, `strategy: Recreate`, HTTPS clone only) with its companion `apps/gitea-secrets.yaml` (admin `SopsSecret` in `manifests/gitea-secrets/`). Traefik redirects all HTTP to HTTPS on the `web` entrypoint, so every new Ingress needs TLS. `apps/` must only contain apps that are really deployed: add a file when the app is implemented, not as a placeholder.

## Conventions

### Adding a service
1. Create `apps/<name>.yaml` as an ArgoCD `Application` in namespace `argocd`, `project: default`.
2. Third-party software → Helm chart via `source.repoURL` + `chart` + `targetRevision`. Own manifests/values → `path: manifests/<name>` in this repo.
3. Destination `https://kubernetes.default.svc`, with its own namespace.
4. Use the same `syncPolicy` as the existing apps:
   ```yaml
   syncPolicy:
     automated:
       prune: true
       selfHeal: true
     syncOptions:
       - CreateNamespace=true
   ```
   Exception: an app that uses CRDs installed by another app also adds `SkipDryRunOnMissingResource=true` and a `retry` policy (see `apps/cert-manager-issuers.yaml`), because `root` syncs all apps at once.
5. Update the README roadmap / `docs/architecture.md` when the change is architecturally meaningful.

Use `apps/traefik.yaml` as the reference template.

### Versions
- **Pin everything**: Helm `targetRevision` must be an exact version, never `*`, `latest` or a range. Container images too (tag, ideally digest).
- Renovate (`renovate.json`) opens PRs for version bumps: Helm charts in `apps/` (argocd manager), container images in `manifests/` (kubernetes manager, tag + digest), GitHub Actions (pinned to digests) and any variable annotated with a `# renovate: datasource=... depName=...` comment in the `Makefile` or `scripts/*.sh` (e.g. `ARGOCD_VERSION`, CI tool versions). When adding a new pinned version outside those managers, add the annotation so it stays covered.

### kind-specific choices (document them as such)
- No cloud LoadBalancer: Traefik uses `service.spec.type: ClusterIP`, `hostPort` 80/443, `nodeSelector: ingress-ready=true` and a control-plane toleration.
- If a new component needs external access, route it through Traefik with an Ingress/IngressRoute rather than adding new host port mappings (changing `kind-config.yaml` requires recreating the cluster).
- Ingress controller is Traefik, **not** ingress-nginx (retired March 2026). Don't suggest switching back.

### Style
- YAML: 2-space indent, no tabs, one resource per file where practical, kebab-case names.
- Commits: Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`), short English subject, as in the existing history.
- Keep `README.md` (usage, roadmap) and `docs/architecture.md` (design) in sync with reality.

## Common commands

```bash
make up                 # create kind cluster, install ArgoCD, apply root app
make status             # nodes, ArgoCD applications, all pods
make argocd-password    # initial admin password
make sops-key           # load the local age private key into the cluster (also run by make up)
make argocd-ui          # port-forward UI to https://localhost:8080
make destroy            # delete the cluster
curl -i http://localhost    # expect 308 redirect to https (port 80 only redirects)
curl -ik https://localhost  # expect 404 from Traefik for unknown hosts
curl --cacert homelab-ca.crt https://whoami.localhost  # TLS end to end (CA from Secret homelab-ca in cert-manager)
```

Read-only inspection is always fine (`kubectl get/describe/logs`, `argocd app get`, `helm template`, `helm show values`). Before running anything that mutates the cluster or the host (`make up`, `make destroy`, `docker`/`kind` operations), say what it will do. `make destroy` is cheap but loses all in-cluster state.

## Validating changes (before pushing)

CI (`.github/workflows/lint.yaml`) runs on every PR and push to `main`; all three jobs are required checks on `main` (ruleset `protect_main`, branches must be up to date before merging):

- `yamllint`: `yamllint --strict` with the rules in `.yamllint`.
- `kubeconform`: `scripts/validate-manifests.sh` first fails on any unencrypted `manifests/**/*.sops.yaml`, then validates the Applications against the ArgoCD CRD schema, renders every Helm-based app with `helm template` (same chart, version and inline values ArgoCD uses), bundles every `path` app from `manifests/` into one file, and validates the output with `kubeconform -strict`. Custom resources are validated with schemas from the datreeio CRDs-catalog. CRD definitions are skipped (no upstream schema).
- `trivy`: scans the same rendered manifests with `trivy config` and fails on HIGH/CRITICAL findings. Accepted risks live in `.trivyignore.yaml`, each scoped to one app's rendered file and with a `statement` explaining why. Never add an ignore without that justification; prefer fixing the values.

Tool versions for CI are pinned in `scripts/ci-install-tools.sh` (Trivy is installed as a checksum-verified binary, not via a third-party action).

Run the same checks locally before pushing (needs `helm`, `yq` v4, `kubeconform`, `trivy`):

```bash
make lint       # or: uvx yamllint@1.37.1 --strict .
make validate
make scan
```

If you add an app whose source type the script does not handle, extend the script so it stays covered.

After pushing, confirm with `make status` / the ArgoCD UI that the app is `Synced` and `Healthy`.

## Roadmap (what's next)

CI (`yamllint`, `kubeconform`, Trivy) → Renovate → cert-manager (TLS) → kube-prometheus-stack (Prometheus/Alertmanager) → SOPS + age secrets → Grafana (ingress + credentials from SOPS) → first real apps: Vaultwarden (done), Gitea (done); backups for stateful apps postponed by the owner (don't propose them as the next step unless asked) → dashboards/alerts/SLOs → phase 2: multi-VM k3s with Terraform (libvirt) + Ansible, reusing this GitOps repo.

When asked "what should I do next", follow this order and explain the reasoning for the next step.

## Things to avoid

- Don't apply cluster changes imperatively and leave them undeclared in Git.
- Don't commit secrets, tokens, kubeconfigs or age private keys.
- Don't use unpinned versions.
- Don't push to `main`, force-push, or rewrite history without the owner asking.
- Don't over-engineer: this is a single-user local lab. Prefer the simplest setup that teaches the concept.
