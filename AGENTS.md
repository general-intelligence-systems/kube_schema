# Schema Generation

All scripts are orchestrated by `bin/run`, which calls them in numbered order.

## Approach 1: Kubernetes Core Swagger Download (`bin/01-download`)

**Language:** Ruby

Downloads pre-built OpenAPI v2 (Swagger) JSON files for multiple Kubernetes versions from the `kubernetes-sigs/reference-docs` GitHub repo. Also fetches `kubectl.yaml` and API group metadata.

- **Source:** `https://raw.githubusercontent.com/kubernetes-sigs/reference-docs/.../swagger.json`
- **Versions:** v1.19, v1.20, v1.21, v1.31–v1.35
- **Output:** `data/k8s.io/{version}.json`, `data/kubectl.yaml`, `data/api-groups.yaml`

## Approach 2: CRD YAML Download + k3s OpenAPI Extraction (`bin/03-download-crds` + `bin/03-download-helm-crds` + `bin/04-get-crd-json`)

**Language:** Ruby (03, 03-helm), Bash (04)

Three-phase approach for third-party CRD schemas (Gateway API, Argo, cert-manager, External Secrets, agentgateway, etc.):

1. **`bin/03-download-crds`** — Reads URLs from `data/crd-list.yaml` and downloads all CRD YAML manifests using async HTTP. Concatenates them into a single file.
2. **`bin/03-download-helm-crds`** — Reads Helm chart references from `data/helm-crd-list.yaml` and renders each via `helm template`. Appends the rendered CRD YAML to the same combined file. This is needed for projects like agentgateway that distribute CRDs exclusively as OCI Helm charts rather than raw YAML manifests.
3. **`bin/04-get-crd-json`** — Spins up a k3s cluster via Docker Compose, captures the baseline OpenAPI v2 definition list, applies all downloaded CRDs, captures the post-apply definition list, then diffs the two to isolate CRD-only schemas.

- **CRD list (raw YAML):** `data/crd-list.yaml`
- **CRD list (Helm charts):** `data/helm-crd-list.yaml`
- **Intermediate outputs:** `data/crds/00-all-crds.yaml`, `data/crds/01-k8s-definitions-list.txt`, `data/crds/02-full-schema.json`, `data/crds/03-crds-definitions-list.txt`, `data/crds/04-crd-only-definitions-list.txt`
- **Final output:** `data/crds/05-crd-only-definitions.json`

To add a new CRD source, either append its raw YAML URL to `data/crd-list.yaml`, or if the CRDs are only available as a Helm chart, add an entry to `data/helm-crd-list.yaml`.

## Approach 3: Aggregated API Server Swagger — Loft/vCluster (`bin/05-download-loft-schemas`)

**Language:** Bash + jq

Loft (vCluster Platform) types are served via an aggregated API server, not regular CRDs, so they can't be extracted by applying CRD YAMLs to k3s. Instead, the full Loft swagger.json is downloaded from GitHub and processed in three passes:

1. **Pass 1:** Find seed definitions — those with `x-kubernetes-group-version-kind` annotations where the group matches `*.loft.sh`.
2. **Pass 2:** Iteratively resolve transitive `$ref` dependencies until no new definitions are discovered.
3. **Pass 3:** Extract the full closure of definitions into the output file.

- **Source:** `https://raw.githubusercontent.com/loft-sh/loft/master/api/openapi-spec/swagger.json`
- **Output:** `data/crds/07-loft-definitions.json`

## Approach 4: Aggregated API Server Swagger — KubeVirt (`bin/06-download-kubevirt-schemas`)

**Language:** Bash + jq

Like Loft, KubeVirt types are served via an aggregated API server. The approach is simpler because KubeVirt's swagger lacks `x-kubernetes-group-version-kind` annotations. Instead, definitions are filtered by prefix: everything **not** starting with `k8s.io.` is kept as a KubeVirt-native type.

- **Source:** `https://raw.githubusercontent.com/kubevirt/kubevirt/refs/heads/main/api/openapi-spec/swagger.json`
- **Output:** `data/crds/08-kubevirt-definitions.json`

## Retired Scripts (`bin/old/`)

These scripts are no longer called by `bin/run`.

- **`bin/old/02-extract-schemas`** — Split core Kubernetes swagger JSON into individual per-GVK files organized as `data/k8s.io/{version}/{group}/{version}/{kind}.json`. Disabled (has `exit` at line 3).
- **`bin/old/05-extract-schemas`** — Split CRD swagger JSON into individual per-GVK files organized as `data/crds/{group}/{version}/{kind}.json`. Filtered definitions by matching groups from a CRD list file.
