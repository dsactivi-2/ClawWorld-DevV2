/**
 * OpenClaw Teams — Load Testing
 *
 * Simulates concurrent load against the running API.
 * Measures p50/p95/p99 latency and throughput.
 *
 * Run with:
 *   API_URL=http://localhost:3000 npx ts-node tests/performance/load-test.ts
 *
 * Or via Jest:
 *   API_URL=http://localhost:3000 jest --testPathPattern=tests/performance --runInBand --testTimeout=120000
 */

import http from 'http';
import https from 'https';
import { URL } from 'url';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const API_URL = process.env['API_URL'] ?? 'http://localhost:3000';
const CONCURRENT_USERS = parseInt(process.env['LOAD_CONCURRENCY'] ?? '100', 10);
const RAMP_UP_MS = parseInt(process.env['LOAD_RAMP_MS'] ?? '5000', 10);
const DURATION_MS = parseInt(process.env['LOAD_DURATION_MS'] ?? '30000', 10);

// SLA thresholds
const P99_THRESHOLD_MS = 5000;
const ERROR_RATE_THRESHOLD = 0.01; // 1%

// ---------------------------------------------------------------------------
// HTTP request helper (no external dependencies)
// ---------------------------------------------------------------------------

interface RequestResult {
  statusCode: number;
  durationMs: number;
  error?: string;
  body?: string;
}

function httpRequest(
  urlStr: string,
  options: {
    method?: string;
    body?: string;
    headers?: Record<string, string>;
    timeoutMs?: number;
  } = {},
): Promise<RequestResult> {
  return new Promise((resolve) => {
    const start = Date.now();
    const parsed = new URL(urlStr);
    const isHttps = parsed.protocol === 'https:';
    const transport = isHttps ? https : http;

    const reqOptions: http.RequestOptions = {
      hostname: parsed.hostname,
      port: parsed.port ? parseInt(parsed.port, 10) : isHttps ? 443 : 80,
      path: parsed.pathname + parsed.search,
      method: options.method ?? 'GET',
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': 'openclaw-load-test/1.0',
        ...options.headers,
      },
    };

    const req = transport.request(reqOptions, (res) => {
      let body = '';
      res.on('data', (chunk: Buffer) => (body += chunk.toString()));
      res.on('end', () => {
        resolve({
          statusCode: res.statusCode ?? 0,
          durationMs: Date.now() - start,
          body,
        });
      });
    });

    req.on('error', (err: Error) => {
      resolve({
        statusCode: 0,
        durationMs: Date.now() - start,
        error: err.message,
      });
    });

    if (options.timeoutMs) {
      req.setTimeout(options.timeoutMs, () => {
        req.destroy(new Error(`Request timeout after ${options.timeoutMs}ms`));
      });
    }

    if (options.body) {
      req.write(options.body);
    }

    req.end();
  });
}

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

interface PercentileStats {
  p50: number;
  p75: number;
  p95: number;
  p99: number;
  min: number;
  max: number;
  mean: number;
}

function computePercentiles(durations: number[]): PercentileStats {
  const sorted = [...durations].sort((a, b) => a - b);
  const n = sorted.length;

  function percentile(p: number): number {
    if (n === 0) return 0;
    const idx = Math.ceil((p / 100) * n) - 1;
    return sorted[Math.max(0, Math.min(idx, n - 1))] ?? 0;
  }

  const mean = n > 0 ? sorted.reduce((a, b) => a + b, 0) / n : 0;

  return {
    p50: percentile(50),
    p75: percentile(75),
    p95: percentile(95),
    p99: percentile(99),
    min: sorted[0] ?? 0,
    max: sorted[n - 1] ?? 0,
    mean: Math.round(mean),
  };
}

// ---------------------------------------------------------------------------
// Load runner
// ---------------------------------------------------------------------------

interface ScenarioResult {
  name: string;
  totalRequests: number;
  successfulRequests: number;
  errorCount: number;
  errorRate: number;
  throughputRps: number;
  latency: PercentileStats;
  durationMs: number;
}

async function runScenario(
  name: string,
  requestFn: () => Promise<RequestResult>,
  concurrency: number,
  durationMs: number,
  rampUpMs = 0,
): Promise<ScenarioResult> {
  const durations: number[] = [];
  let totalRequests = 0;
  let errorCount = 0;
  let running = true;

  const startTime = Date.now();

  // Worker function — keeps firing requests until done = true
  async function worker(workerIndex: number): Promise<void> {
    // Ramp-up delay: stagger workers evenly
    if (rampUpMs > 0) {
      const stagger = (rampUpMs / concurrency) * workerIndex;
      await new Promise((r) => setTimeout(r, stagger));
    }

    while (running) {
      const result = await requestFn();
      totalRequests++;
      durations.push(result.durationMs);

      if (result.error || result.statusCode === 0 || result.statusCode >= 500) {
        errorCount++;
      }
    }
  }

  // Launch workers
  const workers = Array.from({ length: concurrency }, (_, i) => worker(i));

  // Stop after durationMs
  await new Promise((r) => setTimeout(r, durationMs));
  running = false;

  // Await all workers (they check `running` so they'll exit on the next loop tick)
  await Promise.allSettled(workers);

  const elapsed = Date.now() - startTime;
  const errorRate = totalRequests > 0 ? errorCount / totalRequests : 0;
  const throughputRps = totalRequests / (elapsed / 1000);

  return {
    name,
    totalRequests,
    successfulRequests: totalRequests - errorCount,
    errorCount,
    errorRate,
    throughputRps: Math.round(throughputRps * 100) / 100,
    latency: computePercentiles(durations),
    durationMs: elapsed,
  };
}

// ---------------------------------------------------------------------------
// Print report
// ---------------------------------------------------------------------------

function printReport(results: ScenarioResult[]): void {
  console.log('\n========================================');
  console.log('  OpenClaw Teams — Load Test Report');
  console.log('========================================\n');

  for (const r of results) {
    const p99Pass = r.latency.p99 <= P99_THRESHOLD_MS;
    const errPass = r.errorRate <= ERROR_RATE_THRESHOLD;

    console.log(`Scenario: ${r.name}`);
    console.log(`  Duration        : ${(r.durationMs / 1000).toFixed(1)}s`);
    console.log(`  Total Requests  : ${r.totalRequests}`);
    console.log(`  Successful      : ${r.successfulRequests}`);
    console.log(`  Errors          : ${r.errorCount} (${(r.errorRate * 100).toFixed(2)}%) ${errPass ? 'PASS' : 'FAIL'}`);
    console.log(`  Throughput      : ${r.throughputRps} req/s`);
    console.log(`  Latency (ms)`);
    console.log(`    min / mean    : ${r.latency.min} / ${r.latency.mean}`);
    console.log(`    p50 / p75     : ${r.latency.p50} / ${r.latency.p75}`);
    console.log(`    p95 / p99     : ${r.latency.p95} / ${r.latency.p99} ${p99Pass ? 'PASS' : 'FAIL'}`);
    console.log(`    max           : ${r.latency.max}`);
    console.log('');
  }
}

// ---------------------------------------------------------------------------
// Jest test wrapper
// ---------------------------------------------------------------------------

const scenarioResults: ScenarioResult[] = [];

describe('Performance: Load Test', () => {
  jest.setTimeout(180_000);

  describe('Health endpoint', () => {
    it(`should handle ${CONCURRENT_USERS} concurrent requests with p99 < ${P99_THRESHOLD_MS}ms`, async () => {
      const result = await runScenario(
        `GET /health — ${CONCURRENT_USERS} concurrent`,
        () => httpRequest(`${API_URL}/health`),
        CONCURRENT_USERS,
        DURATION_MS,
        RAMP_UP_MS,
      );

      scenarioResults.push(result);

      console.log('\nHealth endpoint results:');
      console.log(`  Requests: ${result.totalRequests}, Throughput: ${result.throughputRps} req/s`);
      console.log(`  p50: ${result.latency.p50}ms, p95: ${result.latency.p95}ms, p99: ${result.latency.p99}ms`);
      console.log(`  Error rate: ${(result.errorRate * 100).toFixed(2)}%`);

      expect(result.latency.p99).toBeLessThanOrEqual(P99_THRESHOLD_MS);
      expect(result.errorRate).toBeLessThanOrEqual(ERROR_RATE_THRESHOLD);
    });
  });

  describe('Workflows list endpoint', () => {
    it(`should handle ${Math.min(50, CONCURRENT_USERS)} concurrent GET /api/workflows requests`, async () => {
      const concurrency = Math.min(50, CONCURRENT_USERS);
      const result = await runScenario(
        `GET /api/workflows — ${concurrency} concurrent`,
        () => httpRequest(`${API_URL}/api/workflows?page=1&pageSize=10`),
        concurrency,
        Math.min(DURATION_MS, 15_000),
        RAMP_UP_MS,
      );

      scenarioResults.push(result);

      console.log('\nWorkflow list results:');
      console.log(`  Requests: ${result.totalRequests}, Throughput: ${result.throughputRps} req/s`);
      console.log(`  p99: ${result.latency.p99}ms, Error rate: ${(result.errorRate * 100).toFixed(2)}%`);

      expect(result.latency.p99).toBeLessThanOrEqual(P99_THRESHOLD_MS);
      expect(result.errorRate).toBeLessThanOrEqual(ERROR_RATE_THRESHOLD);
    });
  });

  describe('Workflow creation under load', () => {
    it(`should handle ${Math.min(10, CONCURRENT_USERS)} concurrent POST /api/workflows requests`, async () => {
      let reqIndex = 0;
      const concurrency = Math.min(10, CONCURRENT_USERS);

      const result = await runScenario(
        `POST /api/workflows — ${concurrency} concurrent`,
        () => {
          const idx = ++reqIndex;
          return httpRequest(`${API_URL}/api/workflows`, {
            method: 'POST',
            body: JSON.stringify({
              userInput: `Load test workflow ${idx}: Build a microservice`,
              stateKey: `load-test-${Date.now()}-${idx}`,
            }),
          });
        },
        concurrency,
        Math.min(DURATION_MS, 20_000),
        RAMP_UP_MS,
      );

      scenarioResults.push(result);

      console.log('\nWorkflow creation results:');
      console.log(`  Requests: ${result.totalRequests}, Throughput: ${result.throughputRps} req/s`);
      console.log(`  p99: ${result.latency.p99}ms, Error rate: ${(result.errorRate * 100).toFixed(2)}%`);

      // Workflow creation may be slower due to DB writes — use a generous threshold
      expect(result.latency.p99).toBeLessThanOrEqual(P99_THRESHOLD_MS * 2);
      expect(result.errorRate).toBeLessThanOrEqual(0.05); // allow 5% for creation
    });
  });

  describe('Agent spawning under load', () => {
    it(`should handle ${Math.min(20, CONCURRENT_USERS)} concurrent POST /api/teams/spawn requests`, async () => {
      const concurrency = Math.min(20, CONCURRENT_USERS);

      const result = await runScenario(
        `POST /api/teams/spawn — ${concurrency} concurrent`,
        () =>
          httpRequest(`${API_URL}/api/teams/spawn`, {
            method: 'POST',
            body: JSON.stringify({
              name: `Load Team ${Date.now()}`,
              role: 'load-testing',
              agents: [
                {
                  name: 'Load Worker',
                  model: 'claude-sonnet-4-6',
                  systemPrompt: 'You are a load test worker.',
                  maxTokens: 512,
                  temperature: 0.5,
                  tools: [],
                  metadata: {},
                },
              ],
            }),
          }),
        concurrency,
        Math.min(DURATION_MS, 15_000),
        RAMP_UP_MS,
      );

      scenarioResults.push(result);

      console.log('\nAgent spawning results:');
      console.log(`  Requests: ${result.totalRequests}, Throughput: ${result.throughputRps} req/s`);
      console.log(`  p99: ${result.latency.p99}ms, Error rate: ${(result.errorRate * 100).toFixed(2)}%`);

      expect(result.latency.p99).toBeLessThanOrEqual(P99_THRESHOLD_MS);
      expect(result.errorRate).toBeLessThanOrEqual(ERROR_RATE_THRESHOLD);
    });
  });

  afterAll(() => {
    printReport(scenarioResults);
  });
});

// ---------------------------------------------------------------------------
// Standalone runner (npx ts-node tests/performance/load-test.ts)
// ---------------------------------------------------------------------------

if (require.main === module) {
  (async () => {
    console.log(`OpenClaw Teams Load Test`);
    console.log(`  Target   : ${API_URL}`);
    console.log(`  Workers  : ${CONCURRENT_USERS}`);
    console.log(`  Duration : ${DURATION_MS / 1000}s`);
    console.log(`  Ramp-up  : ${RAMP_UP_MS / 1000}s`);
    console.log('');

    const results: ScenarioResult[] = [];

    // Health check
    results.push(
      await runScenario(
        `GET /health — ${CONCURRENT_USERS} concurrent`,
        () => httpRequest(`${API_URL}/health`),
        CONCURRENT_USERS,
        DURATION_MS,
        RAMP_UP_MS,
      ),
    );

    // Workflows list
    results.push(
      await runScenario(
        `GET /api/workflows — 50 concurrent`,
        () => httpRequest(`${API_URL}/api/workflows?page=1&pageSize=10`),
        50,
        DURATION_MS,
        RAMP_UP_MS,
      ),
    );

    // Workflow creation
    let reqIdx = 0;
    results.push(
      await runScenario(
        `POST /api/workflows — 10 concurrent`,
        () =>
          httpRequest(`${API_URL}/api/workflows`, {
            method: 'POST',
            body: JSON.stringify({
              userInput: `Load test workflow ${++reqIdx}`,
              stateKey: `load-standalone-${Date.now()}-${reqIdx}`,
            }),
          }),
        10,
        DURATION_MS,
        RAMP_UP_MS,
      ),
    );

    printReport(results);

    // Exit with non-zero if any SLA is violated
    const failures = results.filter(
      (r) => r.latency.p99 > P99_THRESHOLD_MS || r.errorRate > ERROR_RATE_THRESHOLD,
    );

    if (failures.length > 0) {
      console.error(`\nSLA VIOLATIONS in ${failures.length} scenario(s):`);
      failures.forEach((f) => {
        if (f.latency.p99 > P99_THRESHOLD_MS) {
          console.error(`  [${f.name}] p99 ${f.latency.p99}ms > threshold ${P99_THRESHOLD_MS}ms`);
        }
        if (f.errorRate > ERROR_RATE_THRESHOLD) {
          console.error(`  [${f.name}] error rate ${(f.errorRate * 100).toFixed(2)}% > ${ERROR_RATE_THRESHOLD * 100}%`);
        }
      });
      process.exit(1);
    }

    console.log('All SLA thresholds met.');
    process.exit(0);
  })().catch((err) => {
    console.error('Load test failed:', err);
    process.exit(1);
  });
}
