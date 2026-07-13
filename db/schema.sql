\restrict dbmate

-- Dumped from database version 16.14 (Debian 16.14-1.pgdg13+1)
-- Dumped by pg_dump version 17.10

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: meta; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA meta;


--
-- Name: raw; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA raw;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: column_registry; Type: TABLE; Schema: meta; Owner: -
--

CREATE TABLE meta.column_registry (
    signal text NOT NULL,
    signal_name text NOT NULL,
    attr_path text NOT NULL,
    status text NOT NULL,
    column_name text,
    data_type text,
    description text,
    useful_for text,
    decided_at date,
    notes text,
    CONSTRAINT column_registry_promoted_chk CHECK ((((status = 'promoted'::text) AND (column_name IS NOT NULL) AND (data_type IS NOT NULL)) OR ((status <> 'promoted'::text) AND (column_name IS NULL) AND (data_type IS NULL)))),
    CONSTRAINT column_registry_signal_chk CHECK ((signal = ANY (ARRAY['metrics'::text, 'events'::text, 'resource'::text]))),
    CONSTRAINT column_registry_status_chk CHECK ((status = ANY (ARRAY['promoted'::text, 'kept'::text, 'denied'::text])))
);


--
-- Name: processed_batches; Type: TABLE; Schema: meta; Owner: -
--

CREATE TABLE meta.processed_batches (
    batch_hash text NOT NULL,
    processed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: events; Type: TABLE; Schema: raw; Owner: -
--

CREATE TABLE raw.events (
    event_time timestamp with time zone NOT NULL,
    event_name text NOT NULL,
    severity text,
    body text,
    user_email text,
    user_account_id text,
    organization_id text,
    session_id uuid,
    prompt_id uuid,
    model text,
    tool_name text,
    duration_ms bigint,
    input_tokens bigint,
    output_tokens bigint,
    cache_creation_tokens bigint,
    cache_read_tokens bigint,
    cost_usd double precision,
    cc_version text,
    event_sequence bigint,
    request_id text,
    speed text,
    effort text,
    query_source text,
    prompt_length bigint,
    command_name text,
    command_source text,
    hook_name text,
    hook_event text,
    from_mode text,
    to_mode text,
    trigger text,
    skill_name text,
    agent_name text,
    plugin_name text,
    marketplace_name text,
    mcp_server_name text,
    mcp_tool_name text,
    mention_type text,
    success_bool boolean,
    tool_use_id text,
    decision text,
    source text,
    scope_name text,
    scope_version text,
    severity_number smallint,
    log_trace_id text,
    log_span_id text,
    dropped_attributes_count integer
);


--
-- Name: metrics; Type: TABLE; Schema: raw; Owner: -
--

CREATE TABLE raw.metrics (
    ts timestamp with time zone NOT NULL,
    metric_name text NOT NULL,
    metric_type text NOT NULL,
    value double precision,
    count bigint,
    value_kind text,
    user_email text,
    user_account_id text,
    organization_id text,
    session_id uuid,
    model text,
    type_label text,
    tool_name text,
    decision text,
    source text,
    language text,
    usage_window text,
    cc_version text,
    query_source text,
    effort text,
    speed text,
    agent_name text,
    skill_name text,
    plugin_name text,
    marketplace_name text,
    start_type text,
    scope_name text,
    scope_version text
);


--
-- Name: column_registry column_registry_pkey; Type: CONSTRAINT; Schema: meta; Owner: -
--

ALTER TABLE ONLY meta.column_registry
    ADD CONSTRAINT column_registry_pkey PRIMARY KEY (signal, signal_name, attr_path);


--
-- Name: processed_batches processed_batches_pkey; Type: CONSTRAINT; Schema: meta; Owner: -
--

ALTER TABLE ONLY meta.processed_batches
    ADD CONSTRAINT processed_batches_pkey PRIMARY KEY (batch_hash);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: events_name_time_idx; Type: INDEX; Schema: raw; Owner: -
--

CREATE INDEX events_name_time_idx ON raw.events USING btree (event_name, event_time DESC);


--
-- Name: events_session_idx; Type: INDEX; Schema: raw; Owner: -
--

CREATE INDEX events_session_idx ON raw.events USING btree (session_id);


--
-- Name: events_time_idx; Type: INDEX; Schema: raw; Owner: -
--

CREATE INDEX events_time_idx ON raw.events USING btree (event_time DESC);


--
-- Name: metrics_name_ts_idx; Type: INDEX; Schema: raw; Owner: -
--

CREATE INDEX metrics_name_ts_idx ON raw.metrics USING btree (metric_name, ts DESC);


--
-- Name: metrics_ts_idx; Type: INDEX; Schema: raw; Owner: -
--

CREATE INDEX metrics_ts_idx ON raw.metrics USING btree (ts DESC);


--
-- Name: metrics_user_ts_idx; Type: INDEX; Schema: raw; Owner: -
--

CREATE INDEX metrics_user_ts_idx ON raw.metrics USING btree (user_email, ts DESC);


--
-- PostgreSQL database dump complete
--

\unrestrict dbmate


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('20260713170001'),
    ('20260713170002'),
    ('20260713170003'),
    ('20260713170004'),
    ('20260713170005');
