# Deploy to a VPS via GitHub Actions

This is the **production** run path: a "Deploy to VPS" button in this repo's
**Actions** tab that ships the latest prebuilt images to your VPS over an
ephemeral WireGuard tunnel and restarts the stack. It builds nothing on the VPS
and commits no secrets — every sensitive value lives in **GitHub Secrets**.

```
 GitHub Actions runner                          Your VPS
 ┌───────────────────────────┐   WireGuard     ┌────────────────────────────┐
 │ publish.yml (ai, agent)   │ ◀── tunnel ───▶ │  docker compose            │
 │   → pushes images to GHCR │   (ephemeral)   │   -f docker-compose.yml    │
 │                           │                 │   -f docker-compose.prod.yml│
 │ deploy.yml (the button)   │   SSH over WG   │   pull && up -d            │
 │   → rsync + ssh + .env    │ ──────────────▶ │  scripulya-ai / -agent     │
 │   → deploy-vps.sh         │                 │  + pg / rabbit / minio /   │
 └───────────────────────────┘                 │    redis / falkordb        │
                                                └────────────────────────────┘
```

The two source images are published by their own repos:

- `scripulya_ai` (`dreamescape_ai`) → `ghcr.io/scripulya-ai-roleplay/scripulya-ai`
- `scripulya_agent` (`llm_api_agent`) → `ghcr.io/scripulya-ai-roleplay/scripulya-agent`

Each is tagged `latest` and `sha-<7>` on every push to `master`.

---

## Prerequisites on the VPS

- Docker **+ Compose v2** (`docker compose version` ≥ 2.24 — the prod override
  relies on modern compose merge behavior).
- A non-root **deploy user** that can run `docker` without `sudo`:
  ```bash
  sudo useradd -m -s /bin/bash deploy
  sudo usermod -aG docker deploy
  ```
- A **WireGuard server already running** on the VPS (you said it's set up).
- The VPS's SSH must be reachable **from inside the WireGuard tunnel** (i.e. sshd
  listens on the VPS's WireGuard IP, or on `0.0.0.0`). The public SSH port can
  stay firewalled — the deploy only ever uses the tunnel.

You do **not** need the `scripulya_ai` / `scripulya_agent` source trees on the
VPS — images come from GHCR and `scripts/init.sql` is fetched by the workflow.

---

## Step 1 — Publish the images (one-time, then automatic)

Push (or manually run) the **publish (GHCR)** workflow in each source repo:

- `dreamescape_ai` → Actions → "publish (GHCR)" → Run workflow
- `llm_api_agent`  → Actions → "publish (GHCR)" → Run workflow

After that, every push to `master` republishes automatically.

**Package visibility:** by default the packages inherit the repo visibility
(**public**, since the repos are public), so the VPS pulls anonymously — no
`docker login` needed. If you flip a package to **private**, set `GHCR_USER` +
`GHCR_TOKEN` (below) so the VPS can authenticate.

---

## Step 2 — Add the runner as a WireGuard peer (one-time)

The GitHub runner always connects with the same WireGuard identity, so generate
one keypair and keep the private key in a secret:

```bash
# on any machine with wireguard-tools
umask 077
wg genkey | tee runner_private.key | wg pubkey > runner_public.key
```

Add a `[Peer]` for the runner to the VPS's WireGuard config
(`/etc/wireguard/wg0.conf`), then `sudo systemctl reload wg-quick@wg0`:

```ini
[Peer]
PublicKey = <contents of runner_public.key>
# Optional, if you use a preshared key (generate with `wg genpsk`):
# PresharedKey = <psk>
AllowedIPs = 10.7.0.2/32      # = the runner's WG_ADDRESS (see secrets table)
```

Grab the VPS's public key for the runner side: `sudo wg show` (or
`sudo wg pubkey < /etc/wireguard/privatekey`).

---

## Step 3 — Install an SSH key for the deploy user (one-time)

Generate a dedicated keypair (don't reuse your personal key):

```bash
ssh-keygen -t ed25519 -f scripulya_deploy_id -N ""
```

Put the **public** key on the VPS:

```bash
ssh-copy-id -i scripulya_deploy_id.pub deploy@<vps-wg-ip>
# or append scripulya_deploy_id.pub to ~deploy/.ssh/authorized_keys by hand
```

The **private** key (`scripulya_deploy_id`) goes into the `SSH_PRIVATE_KEY`
secret (entire file contents, including the `-----BEGIN…-----` / `-----END…-----`
lines).

---

## Step 4 — GitHub Secrets

In this repo (**Settings → Secrets and variables → Actions → New repository
secret**) add:

### Connection — WireGuard

| Secret | Required | Example / meaning |
|--------|----------|-------------------|
| `WG_PRIVATE_KEY` | yes | Runner's WG private key (`runner_private.key`) |
| `WG_ADDRESS` | yes | Runner's WG IP **with CIDR**, e.g. `10.7.0.2/32` |
| `WG_PEER_PUBLIC_KEY` | yes | VPS's WG public key |
| `WG_PRESHARED_KEY` | no | Optional PSK (only if you set one on the VPS peer) |
| `WG_ENDPOINT` | yes | VPS public host **:port**, e.g. `vpn.example.com:51820` |
| `WG_PEER_ALLOWED_IPS` | yes | WG subnet reachable via tunnel, e.g. `10.7.0.0/24` (**must include the VPS WG IP**) |

### Connection — SSH

| Secret | Required | Example / meaning |
|--------|----------|-------------------|
| `VPS_WG_IP` | yes | VPS's WG IP **without CIDR**, e.g. `10.7.0.1` |
| `VPS_SSH_USER` | yes | SSH user, e.g. `deploy` |
| `VPS_SSH_PORT` | no | SSH port (default `22`) |
| `SSH_PRIVATE_KEY` | yes | Entire ed25519 private key file from Step 3 |

### GHCR (only for **private** packages)

| Secret | Required | Example / meaning |
|--------|----------|-------------------|
| `GHCR_USER` | no | GitHub username (or PAT username); leave empty if packages are public |
| `GHCR_TOKEN` | no | PAT with `read:packages`; leave empty if public |

### Application secrets (written into the VPS `.env` each deploy)

| Secret | Required | Example / meaning |
|--------|----------|-------------------|
| `JWT_SECRET_KEY` | yes | `python -c "import secrets; print(secrets.token_urlsafe(48))"` |
| `OPENAI_API_KEY` | no | Hybrid-memory embeddings/summary (empty ⇒ those layers degrade to empty) |
| `ANTHROPIC_API_KEY` | no | LLM provider (agent) |
| `GEMINI_API_KEY` | no | LLM provider (agent); also the image-seeder fallback |
| `ZAI_API_KEY` | no | LLM provider (agent) |
| `DEEPSEEK_API_KEY` | no | LLM provider (agent) |
| `IMAGE_API_KEY` | no | Google Imagen key for scene-art seeding |
| `MINIO_ROOT_USER` | yes | MinIO root user = S3 access key |
| `MINIO_ROOT_PASSWORD` | yes | MinIO root password (use a strong one) |
| `MINIO_PUBLIC_ENDPOINT` | yes | **Client-reachable** MinIO host:port, e.g. `media.example.com:9000` (a wrong value ⇒ every image URL 404s) |

> Provider keys are optional: with all of them empty the stack still boots and
> the backend serves the offline `testing_mock` model.

---

## Step 5 — Deploy

This repo → **Actions → "Deploy to VPS" → Run workflow**. Pick:

- **`image_tag`** — GHCR tag to deploy for both apps (default `latest`; use
  `sha-abc1234` to pin an exact build).
- **`deploy_dir`** — absolute path on the VPS (default `/opt/scripulya`).

The run will: bring up WireGuard → ping the VPS → rsync compose + `.env` +
`init.sql` → SSH `deploy-vps.sh` (pull, `up -d`, wait for `scripulya-ai` healthy)
→ tear the tunnel down. Green check = the API passed its `/health` check.

You can run the same steps by hand on the VPS: `make prod-up`, `make prod-logs`,
`make prod-ps`, `make prod-down`.

---

## Rollback

Re-run the workflow with an earlier **`image_tag`** (e.g. the last known-good
`sha-…`). The VPS keeps prior images in its local cache; Compose recreates only
the containers whose image changed.

---

## Security notes

- **Rotate the leaked GitHub PAT.** The git remotes in all three source repos
  embed a PAT (`ghp_…`) in their URL, and this repo's `.env.example` already
  flags it. Because the repos are public, that token is compromised — revoke it
  at github.com/settings/tokens and switch the remotes to SSH or a stored
  credential. None of these deploy files touch or commit that token.
- **Firewall data-plane ports.** The compose file maps Redis/FalkorDB/MinIO/
  RabbitMQ-mgmt to host ports for local dev. On the VPS, allow them only over
  WireGuard (or not at all) with your firewall — the deploy itself only needs the
  API (`:8000`) and MinIO S3 (`:9000`) to be client-reachable.
- **Avoid passing `GHCR_TOKEN` each deploy** by making the packages public (the
  repos already are) or running `docker login ghcr.io` once on the VPS; then
  leave `GHCR_USER`/`GHCR_TOKEN` empty.
- **`.env` on the VPS** is regenerated every deploy from GitHub Secrets and is
  never committed (`.gitignore` already excludes it).

---

## Troubleshooting

- **`ping` to `VPS_WG_IP` fails** → tunnel didn't come up. Check `WG_ENDPOINT`
  is reachable from the runner, `WG_PEER_ALLOWED_IPS` includes the VPS WG IP, and
  the runner's public key is actually a peer in the VPS `wg0.conf`. The "Bring up
  WireGuard tunnel" step prints `wg show`.
- **SSH `Permission denied`** → wrong `SSH_PRIVATE_KEY`/`VPS_SSH_USER`, or the
  pubkey isn't in the deploy user's `authorized_keys`, or the user isn't in the
  `docker` group.
- **`manifest unknown` / pull fails** → the tag doesn't exist in GHCR yet. Run
  the source repo's "publish (GHCR)" workflow first (Step 1).
- **`SCRIPULYA_*_IMAGE must be set`** → the workflow didn't write `.env`; re-run.
- **scripulya-ai never becomes healthy** → the run prints the last 100 log lines.
  Common cause: `MINIO_PUBLIC_ENDPOINT` wrong, or DB not initialized on a fresh
  volume (the workflow ships `init.sql`; it only runs on a pristine data volume).
- **Schema changes** → all schema lives in `scripts/init.sql` — there are **no
  migration scripts** (dev/prod always initialize from a fresh `init.sql`). To
  apply a change: edit `init.sql`, then re-seed (`docker compose down -v && up`,
  which drops DB data) or run
  `docker compose exec postgres psql -U user -d dbname -f /docker-entrypoint-initdb.d/init.sql`
  against the existing volume.
