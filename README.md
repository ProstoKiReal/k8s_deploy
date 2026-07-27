# scripulya_deploy

Unified **local** deployment for the scripulya system — runs
[`scripulya_ai`](../scripulya_ai) (FastAPI backend) and
[`scripulya_agent`](../scripulya_agent) (FastStream LLM worker) together as **one
system**, sharing a single RabbitMQ broker.

Two interchangeable run paths are provided:

| Path | When | Command |
|------|------|---------|
| **Docker Compose** (primary) | Local dev / quick start | `make up` |
| **VPS via GitHub Actions** | Production (prebuilt GHCR images) | "Deploy to VPS" button → [`docs/DEPLOY.md`](docs/DEPLOY.md) |
| **Kubernetes** (target: kind) | Cluster-style / prod rehearsal | `make deploy-kind` |

---

## Architecture

```
                    ┌───────────────────────┐
   HTTP :8000  ───▶ │   scripulya-ai        │  FastAPI backend
   (/docs,          │  (FastAPI, uvicorn)   │  DB = postgres
   /api/v1/*)       └──────────┬────────────┘
                        AMQP   │   publishes LLMRequest  ─┐
                               │   consumes  LLMResult  ◀┘
                               ▼
                    ┌───────────────────────┐
                    │      rabbitmq         │  shared broker
                    │  (3-management)       │  q: llm.agent.request
                    │  mgmt UI :15672       │  q: llm.agent.result
                    └──────────┬────────────┘
                               │   consumes  LLMRequest  ◀┐
                               │   publishes LLMResult  ─┘
                               ▼
                    ┌───────────────────────┐
                    │   scripulya-agent     │  FastStream worker
                    │  (no HTTP port)       │  → Anthropic / Gemini /
                    │                       │    ZAI / DeepSeek
                    └───────────────────────┘

   ┌───────────────────────┐
   │   postgres :5432      │  seeded from ../scripulya_ai/scripts/init.sql
   └───────────────────────┘

   ┌───────────────────────┐
   │   minio :9000/:9001   │  object storage for media (images)
   │   buckets: -public    │  public  -> anonymous URL (no signature)
   │            -private   │  private -> short-lived presigned URL (owner-only)
   └───────────────────────┘
```

The backend delegates **all** real LLM calls to the worker over RabbitMQ. The only
model the backend serves locally (no broker, no provider key) is `testing_mock`.
---

## Prerequisites

- The two source repos checked out as siblings of this one:
  ```
  /home/h3ne58/
  ├── scripulya_ai/
  ├── scripulya_agent/
  └── scripulya_deploy/   ← this repo
  ```
- **Compose path:** Docker + Compose v2.
- **k8s path:** `kubectl` + a local cluster (kind recommended), plus `make`.

## First-time setup

```bash
cp .env.example .env
# edit .env: set JWT_SECRET_KEY (generate one — see the comment in the file).
# Provider keys (ANTHROPIC/GEMINI/ZAI/DEEPSEEK) are OPTIONAL: leave empty to
# disable a provider; the agent still boots and `testing_mock` works offline.
```

---

## Run with Docker Compose (primary)

```bash
make up            # build + start postgres, rabbitmq, scripulya-ai, scripulya-agent
make ps            # status
make logs          # tail all logs (Ctrl-C); or: make logs-ai / make logs-agent
```

Then:

- **API / Swagger UI:** http://localhost:8000/docs  (also http://localhost:8000/openapi.json)
- **RabbitMQ management UI:** http://localhost:15673  (`guest` / `guest`)
  → the `llm.agent.request` queue should show **1 consumer** (the worker). That is
  the end-to-end proof the backend ↔ worker wiring is healthy.
- **Postgres:** `localhost:5432`, db `dbname`, user `user`, password `password`.
- **MinIO console:** http://localhost:9001  (`minioadmin` / `minioadmin`) — browse
  the `scripulya-public` / `scripulya-private` buckets (created by the backend on
  first upload). The S3 API at `:9000` is what mobile/web clients hit via the
  presigned/public image URLs returned by `GET/POST /api/v1/media`.

Other targets: `make down`, `make restart`, `make reseed` (wipe + re-seed DB),
`make mock-up` (optional mock — see below).

### Seeding / re-seeding Postgres (compose)

`../scripulya_ai/scripts/init.sql` is mounted into Postgres'
`/docker-entrypoint-initdb.d`, so the schema + test data load **only on first init**
of the data volume. To force a re-seed:

```bash
make reseed        # docker compose down -v && up  (wipes ALL DB data)
```

---

## Deploy to a VPS via GitHub Actions (production)

For a real server, use the **"Deploy to VPS"** button (this repo's **Actions**
tab). It pulls the prebuilt GHCR images onto the VPS over an ephemeral WireGuard
tunnel and writes `.env` from **GitHub Secrets** — nothing sensitive is ever
committed, and the VPS needs no source checkout.

Full one-time setup (publishing the GHCR packages, adding the WireGuard peer,
installing the SSH key, and the **complete secret list**) lives in
**[docs/DEPLOY.md](docs/DEPLOY.md)**.

You can run the same prod stack by hand on the VPS: `make prod-up` ·
`make prod-logs` · `make prod-ps` · `make prod-down`.

---

## Run on a local Kubernetes cluster (kind)

`kind` has no registry, so images are built locally and loaded into the node
(`imagePullPolicy: Never`).

### Create the cluster (one-time)

Create a cluster that exposes the API NodePort to the host:

```bash
cat > /tmp/kind-scripulya.yaml <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080   # scripulya-ai NodePort
        hostPort: 8000
YAML
kind create cluster --name scripulya --config /tmp/kind-scripulya.yaml
```

(Without `extraPortMappings`, reach the API via `make pf` port-forward instead.)

### Deploy

```bash
make deploy-kind   # build images → load into kind → gen secret + init.sql → apply
make status        # kubectl get pods,svc  (wait until all are Running/Ready)
```

Access:

- **API:** http://localhost:8000/docs (via the NodePort mapping above), **or** `make pf`.
- **RabbitMQ mgmt UI:** `make pf` (forwards both), then http://localhost:15673.

### Seeding / re-seeding Postgres (k8s)

`init.sql` is applied only on **first** PVC init (when the data dir is empty).
Re-applying manifests will **not** re-run it. To force a re-seed:

```bash
# Option A — fresh init (drops ALL data):
kubectl -n scripulya delete pod postgres-0
kubectl -n scripulya delete pvc data-postgres-0
kubectl -n scripulya delete pod postgres-0   # StatefulSet recreates PVC + re-inits

# Option B — re-run the (idempotent) SQL against the existing DB:
kubectl -n scripulya exec -it postgres-0 -- \
  psql -U user -d dbname -f /docker-entrypoint-initdb.d/init.sql
```

### Optional: Ingress

`make apply-ingress` routes `scripulya.local` → the API (needs an ingress controller
such as ingress-nginx on kind / Traefik on k3d — change `ingressClassName` in
`k8s/30-ingress.yaml` accordingly). Add `scripulya.local` → the kind node IP in
`/etc/hosts`.

### Free the kind cluster's host ports (keep the cluster)

A running kind cluster holds host ports — the API NodePort mapping (`:8000`),
the API server port, etc. — which clashes with `make up` or other local
services. **Stop** the cluster to release them without losing anything (pods, DB
data all survive; bring it straight back with `kind-start`):

```bash
make kind-stop     # docker-stop the kind node(s): frees ports, keeps state
make kind-start    # bring a stopped cluster back up
```

### Teardown

```bash
make delete        # deletes the whole namespace (loses DB data)
make kind-delete   # delete the kind cluster too (frees its host ports; all state lost)
```

---

## How the two run paths stay in sync (DRY)

- **One `.env`** is the single source of secrets/tunables.
- Compose reads it directly (`${VAR}`).
- k8s reads it once via `make gen-secrets` → the `scripulya-secrets` Secret; the
  `scripulya-config` ConfigMap holds the non-secret values.
- The **queue names** (`llm.agent.request` / `llm.agent.result`) and the
  **`RABBIT_URL`** are a contract between the two apps and are written literally in
  both `docker-compose.yml` and `k8s/01-configmap.yaml`. Keep them in sync if you
  ever change them.

## How the worker is health-checked in k8s

The worker has **no HTTP port**, so a normal probe won't work. Its
liveness/readiness probe is an exec probe (stdlib `urllib` only — no `curl`, no
image patch, no sidecar) that calls the RabbitMQ **management API** and asserts a
consumer is bound to `llm.agent.request`. i.e. it proves the worker is actually up
*and subscribed*. An initContainer first waits for the broker to be reachable.

## Optional: mock-google-api

The backend **never** calls `generativelanguage.googleapis.com` (verified in
source), so the mock is **off by default**. It only matters if you want to run the
**worker's** Google/Gemini provider offline.

- **Compose:** `make mock-up` (adds a container aliased as
  `generativelanguage.googleapis.com`).
- **k8s:** opt-in — see `k8s/mock-google/`. Requires a CoreDNS hosts override
  (`k8s/mock-google/coredns-hosts-patch.yaml`) because Service names can't contain
  dots.

## Media (images via MinIO)

Images (character avatars, scene backgrounds, user profile pictures, …) live in
MinIO and are exposed through the backend's media API:

- `POST /api/v1/media` (multipart: `file`, `entity_type`, `entity_id`, `is_public`)
  — upload an image. `is_public=true` lands it in the anonymous-read bucket;
  `is_public=false` in the presigned-only bucket.
- `GET /api/v1/media/{id}` — metadata + a `url` (stable public URL, short-lived
  presigned URL, or the legacy external `file_url`). Public assets are reachable
  anonymously; private assets only by their owner.
- `GET /api/v1/media?entity_type=&entity_id=` — list media for an entity.
- `DELETE /api/v1/media/{id}` — owner only.

Clients fetch the image **bytes directly from MinIO** using the returned `url`;
the backend never streams image bytes. The buckets (`scripulya-public` /
`scripulya-private`) are created by the backend at startup (and lazily on first
upload).

`MINIO_PUBLIC_ENDPOINT` is load-bearing — it is the host embedded in every image
URL and **must be reachable from the client**. It differs per run path:

| Path | `MINIO_PUBLIC_ENDPOINT` |
|------|-------------------------|
| Compose | `localhost:9000` |
| k8s (kind, NodePort 30900) | `localhost:30900` (needs a kind `extraPortMapping` for `containerPort: 30900`, or `make pf`) |
| prod | real public DNS for the MinIO API |

Set it wrong and every image URL 404s (presigned `Host` mismatch / unreachable).

## Troubleshooting

- **`bind: address already in use` on start:** a host service already owns that
  port. The broker's AMQP port (5672) is kept internal for this reason; the
  management UI defaults to host port **15673** (not 15672) to avoid clashing with
  a host-installed RabbitMQ. Override any host port in `.env`: `AI_PORT`,
  `RABBIT_MGMT_PORT`. If port **8000** is held by a leftover kind cluster, free it
  with `make kind-stop` (or `make kind-delete`).
- **Worker shows 0 consumers / `llm.agent.request` missing:** the worker only
  declares the queue once it connects. Check `make logs-agent` for the `agent up`
  line and confirm RabbitMQ is healthy. With empty provider keys the worker still
  connects and consumes — empty keys only disable per-provider LLM calls.
- **RabbitMQ rejects `guest` from other pods/containers:** the `rabbitmq.conf`
  mounted in k8s sets `loopback_users.guest = false`. In Compose, Docker bridge DNS
  normally allows it; if not, set a non-guest user and update `RABBIT_URL`.
- **Postgres "no such table":** the DB wasn't (re-)initialized. The init script
  only runs on a fresh volume — see the re-seed steps above.
- **Images 404 / `SignatureDoesNotMatch`:** the `url` was built with a
  `MINIO_PUBLIC_ENDPOINT` the client cannot reach, or that differs from the host
  MinIO actually serves on. Set it to the client-facing host (compose
  `localhost:9000`, k8s NodePort `localhost:30900`, prod DNS) in `.env` (compose)
  / the `scripulya-config` ConfigMap (k8s) and restart the backend.
- **MinIO buckets missing / uploads fail:** the backend creates the buckets
  lazily on first upload and best-effort at startup. Check the backend logs for a
  MinIO connection error and confirm the `minio` container/pod is healthy.
- **`make deploy-kind` images not found / `ImagePullBackOff`:** images must be
  loaded into kind first (`make load-kind` is part of `deploy-kind`); confirm
  `imagePullPolicy: Never` is set (it is) and the kind cluster you loaded into is
  the active context (`kubectl config current-context`).
- **k8s apply errors with no cluster:** the workload manifests need a real cluster;
  they are not meant to be applied without one. Use the Compose path for a no-k8s
  local run.

---

## Repository layout

```
scripulya_deploy/
├── docker-compose.yml        # PRIMARY: unified local stack (builds from siblings)
├── docker-compose.prod.yml   # PROD override: pull GHCR images, local init.sql
├── .env.example              # placeholder secrets (single source for all paths)
├── Makefile                  # compose + prod + kind targets
├── .github/workflows/        # deploy.yml — the "Deploy to VPS" button
├── docs/DEPLOY.md            # VPS deploy setup guide + full secret list
├── k8s/                      # portable manifests (namespace, config, secret example,
│   │                           postgres/rabbit StatefulSets, ai/agent Deployments,
│   │                           optional ingress, optional mock-google)
└── scripts/                  # deploy-vps.sh, gen-secrets.sh, gen-init-sql-cm.sh,
                               # load-images-kind.sh, kind-power.sh, port-forward.sh
```
