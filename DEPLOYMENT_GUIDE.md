# Deployment Guide — OpenClaw Teams

Step-by-step instructions for deploying OpenClaw Teams to Docker Compose (single-node) or Kubernetes (production cluster).

---

## 1. Prerequisites Check

Before you begin, verify the following are installed and accessible:

```bash
# Node.js (>= 20)
node --version

# pnpm (>= 8)
pnpm --version

# Docker (>= 24)
docker --version

# Docker Compose (>= 2.20)
docker compose version

# kubectl (for Kubernetes deployment)
kubectl version --client

# PostgreSQL client (for verification)
psql --version
```

Ensure outbound network access is available to:
- `api.anthropic.com` (Claude API)
- Your container registry (if using a private image)
- Your PostgreSQL host (if external)

---

## 2. Clone and Configure

```bash
# Clone the repository
git clone https://github.com/your-org/openclaw-teams.git
cd openclaw-teams

# Create your environment file
cp .env.example .env
```

Open `.env` and configure the following **required** variables:

```bash
# REQUIRED
ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
DATABASE_URL=postgresql://openclaw:YOUR_PASSWORD@localhost:5432/openclaw_teams
DB_PASSWORD=YOUR_STRONG_PASSWORD
JWT_SECRET=change-me-to-at-least-64-random-characters-for-production-use

# RECOMMENDED
NODE_ENV=production
LOG_LEVEL=info
REDIS_URL=redis://:YOUR_REDIS_PASSWORD@localhost:6379/0
REDIS_PASSWORD=YOUR_REDIS_PASSWORD
GRAFANA_ADMIN_PASSWORD=YOUR_GRAFANA_PASSWORD

# OPTIONAL
PORT=3000
CORS_ORIGINS=https://your-frontend.example.com
SENTRY_DSN=https://your-sentry-dsn@sentry.io/project-id
```

> Security note: never commit `.env` to version control. It is already listed in `.gitignore`.

---

## 3. Docker Compose Deployment

This is the recommended approach for single-node production deployments.

### 3.1 Build the image

```bash
docker compose -f docker/docker-compose.production.yml build
```

### 3.2 Start all services

```bash
docker compose -f docker/docker-compose.production.yml up -d
```

This starts:
- `openclaw-gateway` — Node.js API on port 3000
- `postgres` — PostgreSQL 15 on port 5432 (internal)
- `redis` — Redis 7 on port 6379 (internal)
- `prometheus` — Metrics collection on port 9091
- `grafana` — Dashboards on port 3100
- `elasticsearch` — Log aggregation on port 9200

### 3.3 Verify all containers are healthy

```bash
docker compose -f docker/docker-compose.production.yml ps
```

All services should show `healthy` within 60 seconds of starting.

### 3.4 Check application health

```bash
curl http://localhost:3000/health
```

Expected response:

```json
{
  "status": "healthy",
  "checkedAt": "2026-04-23T12:00:00.000Z",
  "components": {
    "database": { "status": "healthy", "latencyMs": 2 },
    "redis": { "status": "healthy", "latencyMs": 1 },
    "orchestrator": { "status": "healthy", "message": "LangGraph operational" }
  },
  "uptimeSeconds": 30,
  "version": "1.0.0"
}
```

### 3.5 View logs

```bash
# All services
docker compose -f docker/docker-compose.production.yml logs -f

# Gateway only
docker compose -f docker/docker-compose.production.yml logs -f openclaw-gateway
```

### 3.6 Stop services

```bash
docker compose -f docker/docker-compose.production.yml down
# Add -v to also remove volumes (WARNING: destroys all data)
```

---

## 4. Kubernetes Deployment

Use this for multi-node, high-availability production deployments.

### 4.1 Prerequisites

- A running Kubernetes cluster (>= 1.28)
- `kubectl` configured with cluster access
- A container registry accessible from the cluster
- A PostgreSQL database (RDS, Cloud SQL, or self-hosted)
- A Redis instance (ElastiCache, Memorystore, or self-hosted)

### 4.2 Build and push the image

```bash
# Set your registry
export REGISTRY=registry.example.com/openclaw-teams
export TAG=$(git rev-parse --short HEAD)

# Build
docker build -f docker/Dockerfile.production -t ${REGISTRY}:${TAG} .
docker tag ${REGISTRY}:${TAG} ${REGISTRY}:latest

# Push
docker push ${REGISTRY}:${TAG}
docker push ${REGISTRY}:latest
```

### 4.3 Create the namespace

```bash
kubectl apply -f kubernetes/namespace.yaml
```

### 4.4 Create secrets

```bash
kubectl create secret generic openclaw-secrets \
  --namespace=openclaw-teams \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --from-literal=DATABASE_URL="$DATABASE_URL" \
  --from-literal=REDIS_URL="$REDIS_URL" \
  --from-literal=JWT_SECRET="$JWT_SECRET"
```

### 4.5 Apply the ConfigMap

Edit `kubernetes/configmap.yaml` to match your non-secret environment config, then:

```bash
kubectl apply -f kubernetes/configmap.yaml
```

### 4.6 Deploy all resources

```bash
# Apply remaining manifests
kubectl apply -f kubernetes/

# Watch rollout
kubectl rollout status deployment/openclaw-gateway -n openclaw-teams
```

### 4.7 Verify the deployment

```bash
# Check pods
kubectl get pods -n openclaw-teams

# Port-forward for local verification
kubectl port-forward svc/openclaw-gateway 3000:3000 -n openclaw-teams

# Test health
curl http://localhost:3000/health
```

### 4.8 Horizontal pod autoscaling

The provided HPA manifest scales the gateway between 2 and 10 replicas based on CPU utilisation at 70%. To view HPA status:

```bash
kubectl get hpa -n openclaw-teams
```

---

## 5. First-Run Verification

After deployment (Docker or Kubernetes), run these smoke tests:

```bash
BASE_URL=http://localhost:3000

# 1. Health check
curl -s ${BASE_URL}/health | jq .status

# 2. Start a test workflow
curl -s -X POST ${BASE_URL}/api/workflows \
  -H "Content-Type: application/json" \
  -d '{"userInput": "Build a simple REST API with one GET endpoint"}' | jq .

# 3. List workflows
curl -s "${BASE_URL}/api/workflows?page=1&pageSize=5" | jq .total

# 4. List teams
curl -s ${BASE_URL}/api/teams | jq .total

# 5. List agents
curl -s ${BASE_URL}/api/agents | jq .total

# 6. Metrics endpoint
curl -s ${BASE_URL}/metrics | head -5
```

All commands should return HTTP 200 responses with valid JSON (or Prometheus exposition text for /metrics).

---

## 6. Monitoring Setup

### Grafana

1. Open http://localhost:3100 (Docker) or your Grafana ingress URL (Kubernetes)
2. Log in with `admin` / `$GRAFANA_ADMIN_PASSWORD`
3. Dashboards are auto-provisioned from `config/grafana/`:
   - **OpenClaw Overview** — Request rate, error rate, latency histograms
   - **Database** — Pool connections, query latency, active transactions
   - **Agent Activity** — Active agents, tasks per second, token usage

### Prometheus Alerts

Alerts are defined in `config/prometheus-alerts.yml`. Key alerts:

| Alert | Threshold | Severity |
|-------|-----------|----------|
| `HighErrorRate` | > 5% 5xx in 5 min | critical |
| `HighLatency` | p99 > 5s in 5 min | warning |
| `DatabaseUnhealthy` | health check fails 3 times | critical |
| `AgentQueueDepth` | > 100 queued tasks | warning |
| `HighMemoryUsage` | > 80% container memory | warning |

Configure alert receivers (PagerDuty, Slack, etc.) in `config/prometheus.yml`.

### Log Access

```bash
# Docker — live log tail
docker compose -f docker/docker-compose.production.yml logs -f openclaw-gateway

# Docker — last 100 lines
docker compose -f docker/docker-compose.production.yml logs --tail=100 openclaw-gateway

# File logs (mounted at /app/logs inside container)
# Access via volume: docker exec openclaw-gateway tail -f /app/logs/app.log

# Kubernetes
kubectl logs -f deployment/openclaw-gateway -n openclaw-teams --tail=100
```

---

## 7. Troubleshooting

### Service fails to start (Docker)

```bash
# Check container exit code and logs
docker compose -f docker/docker-compose.production.yml ps
docker compose -f docker/docker-compose.production.yml logs openclaw-gateway
```

Common causes:
- `ANTHROPIC_API_KEY` not set in `.env`
- PostgreSQL not ready — wait 30 seconds and retry
- Port 3000 already in use — change `PORT` in `.env`

### Database connection errors

```bash
# Verify PostgreSQL is reachable
docker compose -f docker/docker-compose.production.yml exec postgres \
  pg_isready -U openclaw -d openclaw_teams

# Check connection string
echo $DATABASE_URL
```

### Redis connection errors

The application degrades gracefully without Redis. Check the health endpoint for `redis.status`:

```bash
curl -s http://localhost:3000/health | jq .components.redis
```

If Redis is unavailable but not required, set `REDIS_URL=` (empty) to disable Redis entirely.

### LangGraph initialisation fails

```bash
# Check that ANTHROPIC_API_KEY is valid
curl https://api.anthropic.com/v1/models \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01"
```

### Workflow stuck in `running` state

1. Check the logs for the specific `stateKey`
2. Query the database: `SELECT state->>'currentStep', state->>'errors' FROM langgraph_states WHERE state_key = '<id>';`
3. If the step history is not advancing, the Claude API may be rate-limited. Check `errors[]` in the state.

### High memory usage

LangGraph checkpoints accumulate in PostgreSQL. Run the cleanup job to remove states older than 30 days:

```bash
# Via API (when implemented)
curl -X POST http://localhost:3000/api/admin/cleanup -d '{"daysOld": 30}'

# Directly via psql
psql $DATABASE_URL -c "
  DELETE FROM langgraph_states
  WHERE updated_at < NOW() - INTERVAL '30 days';
"
```

### Kubernetes pod CrashLoopBackOff

```bash
# Check events
kubectl describe pod <pod-name> -n openclaw-teams

# Check previous container logs
kubectl logs <pod-name> -n openclaw-teams --previous
```

Most common cause: secret `openclaw-secrets` does not contain all required keys. Re-create the secret with all required values.

---

## Rollback

### Docker Compose rollback

```bash
# Tag previous image
docker tag openclaw-teams:previous openclaw-teams:production

# Restart with previous image
docker compose -f docker/docker-compose.production.yml up -d --no-build
```

### Kubernetes rollback

```bash
# Rollback to previous revision
kubectl rollout undo deployment/openclaw-gateway -n openclaw-teams

# Rollback to a specific revision
kubectl rollout undo deployment/openclaw-gateway --to-revision=2 -n openclaw-teams

# Check rollout history
kubectl rollout history deployment/openclaw-gateway -n openclaw-teams
```
