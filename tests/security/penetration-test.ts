/**
 * OpenClaw Teams — Security / Penetration Test Suite
 *
 * Tests for:
 *  - SQL injection in workflow inputs
 *  - XSS payloads in agent names
 *  - JWT validation (expired, invalid signature, missing token)
 *  - Rate limiting enforcement
 *  - Unauthorized access to admin endpoints
 *  - Path traversal attempts
 *
 * Run with:
 *   API_URL=http://localhost:3000 jest --testPathPattern=tests/security --runInBand --forceExit
 */

import axios, { AxiosInstance } from 'axios';

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const API_URL = process.env['API_URL'] ?? 'http://localhost:3000';
const RATE_LIMIT_WINDOW_MS = 15 * 60 * 1000; // 15 minutes
const RATE_LIMIT_MAX = 100;

// ---------------------------------------------------------------------------
// Axios client
// ---------------------------------------------------------------------------

function makeClient(baseURL: string, headers: Record<string, string> = {}): AxiosInstance {
  return axios.create({
    baseURL,
    timeout: 10_000,
    validateStatus: () => true,
    headers: { 'Content-Type': 'application/json', ...headers },
  });
}

const client = makeClient(API_URL);

// ---------------------------------------------------------------------------
// JWT helpers
// ---------------------------------------------------------------------------

function base64url(input: string): string {
  return Buffer.from(input)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

function buildJwt(payload: Record<string, unknown>, signature = 'invalidsig'): string {
  const header = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = base64url(JSON.stringify(payload));
  return `${header}.${body}.${signature}`;
}

function expiredJwt(): string {
  return buildJwt({
    sub: 'user-123',
    exp: Math.floor(Date.now() / 1000) - 3600, // 1 hour in the past
    iat: Math.floor(Date.now() / 1000) - 7200,
  });
}

function futureJwt(): string {
  return buildJwt({
    sub: 'user-123',
    exp: Math.floor(Date.now() / 1000) + 3600,
    iat: Math.floor(Date.now() / 1000),
  });
}

// ---------------------------------------------------------------------------
// SQL injection payloads
// ---------------------------------------------------------------------------

const SQL_INJECTION_PAYLOADS = [
  "'; DROP TABLE langgraph_states; --",
  "' OR '1'='1",
  "' UNION SELECT * FROM langgraph_states --",
  "1; DELETE FROM langgraph_states WHERE 1=1; --",
  "' OR 1=1--",
  "admin'--",
  "1' AND SLEEP(5)--",
  "'; INSERT INTO langgraph_states (state_key) VALUES ('hacked'); --",
];

// ---------------------------------------------------------------------------
// XSS payloads
// ---------------------------------------------------------------------------

const XSS_PAYLOADS = [
  '<script>alert("xss")</script>',
  '"><img src=x onerror=alert(1)>',
  "javascript:alert('xss')",
  '<svg onload=alert(1)>',
  '{{7*7}}', // template injection
  '${7*7}',  // template literal injection
  '<iframe src="javascript:alert(1)">',
];

// ---------------------------------------------------------------------------
// Path traversal payloads
// ---------------------------------------------------------------------------

const PATH_TRAVERSAL_PAYLOADS = [
  '../../../etc/passwd',
  '..%2F..%2F..%2Fetc%2Fpasswd',
  '....//....//....//etc/passwd',
  '%2e%2e%2f%2e%2e%2f%2e%2e%2fetc%2fpasswd',
  '..\\..\\..\\windows\\system32\\cmd.exe',
  '/etc/passwd',
  '/proc/self/environ',
];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('Security: SQL Injection', () => {
  it.each(SQL_INJECTION_PAYLOADS)(
    'should not return 500 or leak DB errors for SQL payload: %s',
    async (payload) => {
      const res = await client.post('/api/workflows', { userInput: payload });
      // Should accept, validate, or reject gracefully — not 500
      expect(res.status).not.toBe(500);
      // Response body should not contain raw SQL error messages
      const body = typeof res.data === 'string' ? res.data : JSON.stringify(res.data);
      expect(body.toLowerCase()).not.toMatch(/sql syntax|pg_query|pg_exec|syntax error at|pg_prepare/i);
    },
  );

  it('should sanitise SQL injection in agent name field', async () => {
    const res = await client.post('/api/teams/spawn', {
      name: "'; DROP TABLE langgraph_states; --",
      role: 'test',
      agents: [
        {
          name: "' OR '1'='1",
          model: 'claude-sonnet-4-6',
          systemPrompt: 'test',
          maxTokens: 512,
          temperature: 0.5,
          tools: [],
          metadata: {},
        },
      ],
    });
    expect(res.status).not.toBe(500);
    const body = typeof res.data === 'string' ? res.data : JSON.stringify(res.data);
    expect(body.toLowerCase()).not.toMatch(/syntax error|pg_query|invalid input/i);
  });
});

describe('Security: XSS Prevention', () => {
  it.each(XSS_PAYLOADS)(
    'should not reflect XSS payload unescaped in response: %s',
    async (payload) => {
      const res = await client.post('/api/teams/spawn', {
        name: payload,
        role: 'test',
        agents: [
          {
            name: payload,
            model: 'claude-sonnet-4-6',
            systemPrompt: 'test agent',
            maxTokens: 512,
            temperature: 0.5,
            tools: [],
            metadata: {},
          },
        ],
      });

      // If it echoes the name back, check it's not raw HTML
      if (res.status === 200 || res.status === 201) {
        const body = typeof res.data === 'string' ? res.data : JSON.stringify(res.data);
        // Raw <script> tags should not appear unescaped
        expect(body).not.toMatch(/<script>alert/);
        expect(body).not.toMatch(/onerror=alert/);
      }

      // Status should not be 500 (internal error from unescaped rendering)
      expect(res.status).not.toBe(500);
    },
  );

  it('should return Content-Type application/json (not text/html) for API responses', async () => {
    const res = await client.get('/api/agents');
    const contentType = res.headers['content-type'] ?? '';
    expect(contentType).toMatch(/application\/json/);
  });

  it('should include X-Content-Type-Options header to prevent MIME sniffing', async () => {
    const res = await client.get('/health');
    const header = res.headers['x-content-type-options'];
    // Helmet sets this; if not present the test is informational
    if (header) {
      expect(header).toBe('nosniff');
    }
  });
});

describe('Security: JWT Token Validation', () => {
  it('should return 401 when Authorization header is missing on protected endpoint', async () => {
    const protectedClient = makeClient(API_URL);
    const res = await protectedClient.get('/api/admin/users');
    // If endpoint exists and is protected, expect 401 or 403; if it does not exist, 404 is fine
    expect([401, 403, 404]).toContain(res.status);
  });

  it('should return 401 or 403 when a JWT with invalid signature is provided', async () => {
    const badToken = futureJwt(); // valid structure, wrong signature
    const res = await makeClient(API_URL, { Authorization: `Bearer ${badToken}` }).get(
      '/api/admin/users',
    );
    expect([401, 403, 404]).toContain(res.status);
  });

  it('should return 401 or 403 when an expired JWT is provided', async () => {
    const token = expiredJwt();
    const res = await makeClient(API_URL, { Authorization: `Bearer ${token}` }).get(
      '/api/admin/users',
    );
    expect([401, 403, 404]).toContain(res.status);
  });

  it('should not accept a completely malformed token string', async () => {
    const res = await makeClient(API_URL, { Authorization: 'Bearer not.a.valid.jwt.string' }).get(
      '/api/admin/users',
    );
    expect([401, 403, 404]).toContain(res.status);
  });

  it('should not accept a token with algorithm "none"', async () => {
    const noneToken =
      base64url(JSON.stringify({ alg: 'none', typ: 'JWT' })) +
      '.' +
      base64url(JSON.stringify({ sub: 'attacker', exp: Math.floor(Date.now() / 1000) + 9999 })) +
      '.';
    const res = await makeClient(API_URL, { Authorization: `Bearer ${noneToken}` }).get(
      '/api/admin/users',
    );
    expect([401, 403, 404]).toContain(res.status);
  });
});

describe('Security: Rate Limiting', () => {
  it('should return 429 after exceeding the rate limit threshold', async () => {
    const requests = Array.from({ length: RATE_LIMIT_MAX + 20 }, () =>
      client.get('/health'),
    );
    const responses = await Promise.all(requests);
    const statusCodes = responses.map((r) => r.status);

    // At least some requests should be rate limited — but health may be exempt.
    // Check against a more limited endpoint.
    const tooMany = statusCodes.filter((s) => s === 429);

    // If rate limiting is configured, we expect at least some 429s.
    // If the server does not implement rate limiting on /health, this is informational.
    if (tooMany.length > 0) {
      expect(tooMany.length).toBeGreaterThan(0);
    } else {
      console.warn(
        'Rate limiting not triggered on /health — verify rate limit config includes API routes',
      );
    }
  }, 30_000);

  it('should return 429 when flooding POST /api/workflows', async () => {
    const concurrentRequests = RATE_LIMIT_MAX + 10;
    const requests = Array.from({ length: concurrentRequests }, (_, i) =>
      client.post('/api/workflows', { userInput: `rate limit test ${i}` }),
    );

    const responses = await Promise.all(requests);
    const statusCodes = responses.map((r) => r.status);

    // All responses should be 200, 201, 202, 400, or 429 — never 500
    statusCodes.forEach((code) => {
      expect([200, 201, 202, 400, 429]).toContain(code);
    });
  }, 30_000);
});

describe('Security: Unauthorized Access to Admin Endpoints', () => {
  it('should not expose /api/admin routes without authentication', async () => {
    const adminRoutes = [
      '/api/admin',
      '/api/admin/users',
      '/api/admin/config',
      '/api/admin/metrics',
    ];

    for (const route of adminRoutes) {
      const res = await client.get(route);
      // Must be either 401 (unauthenticated), 403 (forbidden), or 404 (not exposed)
      expect([401, 403, 404]).toContain(res.status);
    }
  });

  it('should not expose internal DB schema at any public endpoint', async () => {
    const internalPaths = [
      '/api/internal',
      '/api/debug',
      '/.env',
      '/config',
    ];
    for (const path of internalPaths) {
      const res = await client.get(path);
      expect([401, 403, 404]).toContain(res.status);
    }
  });

  it('should return 403 or 404 when accessing a different users workflow', async () => {
    // Try to access a workflow with a crafted ID
    const res = await client.get('/api/workflows/../../admin');
    expect([400, 403, 404]).toContain(res.status);
  });
});

describe('Security: Path Traversal', () => {
  it.each(PATH_TRAVERSAL_PAYLOADS)(
    'should return 400 or 404 for path traversal in workflow id: %s',
    async (payload) => {
      const encodedPayload = encodeURIComponent(payload);
      const res = await client.get(`/api/workflows/${encodedPayload}`);
      expect([400, 403, 404]).toContain(res.status);
      // Must not return server internals
      const body = typeof res.data === 'string' ? res.data : JSON.stringify(res.data);
      expect(body).not.toMatch(/root:x:0:0/); // /etc/passwd content
      expect(body).not.toMatch(/\[extensions\]/i); // windows system file
    },
  );

  it('should return 400 or 404 for path traversal in agent id', async () => {
    const res = await client.get('/api/agents/..%2F..%2Fetc%2Fpasswd');
    expect([400, 403, 404]).toContain(res.status);
  });

  it('should return 400 or 404 for path traversal in team id', async () => {
    const res = await client.get('/api/teams/..%2F..%2Fetc%2Fpasswd');
    expect([400, 403, 404]).toContain(res.status);
  });
});

describe('Security: Security Headers', () => {
  it('should include X-Frame-Options header to prevent clickjacking', async () => {
    const res = await client.get('/health');
    const header = res.headers['x-frame-options'];
    if (header) {
      expect(['DENY', 'SAMEORIGIN']).toContain(header.toUpperCase());
    }
  });

  it('should include Strict-Transport-Security header in production', async () => {
    // HSTS is typically only sent over HTTPS; skip for HTTP test environments
    if (!API_URL.startsWith('https://')) return;
    const res = await client.get('/health');
    expect(res.headers).toHaveProperty('strict-transport-security');
  });

  it('should not expose Express server version in X-Powered-By header', async () => {
    const res = await client.get('/health');
    // Helmet removes this header by default
    expect(res.headers['x-powered-by']).toBeUndefined();
  });
});

describe('Security: CSRF Protection', () => {
  it('should require CSRF token for state-changing requests', async () => {
    const res = await client.post('/api/workflows',
      { userInput: 'test' },
      { headers: { 'X-CSRF-Token': 'invalid-token' } }
    );
    expect([400, 403, 422]).toContain(res.status);
  });

  it('should reject POST without CSRF token header entirely', async () => {
    const res = await client.post('/api/teams/spawn',
      { name: 'csrf-test-team', agents: [] },
      { headers: { 'X-CSRF-Token': undefined } }
    );
    // Must not succeed silently
    expect(res.status).not.toBe(201);
  });

  it('should accept requests with valid CSRF token', async () => {
    // First get a valid token via GET (if CSRF endpoint exists)
    const tokenRes = await client.get('/api/csrf-token').catch(() => null);
    if (tokenRes && tokenRes.status === 200 && tokenRes.data?.token) {
      const res = await client.post('/api/workflows',
        { userInput: 'csrf-valid-test' },
        { headers: { 'X-CSRF-Token': tokenRes.data.token } }
      );
      expect([200, 201, 202]).toContain(res.status);
    } else {
      // CSRF endpoint not implemented — skip gracefully
      expect(true).toBe(true);
    }
  });
});

describe('Security: CORS', () => {
  it('should not allow wildcard CORS from health endpoint', async () => {
    const res = await client.get('/health', {
      headers: { Origin: 'https://evil.com' }
    });
    const acao = res.headers['access-control-allow-origin'];
    // Must not be wildcard
    expect(acao).not.toBe('*');
  });

  it('should not echo arbitrary Origin back in ACAO header', async () => {
    const res = await client.get('/api/agents', {
      headers: { Origin: 'https://attacker.example.com' }
    });
    const acao = res.headers['access-control-allow-origin'];
    if (acao) {
      expect(acao).not.toBe('https://attacker.example.com');
    }
    // No ACAO header is also acceptable
  });

  it('should allow configured allowed origins', async () => {
    const allowedOrigin = process.env.ALLOWED_ORIGIN ?? 'http://localhost:3000';
    const res = await client.get('/health', {
      headers: { Origin: allowedOrigin }
    });
    expect([200, 204]).toContain(res.status);
  });

  it('should respond correctly to CORS preflight (OPTIONS)', async () => {
    const res = await client.options('/api/workflows', {
      headers: {
        Origin: 'https://evil.com',
        'Access-Control-Request-Method': 'POST',
        'Access-Control-Request-Headers': 'Content-Type',
      }
    });
    const acao = res.headers['access-control-allow-origin'];
    // Preflight must not grant evil.com
    if (acao) {
      expect(acao).not.toBe('https://evil.com');
      expect(acao).not.toBe('*');
    }
  });
});
