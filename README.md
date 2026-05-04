# Zerops Deploy Pipeline

Automated deployment pipeline that creates and manages full application environments on [Zerops](https://zerops.io) directly from your GitHub workflow. Push a branch, open a pull request, or merge to main — the pipeline handles the rest.

## What This Does

Every time you do something in Git, this pipeline creates or updates a complete copy of your application on Zerops — including the app itself, background workers, database, cache, message queue, and object storage. When you're done, it cleans everything up automatically.

Here's what happens for each Git action:

| You do this | Pipeline creates | What gets deployed | Lifetime |
|---|---|---|---|
| Push to a feature branch | `showcase-dev-{branch}` | Full isolated environment | Until branch is deleted |
| Open/update a PR to `stage` | `showcase-mr-{number}` | Full isolated environment | Until PR is closed |
| Merge a PR into `stage` | `showcase-stage` | Redeploys app code only | Permanent (data preserved) |
| Push/merge to `main` | `showcase-prod` | Redeploys app code only | Permanent (data preserved) |
| Delete a feature branch | — | Deletes the dev environment | — |
| Close/merge a PR | — | Deletes the MR environment | — |

**Permanent environments** (stage, prod) keep their databases, caches, queues, and storage across every deploy. Only your application code gets updated. This means your data is never lost when you deploy.

**Ephemeral environments** (dev, MR) are created from scratch each time and deleted when no longer needed. Every developer gets their own isolated copy of the full stack.

## How It Works

### The Big Picture

This repository is a **deployment orchestrator**. It does not contain your application code. Instead, it contains:

- A GitHub Actions workflow that reacts to Git events
- Import recipes that describe what services to create on Zerops
- A shell script that talks to the Zerops API

Your actual application code lives in separate repositories. The workflow checks out those repos, packages the code, and uploads it to Zerops for building and deploying.

```
This repo (deployment orchestrator)
├── .github/workflows/deploy.yml    ← the pipeline
├── zerops/
│   ├── recipes/
│   │   ├── zerops-import-dev.yml   ← lightweight config for dev environments
│   │   ├── zerops-import-stage.yml ← mid-tier config for staging
│   │   └── zerops-import-prod.yml  ← full config for production (HA, dedicated CPU)
│   └── scripts/
│       └── zerops-api.sh           ← API helper functions (curl + jq, no CLI needed)

Your app repos (separate repositories)
├── your-org/your-app               ← e.g. Bun/Node web app, has zerops.yml
└── your-org/your-worker            ← e.g. Python worker, has zerops.yml
```

### What Happens When You Push a Feature Branch

1. GitHub Actions detects the push
2. The workflow checks out this repo + your app repos
3. It calls the Zerops API to check if a project named `showcase-dev-{branch}` exists
4. If not, it creates one using the dev recipe (PostgreSQL, Valkey/Redis, NATS, object storage, plus your app and worker services)
5. It waits for all infrastructure services to be ready
6. It packages your app code into a tarball, uploads it to Zerops, and triggers a build + deploy
7. It does the same for your worker service
8. It posts the URL in the GitHub Actions summary

If you push again to the same branch, the project already exists, so step 4 is skipped — it just redeploys your code.

### What Happens When You Delete the Branch

1. GitHub fires a `delete` event
2. The cleanup job finds the project by name and deletes it
3. All services, data, and resources are freed

### Why Data Is Safe on Stage and Prod

The key function is `zerops_ensure_project`. It works like this:

```
Does a project with this name already exist?
  YES → use the existing project (skip creation entirely)
  NO  → create a new project from the import recipe
```

When it reuses an existing project, it only deploys new code to the app and worker services. The database, cache, queue, and storage services are never touched. They keep running with all their data intact.

This has been verified end-to-end: after three successive deploys to stage and multiple deploys to production, every infrastructure service retained the exact same internal ID — proving the services were never deleted and recreated.

## Zerops Concepts You Need to Know

If you're new to Zerops, here are the key concepts this pipeline uses:

**Project** — A container for a group of related services. Think of it as "one environment." All services in a project can talk to each other by hostname (e.g., your app connects to `db:5432`).

**Service (Service Stack)** — A single component within a project: a web app, a database, a cache, etc. Each service has a type (like `postgresql@17` or `bun@1.2`) and configuration for scaling, memory, and storage.

**Import YAML** — A file that describes a complete project: its name and all its services. Zerops can create an entire project from this file in one API call. The recipes in `zerops/recipes/` are import YAML files.

**zerops.yml** — A file in your app's repository that tells Zerops how to build and run your application. It defines build commands, runtime commands, and which files to deploy. This is analogous to a Dockerfile, but simpler.

**App Version** — Each deploy creates a new "app version" for a service. Zerops builds it, then switches traffic to the new version. If you need to roll back, previous versions are available in the Zerops dashboard.

## Setup Guide

### Prerequisites

- A [Zerops](https://zerops.io) account
- A GitHub repository for your deployment orchestrator (this repo)
- One or more GitHub repositories containing your application code
- Each app repo needs a `zerops.yml` file (see [Zerops docs](https://docs.zerops.io))

### Step 1: Get Your Zerops Credentials

1. Log in to [Zerops](https://app.zerops.io)
2. Go to **Settings > Access Token Management** and create a personal access token. This is your `ZEROPS_TOKEN`.
3. Go to **Settings > Client ID**. The ID shown on the page is your `ZEROPS_CLIENT_ID`. It looks like a short random string (e.g., `OBJIhKn4T2ij6SA2Cnv9TQ`).

### Step 2: Configure GitHub Secrets

In your deployment orchestrator repository (this repo), go to **Settings > Secrets and variables > Actions** and add:

| Secret | Value | Required |
|---|---|---|
| `ZEROPS_TOKEN` | Your Zerops personal access token | Yes |
| `ZEROPS_CLIENT_ID` | Your Zerops client/organization ID | Yes |
| `REPO_TOKEN` | A GitHub PAT with `repo` scope | Only if your app repos are private |

If your app repos are public, `REPO_TOKEN` is not needed — the workflow falls back to the built-in `GITHUB_TOKEN`.

### Step 3: Create the `stage` Branch

The pipeline uses a `stage` branch as the target for pull requests. Create it from `main`:

```bash
git checkout main
git checkout -b stage
git push origin stage
```

### Step 4: Customize for Your Project

#### 1. Update the workflow environment variables

Open `.github/workflows/deploy.yml` and change these lines near the top:

```yaml
env:
  APP_REPO: your-org/your-app           # ← your app repository
  WORKER_REPO: your-org/your-worker     # ← your worker repository
  APP_SERVICE_NAME: app                  # ← hostname in your import YAML
  WORKER_SERVICE_NAME: worker            # ← hostname in your import YAML
  ZEROPS_YAML_SETUP: prod               # ← setup name in your zerops.yml
```

`ZEROPS_YAML_SETUP` must match the `setup` field in your app's `zerops.yml`. For example, if your `zerops.yml` starts with `zerops: - setup: prod`, set this to `prod`.

#### 2. Customize the import recipes

The three recipe files define what services each environment gets. Edit them to match your application's needs.

**`zerops/recipes/zerops-import-dev.yml`** — Lightweight, for development:

```yaml
project:
  name: <FILLED_BY_PIPELINE>     # ← don't change this, the pipeline fills it in

services:
  - hostname: app
    type: bun@1.2                # ← change to your app's runtime
    enableSubdomainAccess: true  # ← gives it a public URL

  - hostname: worker
    type: python@3.12            # ← change to your worker's runtime

  - hostname: db
    type: postgresql@17
    mode: NON_HA                 # ← single instance (cheaper for dev)
    priority: 10                 # ← infrastructure: created first, never redeployed

  - hostname: redis
    type: valkey@7.2
    mode: NON_HA
    priority: 10

  - hostname: queue
    type: nats@2.12
    mode: NON_HA
    priority: 10

  - hostname: storage
    type: object-storage
    objectStorageSize: 2         # ← 2 GB
    objectStoragePolicy: public-read
    priority: 10
```

**`zerops/recipes/zerops-import-prod.yml`** — Full production config:

```yaml
project:
  name: <FILLED_BY_PIPELINE>
  corePackage: SERIOUS           # ← higher resource tier

services:
  - hostname: app
    type: bun@1.2
    enableSubdomainAccess: true
    minContainers: 2             # ← auto-scaling: 2-6 containers
    maxContainers: 6
    verticalAutoscaling:
      cpuMode: DEDICATED         # ← dedicated CPU for production
      minRam: 1
      minFreeRamGB: 0.5

  - hostname: db
    type: postgresql@17
    mode: HA                     # ← high availability (3 replicas)
    priority: 10
    verticalAutoscaling:
      cpuMode: DEDICATED
      minRam: 2
      minFreeRamGB: 1

  # ... similar patterns for other services
```

The key differences between environments:
- **Dev**: `NON_HA` (single instance), shared CPU, minimal RAM
- **Stage**: `NON_HA`, shared CPU, moderate RAM
- **Prod**: `HA` (high availability), `DEDICATED` CPU, more RAM, auto-scaling

**Important:** The `<FILLED_BY_PIPELINE>` placeholder in the project name is replaced automatically. Do not change it.

**Important:** Services with `priority: 10` are infrastructure services. They are created when the project is first set up and are never touched by subsequent deploys. Only services without a `priority` (app, worker) receive code deployments.

#### 3. Add or remove services

If your app doesn't use a message queue, remove the `queue` service from all three recipe files. If you need MySQL instead of PostgreSQL, change the `type` field. The available service types are listed in the [Zerops documentation](https://docs.zerops.io).

If you have more than two app services (e.g., an API, a frontend, and a worker), add them to the recipes and duplicate the deploy steps in the workflow:

```yaml
# In the workflow, after deploying app and worker:
zerops_find_service "$PROJECT_ID" "frontend"
zerops_deploy_service "$SERVICE_FOUND_ID" ./frontend ./frontend/zerops.yml "$ZEROPS_YAML_SETUP"
```

And add a checkout step for the additional repo.

#### 4. Change the project naming prefix

The project names (`showcase-dev-*`, `showcase-stage`, `showcase-prod`, `showcase-mr-*`) are set in the workflow's deploy steps. Search for `showcase` and replace with your project's name, e.g., `myapp-dev-*`, `myapp-stage`, etc.

### Step 5: Add `zerops.yml` to Your App Repos

Each application repository needs a `zerops.yml` in its root that tells Zerops how to build and run it. Example for a Node/Bun app:

```yaml
zerops:
  - setup: prod
    build:
      base: bun@1.2
      buildCommands:
        - bun install
        - bun run build
      deployFiles:
        - dist
        - node_modules
        - package.json
    run:
      start: bun run start
```

Example for a Python worker:

```yaml
zerops:
  - setup: prod
    build:
      base: python@3.12
      buildCommands:
        - pip install -r requirements.txt
      deployFiles:
        - .
    run:
      start: python worker.py
```

The `setup` field must match the `ZEROPS_YAML_SETUP` value in the workflow.

## Workflow Reference

### Branching Model

```
main (production)
 │
 └── stage (staging accumulator)
      │
      ├── feat/user-profiles    → PR → stage (merge) → eventually merge stage → main
      ├── feat/image-filters    → PR → stage
      └── feat/notifications    → PR → stage
```

1. Developers create feature branches from `stage`
2. Each push to a feature branch creates/updates a dev environment
3. When ready, developers open a PR targeting `stage`
4. The PR gets its own MR staging environment with a preview URL posted as a comment
5. When the PR is merged, the code deploys to the shared `showcase-stage` environment and the MR environment is deleted
6. When stage is ready for release, merge `stage` into `main` — this deploys to production

### Concurrency

The workflow uses GitHub Actions concurrency groups to prevent race conditions:

- `zerops-prod` — only one production deploy at a time, never cancelled
- `zerops-stage` — only one stage deploy at a time, never cancelled
- `zerops-dev-{branch}` — one deploy per branch, new pushes cancel in-progress deploys
- `zerops-mr-{number}` — one deploy per PR, new pushes cancel in-progress deploys

This means if you push twice quickly to a feature branch, the first deploy is cancelled and only the second one runs.

### Jobs

| Job | Trigger | What it does |
|---|---|---|
| `deploy-dev` | Push to any branch (except `main`, `stage`) | Create/reuse dev project, deploy app + worker |
| `deploy-prod` | Push to `main` or tag `v*` | Create/reuse prod project, deploy app + worker |
| `deploy-mr-staging` | PR opened/updated targeting `stage` | Create/reuse MR project, deploy, post PR comment |
| `deploy-stage` | PR merged into `stage` | Create/reuse stage project, deploy app + worker |
| `cleanup-mr` | PR closed (merged or rejected) | Delete the MR project |
| `cleanup-dev` | Branch deleted | Delete the dev project |

## API Script Reference

The file `zerops/scripts/zerops-api.sh` contains all the functions that talk to Zerops. It uses only `curl` and `jq` — no Zerops CLI is needed.

### Key Functions

| Function | What it does |
|---|---|
| `zerops_ensure_project` | Find a project by name; create it if it doesn't exist. This is the core function that keeps permanent environments safe. |
| `zerops_find_project` | Look up a project by name. Sets `PROJECT_FOUND_ID` if found. |
| `zerops_import_project` | Create a new project from an import YAML file. |
| `zerops_delete_project` | Delete a project by ID. |
| `zerops_find_service` | Look up a service within a project by hostname. |
| `zerops_deploy_service` | Full deploy cycle: create app version, package code, upload, build, deploy, poll until complete. |
| `zerops_wait_ready` | Poll a project until all infrastructure services are ACTIVE. |
| `zerops_get_subdomain_url` | Get the public URL for a service. |

### Error Handling

- All API calls retry up to 3 times on 5xx errors with exponential backoff (5s, 15s, 30s)
- 4xx errors are returned to the caller (e.g., 404 means "not found")
- Deploy processes are polled every 5 seconds until they reach a terminal state (FINISHED, FAILED, CANCELLED)
- If a deploy fails, the full error response is logged

## Single-Service Setup

If your project has only one deployable service (no separate worker), remove the worker-related lines from:

1. The workflow — remove the worker checkout step and the `zerops_find_service`/`zerops_deploy_service` lines for the worker in each job
2. The recipes — remove the `worker` service definition
3. The workflow env — remove the `WORKER_REPO` and `WORKER_SERVICE_NAME` variables

## FAQ

**Q: What if I push to `main` directly instead of merging from `stage`?**
A: The `deploy-prod` job fires on any push to `main`, including direct pushes. It works the same way.

**Q: What if two PRs are merged to `stage` at the same time?**
A: The concurrency group `zerops-stage` serializes them. The second deploy waits for the first to finish.

**Q: What if I close a PR without merging?**
A: The `cleanup-mr` job still runs (it triggers on all PR closes). It deletes the MR staging project. The `deploy-stage` job is skipped because the PR was not merged.

**Q: Can I use this with a monorepo instead of separate app repos?**
A: Yes. Change the checkout steps to check out subdirectories of your monorepo, and point the `zerops_deploy_service` calls to the right directories.

**Q: How much does this cost on Zerops?**
A: Ephemeral environments (dev, MR) are only billed while they exist. They're automatically deleted when branches are deleted or PRs are closed. Permanent environments (stage, prod) run continuously. Check [Zerops pricing](https://zerops.io/pricing) for current rates.

**Q: What if the Zerops API is down during a deploy?**
A: The API calls retry 3 times with exponential backoff. If all retries fail, the GitHub Actions job fails and you can re-run it from the Actions tab.

**Q: How do I see what's running on Zerops?**
A: Log in to [app.zerops.io](https://app.zerops.io). You'll see all your projects listed. Click into any project to see its services, logs, and metrics.
