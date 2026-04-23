-- ============================================================
-- openclaw-teams — LangGraph State & Execution Tables
-- Engine: PostgreSQL 15+
-- Depends on: init.sql (uuid-ossp extension, trigger_set_updated_at)
-- ============================================================

SET search_path TO public;

-- ============================================================
-- ENUMS
-- ============================================================

DO $$ BEGIN
    CREATE TYPE graph_node_status_enum AS ENUM (
        'pending', 'running', 'completed', 'failed', 'skipped', 'cancelled'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ============================================================
-- TABLE: graph_states
-- Central state store for each LangGraph execution instance.
-- One row per unique graph run, updated as the graph progresses.
-- ============================================================

CREATE TABLE IF NOT EXISTS graph_states (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    state_key           VARCHAR(512) NOT NULL,
    state_data          JSONB NOT NULL DEFAULT '{}',
    step_history        TEXT[] NOT NULL DEFAULT '{}',
    team_results        JSONB NOT NULL DEFAULT '{}',
    decisions           JSONB[] NOT NULL DEFAULT '{}',
    deployment_ready    BOOLEAN NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT graph_states_state_key_unique UNIQUE (state_key),
    CONSTRAINT graph_states_state_data_is_object   CHECK (jsonb_typeof(state_data)   = 'object'),
    CONSTRAINT graph_states_team_results_is_object CHECK (jsonb_typeof(team_results) = 'object')
);

COMMENT ON TABLE graph_states IS 'Central LangGraph execution state. One row per unique graph run identified by state_key.';
COMMENT ON COLUMN graph_states.state_key IS 'Opaque unique key that identifies a graph execution: typically a UUID or composite run identifier';
COMMENT ON COLUMN graph_states.state_data IS 'Full serialized LangGraph state: channel values, reducers, pending sends, etc.';
COMMENT ON COLUMN graph_states.step_history IS 'Ordered list of node names executed so far in this graph run';
COMMENT ON COLUMN graph_states.team_results IS 'Aggregated results from each agent/team that has completed work in this run';
COMMENT ON COLUMN graph_states.decisions IS 'Array of routing decision objects emitted by conditional-edge functions';
COMMENT ON COLUMN graph_states.deployment_ready IS 'True when the graph has reached a terminal node and all deployment criteria are met';

CREATE INDEX IF NOT EXISTS idx_graph_states_state_key        ON graph_states (state_key);
CREATE INDEX IF NOT EXISTS idx_graph_states_deployment_ready ON graph_states (deployment_ready) WHERE deployment_ready = TRUE;
CREATE INDEX IF NOT EXISTS idx_graph_states_created_at       ON graph_states (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_graph_states_updated_at       ON graph_states (updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_graph_states_state_data_gin   ON graph_states USING GIN (state_data);
CREATE INDEX IF NOT EXISTS idx_graph_states_team_results_gin ON graph_states USING GIN (team_results);

CREATE TRIGGER trg_graph_states_updated_at
    BEFORE UPDATE ON graph_states
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ============================================================
-- TABLE: graph_edges
-- Records every edge traversal in the graph for replay/audit.
-- ============================================================

CREATE TABLE IF NOT EXISTS graph_edges (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    state_key       VARCHAR(512) NOT NULL REFERENCES graph_states (state_key) ON DELETE CASCADE,
    from_node       VARCHAR(255) NOT NULL,
    to_node         VARCHAR(255) NOT NULL,
    decision_data   JSONB,
    timestamp       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT graph_edges_decision_data_is_object CHECK (
        decision_data IS NULL OR jsonb_typeof(decision_data) = 'object'
    )
);

COMMENT ON TABLE graph_edges IS 'Immutable log of every edge traversal (from_node → to_node) for a given graph state';
COMMENT ON COLUMN graph_edges.from_node IS 'Source node name, or "__start__" for the initial entry edge';
COMMENT ON COLUMN graph_edges.to_node IS 'Destination node name, or "__end__" for terminal edges';
COMMENT ON COLUMN graph_edges.decision_data IS 'Payload from the conditional-edge function that selected this edge, if applicable';

CREATE INDEX IF NOT EXISTS idx_graph_edges_state_key  ON graph_edges (state_key);
CREATE INDEX IF NOT EXISTS idx_graph_edges_from_node  ON graph_edges (from_node);
CREATE INDEX IF NOT EXISTS idx_graph_edges_to_node    ON graph_edges (to_node);
CREATE INDEX IF NOT EXISTS idx_graph_edges_timestamp  ON graph_edges (timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_graph_edges_state_time ON graph_edges (state_key, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_graph_edges_decision_gin ON graph_edges USING GIN (decision_data) WHERE decision_data IS NOT NULL;

-- ============================================================
-- TABLE: graph_checkpoints
-- LangGraph checkpoint snapshots for fault-tolerance / resume.
-- Mirrors LangGraph's built-in checkpoint interface for Postgres.
-- ============================================================

CREATE TABLE IF NOT EXISTS graph_checkpoints (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    state_key       VARCHAR(512) NOT NULL REFERENCES graph_states (state_key) ON DELETE CASCADE,
    checkpoint_id   VARCHAR(512) NOT NULL,
    state_data      JSONB NOT NULL DEFAULT '{}',
    node_name       VARCHAR(255) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT graph_checkpoints_checkpoint_id_unique UNIQUE (checkpoint_id),
    CONSTRAINT graph_checkpoints_state_data_is_object CHECK (jsonb_typeof(state_data) = 'object')
);

COMMENT ON TABLE graph_checkpoints IS 'Periodic state snapshots enabling graph resume after failures or intentional interrupts';
COMMENT ON COLUMN graph_checkpoints.checkpoint_id IS 'Globally unique checkpoint identifier issued by the LangGraph checkpoint saver';
COMMENT ON COLUMN graph_checkpoints.state_data IS 'Full graph state at the moment of checkpoint creation';
COMMENT ON COLUMN graph_checkpoints.node_name IS 'Name of the node that was about to execute when the checkpoint was captured';

CREATE INDEX IF NOT EXISTS idx_graph_checkpoints_state_key     ON graph_checkpoints (state_key);
CREATE INDEX IF NOT EXISTS idx_graph_checkpoints_checkpoint_id ON graph_checkpoints (checkpoint_id);
CREATE INDEX IF NOT EXISTS idx_graph_checkpoints_node_name     ON graph_checkpoints (node_name);
CREATE INDEX IF NOT EXISTS idx_graph_checkpoints_created_at    ON graph_checkpoints (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_graph_checkpoints_state_data_gin ON graph_checkpoints USING GIN (state_data);
-- Composite: latest checkpoint per state_key
CREATE INDEX IF NOT EXISTS idx_graph_checkpoints_state_created ON graph_checkpoints (state_key, created_at DESC);

-- ============================================================
-- TABLE: graph_history
-- Granular per-node execution history with timing and errors.
-- ============================================================

CREATE TABLE IF NOT EXISTS graph_history (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    state_key       VARCHAR(512) NOT NULL REFERENCES graph_states (state_key) ON DELETE CASCADE,
    node_name       VARCHAR(255) NOT NULL,
    input_data      JSONB NOT NULL DEFAULT '{}',
    output_data     JSONB,
    duration_ms     INTEGER,
    error_message   TEXT,
    success         BOOLEAN NOT NULL DEFAULT TRUE,
    timestamp       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT graph_history_duration_positive CHECK (duration_ms IS NULL OR duration_ms >= 0),
    CONSTRAINT graph_history_input_is_object   CHECK (jsonb_typeof(input_data) = 'object'),
    CONSTRAINT graph_history_output_is_object  CHECK (output_data IS NULL OR jsonb_typeof(output_data) = 'object'),
    CONSTRAINT graph_history_error_when_failed CHECK (
        success = TRUE OR error_message IS NOT NULL
    )
);

COMMENT ON TABLE graph_history IS 'Per-node execution records: inputs, outputs, timing, and error details for every node invocation';
COMMENT ON COLUMN graph_history.node_name IS 'Graph node name as declared in the StateGraph definition';
COMMENT ON COLUMN graph_history.input_data IS 'State snapshot passed into the node function at invocation time';
COMMENT ON COLUMN graph_history.output_data IS 'State patch returned by the node function; NULL if the node raised an error';
COMMENT ON COLUMN graph_history.duration_ms IS 'Wall-clock execution time for the node function in milliseconds';
COMMENT ON COLUMN graph_history.error_message IS 'Exception message if success=FALSE; NULL otherwise';

CREATE INDEX IF NOT EXISTS idx_graph_history_state_key   ON graph_history (state_key);
CREATE INDEX IF NOT EXISTS idx_graph_history_node_name   ON graph_history (node_name);
CREATE INDEX IF NOT EXISTS idx_graph_history_success     ON graph_history (success);
CREATE INDEX IF NOT EXISTS idx_graph_history_timestamp   ON graph_history (timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_graph_history_state_node  ON graph_history (state_key, node_name);
CREATE INDEX IF NOT EXISTS idx_graph_history_failed      ON graph_history (state_key, timestamp DESC) WHERE success = FALSE;
CREATE INDEX IF NOT EXISTS idx_graph_history_input_gin   ON graph_history USING GIN (input_data);
CREATE INDEX IF NOT EXISTS idx_graph_history_output_gin  ON graph_history USING GIN (output_data) WHERE output_data IS NOT NULL;

-- ============================================================
-- VIEW: graph_run_summary
-- High-level view over each graph execution
-- ============================================================

CREATE OR REPLACE VIEW graph_run_summary AS
SELECT
    gs.state_key,
    gs.deployment_ready,
    gs.created_at                                               AS run_started_at,
    gs.updated_at                                               AS last_updated_at,
    EXTRACT(EPOCH FROM (gs.updated_at - gs.created_at)) * 1000 AS total_duration_ms,
    array_length(gs.step_history, 1)                            AS steps_completed,
    COUNT(gh.id)                                                AS total_node_executions,
    COUNT(gh.id) FILTER (WHERE gh.success = FALSE)              AS failed_node_executions,
    COUNT(gc.id)                                                AS checkpoint_count,
    COUNT(ge.id)                                                AS edge_count
FROM graph_states gs
LEFT JOIN graph_history     gh ON gh.state_key = gs.state_key
LEFT JOIN graph_checkpoints gc ON gc.state_key = gs.state_key
LEFT JOIN graph_edges       ge ON ge.state_key = gs.state_key
GROUP BY
    gs.state_key,
    gs.deployment_ready,
    gs.created_at,
    gs.updated_at,
    gs.step_history;

COMMENT ON VIEW graph_run_summary IS 'Aggregated overview of each graph run: duration, node execution counts, failures, and checkpoint count';

-- ============================================================
-- VIEW: graph_failed_nodes
-- Quick view of all failed node executions across all runs
-- ============================================================

CREATE OR REPLACE VIEW graph_failed_nodes AS
SELECT
    gh.state_key,
    gh.node_name,
    gh.error_message,
    gh.duration_ms,
    gh.timestamp
FROM graph_history gh
WHERE gh.success = FALSE
ORDER BY gh.timestamp DESC;

COMMENT ON VIEW graph_failed_nodes IS 'All failed node invocations across all graph runs, newest first';

-- ============================================================
-- FUNCTION: get_latest_checkpoint
-- Convenience function to retrieve the most recent checkpoint
-- for a given state_key
-- ============================================================

CREATE OR REPLACE FUNCTION get_latest_checkpoint(p_state_key VARCHAR)
RETURNS TABLE (
    checkpoint_id   VARCHAR,
    state_data      JSONB,
    node_name       VARCHAR,
    created_at      TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        gc.checkpoint_id,
        gc.state_data,
        gc.node_name,
        gc.created_at
    FROM graph_checkpoints gc
    WHERE gc.state_key = p_state_key
    ORDER BY gc.created_at DESC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_latest_checkpoint IS 'Returns the most recent checkpoint for a graph execution identified by state_key';

-- ============================================================
-- FUNCTION: record_graph_node_execution
-- Atomic helper to insert a graph_history row and update
-- graph_states.step_history in one transaction
-- ============================================================

CREATE OR REPLACE FUNCTION record_graph_node_execution(
    p_state_key     VARCHAR,
    p_node_name     VARCHAR,
    p_input_data    JSONB,
    p_output_data   JSONB DEFAULT NULL,
    p_duration_ms   INTEGER DEFAULT NULL,
    p_error_message TEXT DEFAULT NULL,
    p_success       BOOLEAN DEFAULT TRUE
) RETURNS UUID AS $$
DECLARE
    v_history_id UUID;
BEGIN
    -- Insert execution record
    INSERT INTO graph_history (
        state_key, node_name, input_data, output_data,
        duration_ms, error_message, success, timestamp
    ) VALUES (
        p_state_key, p_node_name, p_input_data, p_output_data,
        p_duration_ms, p_error_message, p_success, NOW()
    )
    RETURNING id INTO v_history_id;

    -- Append node to step_history on the parent graph_states row
    UPDATE graph_states
    SET
        step_history = step_history || p_node_name::TEXT,
        updated_at   = NOW()
    WHERE state_key = p_state_key;

    RETURN v_history_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION record_graph_node_execution IS 'Atomically inserts a graph_history row and appends the node name to graph_states.step_history';

-- ============================================================
-- GRANT permissions to application role
-- ============================================================

GRANT SELECT, INSERT, UPDATE ON graph_states       TO openclaw_app;
GRANT SELECT, INSERT          ON graph_edges        TO openclaw_app;
GRANT SELECT, INSERT          ON graph_checkpoints  TO openclaw_app;
GRANT SELECT, INSERT          ON graph_history      TO openclaw_app;
GRANT SELECT ON graph_run_summary    TO openclaw_app;
GRANT SELECT ON graph_failed_nodes   TO openclaw_app;
GRANT EXECUTE ON FUNCTION get_latest_checkpoint      TO openclaw_app;
GRANT EXECUTE ON FUNCTION record_graph_node_execution TO openclaw_app;
