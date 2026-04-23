/**
 * OpenClaw Teams — Integration Tests
 * Tests against a real PostgreSQL database (DATABASE_URL_TEST env variable required).
 *
 * Run with:
 *   DATABASE_URL_TEST=postgresql://user:pw@localhost:5432/openclaw_test \
 *   jest --testPathPattern=tests/integration --runInBand
 */

import { Pool } from 'pg';
import { GraphMemoryManager } from '../../src/memory/graph-memory';
import { TeamSpawningSkill } from '../../skills/team_spawning';
import { WorkflowOrchestrationSkill } from '../../skills/workflow_orchestration';
import type { GraphState } from '../../src/types';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const TEST_DB_URL = process.env['DATABASE_URL_TEST'] ?? process.env['DATABASE_URL'];

function makeState(overrides: Partial<GraphState> = {}): GraphState {
  return {
    userInput: 'Build a test service',
    requirements: { projectName: 'integration-test', estimatedComplexity: 'low' },
    currentStep: 'analyze_requirements',
    stepHistory: ['analyze_requirements'],
    decisions: [
      {
        step: 'analyze_requirements',
        timestamp: new Date().toISOString(),
        description: 'Requirements parsed',
        rationale: 'test run',
        outcome: 'low complexity',
      },
    ],
    teamsSpawned: [],
    teamResults: {},
    finalPlan: null,
    deploymentReady: false,
    startTime: new Date().toISOString(),
    endTime: null,
    errors: [],
    ...overrides,
  };
}

function makeAgent(name = 'Test Agent') {
  return {
    name,
    model: 'claude-sonnet-4-6',
    systemPrompt: `You are ${name}, a test agent.`,
    maxTokens: 1024,
    temperature: 0.5,
    tools: [] as string[],
    metadata: {} as Record<string, unknown>,
  };
}

function makeStep(id: string, handler?: (...args: unknown[]) => Promise<unknown>) {
  return {
    id,
    label: `Step ${id}`,
    agentId: 'agent-1',
    handler: handler ?? jest.fn().mockResolvedValue({ done: true }),
    retryable: false,
    maxRetries: 0,
    onSuccess: [] as string[],
    onFailure: [] as string[],
  };
}

// ---------------------------------------------------------------------------
// Conditionally skip integration tests when no real DB is available
// ---------------------------------------------------------------------------

const describeIfDB = TEST_DB_URL ? describe : describe.skip;

// ---------------------------------------------------------------------------
// Shared setup
// ---------------------------------------------------------------------------

let pool: Pool;
let memoryManager: GraphMemoryManager;

beforeAll(async () => {
  if (!TEST_DB_URL) {
    console.warn('DATABASE_URL_TEST not set — integration tests skipped');
    return;
  }
  pool = new Pool({ connectionString: TEST_DB_URL });
  memoryManager = new GraphMemoryManager(pool);
  await memoryManager.initialize();
});

afterAll(async () => {
  if (!pool) return;
  // Clean up test data
  await pool.query("DELETE FROM langgraph_states WHERE state_key LIKE 'inttest-%'").catch(() => {});
  await memoryManager.close();
});

// ---------------------------------------------------------------------------
// Graph Memory — DB integration
// ---------------------------------------------------------------------------

describeIfDB('GraphMemoryManager (integration)', () => {
  const KEY = `inttest-${Date.now()}`;

  it('should persist a state and load it back from the database', async () => {
    const state = makeState({ currentStep: 'plan_architecture' });
    await memoryManager.saveStateWithHistory(KEY, state, undefined, 'plan_architecture');

    // Create a fresh manager without cache to force DB read
    const freshManager = new GraphMemoryManager(pool);
    const loaded = await freshManager.loadState(KEY);

    expect(loaded).not.toBeNull();
    expect(loaded?.currentStep).toBe('plan_architecture');
    expect(loaded?.requirements['projectName']).toBe('integration-test');
  });

  it('should record edge transitions and retrieve them', async () => {
    const key2 = `${KEY}-edges`;
    const state = makeState();
    await memoryManager.saveStateWithHistory(key2, state, 'spawn_builder_teams', 'build_agents');

    const edges = await memoryManager.getWorkflowGraph(key2);
    expect(edges.length).toBeGreaterThan(0);
    expect(edges[0]?.fromNode).toBe('spawn_builder_teams');
    expect(edges[0]?.toNode).toBe('build_agents');
  });

  it('should create a checkpoint on each save', async () => {
    const key3 = `${KEY}-chk`;
    const state = makeState({ currentStep: 'validate_and_test' });
    await memoryManager.saveStateWithHistory(key3, state, 'build_agents', 'validate_and_test');

    const result = await pool.query<{ id: number; node_name: string }>(
      "SELECT id, node_name FROM langgraph_checkpoints WHERE state_key = $1",
      [key3],
    );
    expect(result.rows.length).toBeGreaterThan(0);
    expect(result.rows[0]?.node_name).toBe('validate_and_test');
  });

  it('should restore state from a specific checkpoint id', async () => {
    const key4 = `${KEY}-restore`;
    const state = makeState({ currentStep: 'deploy_system', deploymentReady: true });
    await memoryManager.saveStateWithHistory(key4, state, 'validate_and_test', 'deploy_system');

    const chkRow = await pool.query<{ id: number }>(
      "SELECT id FROM langgraph_checkpoints WHERE state_key = $1 LIMIT 1",
      [key4],
    );
    const checkpointId = chkRow.rows[0]?.id;
    expect(checkpointId).toBeDefined();

    const restored = await memoryManager.restoreFromCheckpoint(checkpointId!);
    expect(restored?.deploymentReady).toBe(true);
  });

  it('should update the state on subsequent saves for the same key', async () => {
    const key5 = `${KEY}-upsert`;
    const state1 = makeState({ currentStep: 'analyze_requirements' });
    await memoryManager.saveStateWithHistory(key5, state1);

    const state2 = makeState({ currentStep: 'deploy_system', deploymentReady: true });
    await memoryManager.saveStateWithHistory(key5, state2);

    const fresh = new GraphMemoryManager(pool);
    const loaded = await fresh.loadState(key5);
    expect(loaded?.currentStep).toBe('deploy_system');
    expect(loaded?.deploymentReady).toBe(true);
  });

  it('should list states with pagination', async () => {
    const result = await memoryManager.listAllStates(1, 100);
    expect(result.page).toBe(1);
    expect(result.pageSize).toBe(100);
    expect(result.total).toBeGreaterThanOrEqual(result.items.length);
    expect(Array.isArray(result.items)).toBe(true);
  });

  it('should delete old states via cleanup', async () => {
    const keyOld = `${KEY}-old`;
    const oldState = makeState();
    await memoryManager.saveStateWithHistory(keyOld, oldState);

    // Artificially age the record
    await pool.query(
      "UPDATE langgraph_states SET updated_at = NOW() - INTERVAL '91 days' WHERE state_key = $1",
      [keyOld],
    );

    const deleted = await memoryManager.cleanupOldStates(90);
    expect(deleted).toBeGreaterThanOrEqual(1);
  });

  it('should generate a valid mermaid diagram from stored edges', async () => {
    const key6 = `${KEY}-mermaid`;
    const state = makeState();
    await memoryManager.saveStateWithHistory(key6, state, 'analyze_requirements', 'plan_architecture');

    const diagram = await memoryManager.exportAsMermaidDiagram(key6);
    expect(diagram).toContain('flowchart LR');
    expect(diagram).toContain('-->');
  });
});

// ---------------------------------------------------------------------------
// Agent team spawning — integration
// ---------------------------------------------------------------------------

describeIfDB('TeamSpawningSkill (integration)', () => {
  let skill: TeamSpawningSkill;

  beforeEach(() => {
    skill = new TeamSpawningSkill();
  });

  it('should spawn a team with multiple agents and list it', () => {
    const team = skill.spawnTeam({
      name: 'Integration Team',
      role: 'integration-testing',
      agents: [makeAgent('Agent Alpha'), makeAgent('Agent Beta'), makeAgent('Agent Gamma')],
    });

    expect(team.agents).toHaveLength(3);
    const teams = skill.listTeams();
    expect(teams.some((t) => t.teamId === team.teamId)).toBe(true);
  });

  it('should assign tasks to team agents and track them', () => {
    const team = skill.spawnTeam({
      name: 'Task Team',
      role: 'tasks',
      agents: [makeAgent('Worker'), makeAgent('Worker-2')],
    });

    const task1 = skill.assignTaskToTeam(team.teamId, { action: 'build' });
    const task2 = skill.assignTaskToTeam(team.teamId, { action: 'test' });

    expect(task1.assignedAgentId).not.toBe(task2.assignedAgentId);
    expect(task1.status).toBe('running');
    expect(task2.status).toBe('running');
  });

  it('should scale a team and maintain agent consistency', () => {
    const team = skill.spawnTeam({
      name: 'Scale Team',
      role: 'scale',
      agents: [makeAgent()],
    });

    const scaled = skill.scaleTeam(team.teamId, 4);
    expect(scaled.agents).toHaveLength(4);

    const health = skill.getTeamStatus(team.teamId);
    expect(health.agents).toHaveLength(4);
  });

  it('should complete tasks and update agent resource counters', () => {
    const team = skill.spawnTeam({
      name: 'Complete Team',
      role: 'complete',
      agents: [makeAgent()],
    });

    const task = skill.assignTaskToTeam(team.teamId, { data: 'test' });
    const completed = skill.completeTask(task.taskId, { result: 'done' });

    expect(completed.status).toBe('completed');
    expect(completed.result).toEqual({ result: 'done' });

    const health = skill.getTeamStatus(team.teamId);
    expect(health.agents[0]?.resources.tasksCompleted).toBe(1);
    expect(health.agents[0]?.status).toBe('idle');
  });
});

// ---------------------------------------------------------------------------
// Full Workflow Lifecycle — integration
// ---------------------------------------------------------------------------

describeIfDB('WorkflowOrchestrationSkill (integration)', () => {
  let skill: WorkflowOrchestrationSkill;

  beforeEach(() => {
    skill = new WorkflowOrchestrationSkill();
  });

  it('should run a multi-step workflow end to end', async () => {
    const results: string[] = [];
    const step1 = makeStep('s1', async (_input) => {
      results.push('s1');
      return { from: 's1' };
    });
    const step2 = makeStep('s2', async (_input) => {
      results.push('s2');
      return { from: 's2' };
    });

    step1.onSuccess = ['s2'];

    const def = skill.createWorkflow('Multi-Step', [step1, step2], {
      exitPoints: ['s2'],
    });

    const instance = await skill.executeWorkflow(def.id, { start: true });

    expect(instance.status).toBe('completed');
    expect(results).toEqual(['s1', 's2']);
    expect(instance.stepHistory).toHaveLength(2);
  });

  it('should pause and resume a workflow mid-execution', async () => {
    let resolveStep: (v: unknown) => void;
    const slowHandler = () =>
      new Promise((resolve) => {
        resolveStep = resolve;
      });

    const step = makeStep('slow-step', slowHandler);
    const def = skill.createWorkflow('Pausable', [step], { exitPoints: ['slow-step'] });

    const execPromise = skill.executeWorkflow(def.id, {});
    await new Promise((r) => setImmediate(r));

    const active = skill.listActiveWorkflows();
    if (active.length > 0) {
      const instanceId = active[0]!.instanceId;
      skill.pauseWorkflow(instanceId);
      expect(skill.getWorkflowStatus(instanceId).status).toBe('paused');

      skill.resumeWorkflow(instanceId);
      expect(skill.getWorkflowStatus(instanceId).status).toBe('running');
    }

    resolveStep!({ done: true });
    const instance = await execPromise;
    expect(['completed', 'cancelled']).toContain(instance.status);
  });

  it('should cancel a workflow and mark it as cancelled', async () => {
    const neverResolves = () =>
      new Promise<unknown>((_resolve, _reject) => {
        // intentionally never resolves
      });

    const step = makeStep('never', neverResolves);
    const def = skill.createWorkflow('Cancellable', [step], { exitPoints: ['never'] });

    const execPromise = skill.executeWorkflow(def.id, {});
    await new Promise((r) => setImmediate(r));

    const active = skill.listActiveWorkflows();
    if (active.length > 0) {
      skill.cancelWorkflow(active[0]!.instanceId);
    }

    const instance = await execPromise;
    expect(instance.status).toBe('cancelled');
  }, 10_000);
});

// ---------------------------------------------------------------------------
// Graph State Persistence end-to-end
// ---------------------------------------------------------------------------

describeIfDB('Full workflow state persistence (integration)', () => {
  it('should persist the full 6-step workflow state and retrieve it intact', async () => {
    const key = `inttest-full-${Date.now()}`;
    const steps = [
      'analyze_requirements',
      'plan_architecture',
      'spawn_builder_teams',
      'build_agents',
      'validate_and_test',
      'deploy_system',
    ];

    let state = makeState({ currentStep: steps[0]!, stepHistory: [steps[0]!] });

    // Simulate each step transition
    for (let i = 0; i < steps.length - 1; i++) {
      await memoryManager.saveStateWithHistory(key, state, steps[i], steps[i + 1]);
      state = {
        ...state,
        currentStep: steps[i + 1]!,
        stepHistory: [...state.stepHistory, steps[i + 1]!],
      };
    }

    // Final state
    state = { ...state, deploymentReady: true, endTime: new Date().toISOString() };
    await memoryManager.saveStateWithHistory(key, state);

    const loaded = await memoryManager.loadState(key);
    expect(loaded?.deploymentReady).toBe(true);
    expect(loaded?.stepHistory).toHaveLength(6);

    const edges = await memoryManager.getWorkflowGraph(key);
    expect(edges.length).toBeGreaterThanOrEqual(5);

    const diagram = await memoryManager.exportAsMermaidDiagram(key);
    expect(diagram).toContain('analyze_requirements');
    expect(diagram).toContain('deploy_system');
  });
});
