# OpenClaw Teams

A production-grade multi-agent build system powered by Anthropic Claude and LangGraph. OpenClaw Teams orchestrates hierarchical agent teams — from a top-level Builder through Supervisor layers down to specialised Worker agents — to autonomously design, build, test, and deploy software systems from natural-language requirements.

---

## Architecture

```
                        ┌─────────────────────────────────┐
                        │         User / API Client         │
                        └───────────────┬─────────────────┘
                                        │ POST /api/workflows
                                        ▼
                        ┌─────────────────────────────────┐
                        │       Express Gateway (3000)      │
                        │  helmet · cors · compression · joi│
                        └───────────────┬─────────────────┘
                                        │
                        ┌───────────────▼─────────────────┐
                        │      LangGraph Orchestrator       │
                        │                                   │
                        │  ┌──────────────────────────┐    │
                        │  │  1. analyzeRequirements   │    │
                        │  └────────────┬─────────────┘    │
                        │               │                   │
                        │  ┌────────────▼─────────────┐    │
                        │  │  2. planArchitecture      │    │
                        │  └────────────┬─────────────┘    │
                        │               │                   │
                        │  ┌────────────▼─────────────┐    │
                        │  │  3. spawnBuilderTeams     │    │
                        │  └────────────┬─────────────┘    │
                        │               │                   │
                        │  ┌────────────▼─────────────┐    │
                        │  │  4. buildAgents           │    │
                        │  └────────────┬─────────────┘    │
                        │               │                   │
                        │  ┌────────────▼─────────────┐    │
                        │  │  5. validateAndTest       │    │
                        │  └──┬──────────────────┬────┘    │
                        │     │ pass             │ fix/retry│
                        │  ┌──▼──────────────┐   └──► 4    │
                        │  │ 6. deploySystem  │            │
                        │  └─────────────────┘            │
                        └───────────────┬─────────────────┘
                                        │
               ┌────────────────────────┼────────────────────────┐
               │                        │                         │
   ┌───────────▼──────────┐  ┌──────────▼──────────┐  ┌─────────▼─────────┐
   │   Supervisor Teams    │  │  GraphMemoryManager  │  │ TeamSpawningSkill  │
   │  claude-sonnet-4-6   │  │    PostgreSQL JSONB   │  │  Dynamic scaling   │
   └──────────┬───────────┘  └─────────────────────┘  └───────────────────┘
              │
   ┌──────────▼───────────────────────────────────────────┐
   │  Worker Agents (claude-opus-4-6 / claude-sonnet-4-6) │
   │  agent-creator · skill-validator · skill-analyzer    │
   │  conflict-resolver · routing-tester · binding-config │
   │  unit-tester · integration-tester                    │
   └──────────────────────────────────────────────────────┘
```

---

## Quick Start (Docker Compose)

```bash
# 1. Clone and configure
git clone https://github.com/your-org/openclaw-teams.git
cd openclaw-teams
cp .env.example .env
# Edit .env — set ANTHROPIC_API_KEY and DB_PASSWORD at minimum

# 2. Start all services
docker compose -f docker/docker-compose.production.yml up -d

# 3. Verify health
curl http://localhost:3000/health
```

---

## Prerequisites

| Requirement | Version |
|-------------|---------|
| Node.js     | >= 20.0.0 |
| pnpm        | >= 8.0.0 |
| Docker      | >= 24.0 |
| Docker Compose | >= 2.20 |
| PostgreSQL  | 15+ (or Docker) |
| Redis       | 7+ (or Docker) |

---

## Installation

```bash
# Install dependencies
pnpm install

# Build TypeScript
pnpm build

# Run database migrations (requires DATABASE_URL in .env)
pnpm db:migrate
```

---

## Configuration

Copy `.env.example` to `.env` and configure each variable:

```bash
# Minimum required
ANTHROPIC_API_KEY=sk-ant-...          # Anthropic API key
DATABASE_URL=postgresql://...          # PostgreSQL connection string
PORT=3000                              # HTTP server port

# Optional
REDIS_URL=redis://:password@localhost:6379/0
LOG_LEVEL=info                         # error|warn|info|debug
NODE_ENV=production
JWT_SECRET=<64+ character random string>
GRAFANA_ADMIN_PASSWORD=<strong password>
```

Full variable reference: see [`.env.example`](.env.example)

---

## Running

### Development

```bash
pnpm dev
# Starts nodemon with ts-node hot reload on port 3000
```

### Production (Node.js directly)

```bash
pnpm build
pnpm start
```

### Production (Docker Compose)

```bash
docker compose -f docker/docker-compose.production.yml up -d
```

### Production (Kubernetes)

```bash
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/configmap.yaml
kubectl apply -f kubernetes/
```

---

## API Overview

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | System health (DB, Redis, orchestrator) |
| GET | `/metrics` | Prometheus metrics exposition |
| POST | `/api/workflows` | Start a new workflow from natural-language input |
| GET | `/api/workflows` | List all workflows (paginated) |
| GET | `/api/workflows/:id` | Get workflow status and decisions |
| GET | `/api/workflows/:id/graph` | Get Mermaid flowchart of workflow execution |
| DELETE | `/api/workflows/:id` | Cancel a running workflow |
| GET | `/api/agents` | List all live agents |
| GET | `/api/agents/:id` | Get agent details |
| POST | `/api/agents/:id/task` | Assign a task to an agent |
| GET | `/api/agents/:id/metrics` | Agent performance metrics |
| POST | `/api/teams/spawn` | Spawn a new agent team |
| GET | `/api/teams` | List active teams |
| GET | `/api/teams/:id` | Team health and status |
| DELETE | `/api/teams/:id` | Despawn a team |
| POST | `/api/teams/:id/scale` | Scale team agent count |

Full request/response schemas: see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

---

## Monitoring

| Service | URL | Default Credentials |
|---------|-----|---------------------|
| Grafana | http://localhost:3100 | admin / `$GRAFANA_ADMIN_PASSWORD` |
| Prometheus | http://localhost:9091 | — |
| Elasticsearch | http://localhost:9200 | — |
| App metrics | http://localhost:3000/metrics | — |

Dashboards are auto-provisioned from `config/grafana/`. Alerts are defined in `config/prometheus-alerts.yml`.

---

## Testing

```bash
# Unit tests
pnpm test:unit

# Integration tests (requires DATABASE_URL_TEST)
DATABASE_URL_TEST=postgresql://openclaw:pw@localhost:5432/openclaw_test pnpm test:integration

# End-to-end tests (requires running server)
API_URL=http://localhost:3000 pnpm test:e2e

# Performance load test
API_URL=http://localhost:3000 npx ts-node tests/performance/load-test.ts

# Security penetration tests
API_URL=http://localhost:3000 jest --testPathPattern=tests/security
```

---

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Make changes and add tests
4. Ensure all tests pass: `pnpm test`
5. Run type check: `pnpm typecheck`
6. Run linter: `pnpm lint`
7. Open a pull request

Please follow conventional commits and ensure test coverage stays above 80%.

---

## License

MIT License — Copyright (c) 2026 OpenClaw Teams Contributors.

See [LICENSE](LICENSE) for full text.
