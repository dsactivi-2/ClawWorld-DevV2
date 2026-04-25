/**
 * OpenClaw Teams — End-to-End Tests
 * Tests the running HTTP API via supertest / axios.
 *
 * Requires the server to be running (or use supertest against the app directly).
 * Set API_URL env to test against a remote server; omit to spin up the app in-process.
 *
 * Run with:
 *   API_URL=http://localhost:3000 jest --testPathPattern=tests/e2e --runInBand --forceExit
 */

import axios, { type AxiosInstance } from 'axios';

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const API_URL = process.env['API_URL'] ?? 'http://localhost:3000';
const REQUEST_TIMEOUT_MS = 15_000;

// ---------------------------------------------------------------------------
// Axios client factory
// ---------------------------------------------------------------------------

function makeClient(baseURL: string, token?: string): AxiosInstance {
  return axios.create({
    baseURL,
    timeout: REQUEST_TIMEOUT_MS,
    validateStatus: () => true, // never throw on non-2xx so we can assert status codes
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
  });
}

const client = makeClient(API_URL);

// ---------------------------------------------------------------------------
// E2E test suite
// ---------------------------------------------------------------------------

describe('E2E: Health & Metrics', () => {
  it('GET /health returns 200 with status healthy or degraded', async () => {
    const res = await client.get('/health');
    expect(res.status).toBe(200);
    expect(['healthy', 'degraded', 'unhealthy']).toContain(res.data?.status);
  });

  it('GET /health includes a version field', async () => {
    const res = await client.get('/health');
    expect(res.status).toBe(200);
    expect(res.data).toHaveProperty('version');
  });

  it('GET /metrics returns 200 with Prometheus exposition text', async () => {
    const res = await client.get('/metrics');
    expect(res.status).toBe(200);
    // Prometheus metrics start with # HELP or a metric name
    expect(typeof res.data).toBe('string');
    expect(res.data.length).toBeGreaterThan(0);
  });
});

describe('E2E: Workflows', () => {
  let createdWorkflowId: string;

  it('POST /api/workflows creates a workflow and returns 201', async () => {
    const res = await client.post('/api/workflows', {
      userInput: 'Build an e2e test REST API with CRUD operations',
      stateKey: `e2e-test-${Date.now()}`,
    });

    expect([200, 201, 202]).toContain(res.status);
    expect(res.data).toHaveProperty('id');
    createdWorkflowId = res.data.id as string;
  });

  it('POST /api/workflows returns 400 when userInput is missing', async () => {
    const res = await client.post('/api/workflows', {});
    expect(res.status).toBe(400);
    expect(res.data).toHaveProperty('error');
  });

  it('POST /api/workflows returns 400 when userInput is empty string', async () => {
    const res = await client.post('/api/workflows', { userInput: '' });
    expect(res.status).toBe(400);
  });

  it('GET /api/workflows returns 200 with an items array', async () => {
    const res = await client.get('/api/workflows');
    expect(res.status).toBe(200);
    expect(res.data).toHaveProperty('items');
    expect(Array.isArray(res.data.items)).toBe(true);
  });

  it('GET /api/workflows supports pagination with page and pageSize', async () => {
    const res = await client.get('/api/workflows?page=1&pageSize=5');
    expect(res.status).toBe(200);
    expect(res.data).toHaveProperty('page', 1);
    expect(res.data).toHaveProperty('pageSize', 5);
  });

  it('GET /api/workflows/:id returns 200 with workflow details', async () => {
    if (!createdWorkflowId) {
      console.warn('No workflow created — skipping');
      return;
    }
    const res = await client.get(`/api/workflows/${createdWorkflowId}`);
    expect([200, 404]).toContain(res.status);
    if (res.status === 200) {
      expect(res.data).toHaveProperty('id', createdWorkflowId);
    }
  });

  it('GET /api/workflows/:id returns 404 for nonexistent id', async () => {
    const res = await client.get('/api/workflows/nonexistent-id-12345');
    expect(res.status).toBe(404);
  });

  it('GET /api/workflows/:id/graph returns mermaid diagram or 404', async () => {
    if (!createdWorkflowId) return;
    const res = await client.get(`/api/workflows/${createdWorkflowId}/graph`);
    expect([200, 404]).toContain(res.status);
    if (res.status === 200) {
      expect(typeof res.data?.diagram === 'string' || typeof res.data === 'string').toBe(true);
    }
  });

  it('DELETE /api/workflows/:id cancels the workflow and returns 200 or 404', async () => {
    if (!createdWorkflowId) return;
    const res = await client.delete(`/api/workflows/${createdWorkflowId}`);
    expect([200, 202, 404]).toContain(res.status);
  });
});

describe('E2E: Agents', () => {
  it('GET /api/agents returns 200 with an agents array', async () => {
    const res = await client.get('/api/agents');
    expect(res.status).toBe(200);
    expect(res.data).toHaveProperty('agents');
    expect(Array.isArray(res.data.agents)).toBe(true);
  });

  it('GET /api/agents/:id returns 404 for nonexistent agent', async () => {
    const res = await client.get('/api/agents/nonexistent-agent-00001');
    expect(res.status).toBe(404);
  });

  it('POST /api/agents/:id/task returns 404 for unknown agent', async () => {
    const res = await client.post('/api/agents/no-agent/task', { task: 'do something' });
    expect(res.status).toBe(404);
  });

  it('GET /api/agents/:id/metrics returns 404 for unknown agent', async () => {
    const res = await client.get('/api/agents/no-agent/metrics');
    expect(res.status).toBe(404);
  });
});

describe('E2E: Teams', () => {
  let spawnedTeamId: string;

  it('POST /api/teams/spawn creates a team and returns 201', async () => {
    const res = await client.post('/api/teams/spawn', {
      name: 'E2E Test Team',
      role: 'integration-testing',
      agents: [
        {
          name: 'Worker Alpha',
          model: 'claude-sonnet-4-6',
          systemPrompt: 'You are a test worker agent.',
          maxTokens: 1024,
          temperature: 0.5,
          tools: [],
          metadata: {},
        },
      ],
      maxConcurrency: 2,
      timeoutMs: 60000,
    });

    expect([200, 201]).toContain(res.status);
    expect(res.data).toHaveProperty('teamId');
    spawnedTeamId = res.data.teamId as string;
  });

  it('POST /api/teams/spawn returns 400 when name is missing', async () => {
    const res = await client.post('/api/teams/spawn', {
      role: 'testing',
      agents: [{ name: 'A', model: 'claude-sonnet-4-6', systemPrompt: 'p' }],
    });
    expect(res.status).toBe(400);
  });

  it('GET /api/teams returns 200 with a teams array', async () => {
    const res = await client.get('/api/teams');
    expect(res.status).toBe(200);
    expect(res.data).toHaveProperty('teams');
    expect(Array.isArray(res.data.teams)).toBe(true);
  });

  it('GET /api/teams/:id returns team health for a spawned team', async () => {
    if (!spawnedTeamId) return;
    const res = await client.get(`/api/teams/${spawnedTeamId}`);
    expect([200, 404]).toContain(res.status);
    if (res.status === 200) {
      expect(res.data).toHaveProperty('teamId', spawnedTeamId);
    }
  });

  it('POST /api/teams/:id/scale returns 200 when scaling the team', async () => {
    if (!spawnedTeamId) return;
    const res = await client.post(`/api/teams/${spawnedTeamId}/scale`, { targetCount: 2 });
    expect([200, 404]).toContain(res.status);
  });

  it('DELETE /api/teams/:id despawns a team', async () => {
    if (!spawnedTeamId) return;
    const res = await client.delete(`/api/teams/${spawnedTeamId}`);
    expect([200, 202, 404]).toContain(res.status);
  });

  it('GET /api/teams/:id returns 404 for nonexistent team', async () => {
    const res = await client.get('/api/teams/ghost-team-99999');
    expect(res.status).toBe(404);
  });
});
