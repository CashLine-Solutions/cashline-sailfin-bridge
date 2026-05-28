SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: cashline_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cashline_snapshots (
    id bigint NOT NULL,
    loaded_at timestamp(6) without time zone NOT NULL,
    sha256 character varying NOT NULL,
    schema_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: cashline_snapshots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cashline_snapshots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cashline_snapshots_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cashline_snapshots_id_seq OWNED BY public.cashline_snapshots.id;


--
-- Name: cluster_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cluster_assignments (
    id bigint NOT NULL,
    cluster_id bigint NOT NULL,
    sobject_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: cluster_assignments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cluster_assignments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cluster_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cluster_assignments_id_seq OWNED BY public.cluster_assignments.id;


--
-- Name: clusters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clusters (
    id bigint NOT NULL,
    extraction_run_id bigint NOT NULL,
    name character varying NOT NULL,
    color character varying,
    user_modified boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: clusters_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.clusters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: clusters_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.clusters_id_seq OWNED BY public.clusters.id;


--
-- Name: embedding_caches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.embedding_caches (
    id bigint NOT NULL,
    content_sha256 character varying NOT NULL,
    embedding public.vector(1536) NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: embedding_caches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.embedding_caches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: embedding_caches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.embedding_caches_id_seq OWNED BY public.embedding_caches.id;


--
-- Name: embedding_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.embedding_sources (
    id bigint NOT NULL,
    sfield_id bigint NOT NULL,
    content_sha256 character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: embedding_sources_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.embedding_sources_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: embedding_sources_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.embedding_sources_id_seq OWNED BY public.embedding_sources.id;


--
-- Name: extraction_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.extraction_runs (
    id bigint NOT NULL,
    user_id bigint,
    status character varying DEFAULT 'queued'::character varying NOT NULL,
    api_version character varying NOT NULL,
    started_at timestamp(6) without time zone,
    completed_at timestamp(6) without time zone,
    include_sensitive boolean DEFAULT false NOT NULL,
    retained_until timestamp(6) without time zone,
    seed_objects jsonb DEFAULT '[]'::jsonb NOT NULL,
    walk_options jsonb DEFAULT '{}'::jsonb NOT NULL,
    limits_at_start jsonb,
    limits_at_end jsonb,
    installed_packages jsonb,
    partial_failures jsonb DEFAULT '[]'::jsonb NOT NULL,
    error_message text,
    content_hash text,
    directory_token character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: extraction_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.extraction_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: extraction_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.extraction_runs_id_seq OWNED BY public.extraction_runs.id;


--
-- Name: field_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.field_profiles (
    id bigint NOT NULL,
    object_profile_id bigint NOT NULL,
    sfield_id bigint NOT NULL,
    null_rate double precision,
    distinct_count integer,
    distinct_count_suppressed boolean DEFAULT false NOT NULL,
    min_length integer,
    max_length integer,
    avg_length double precision,
    min_value numeric(30,6),
    max_value numeric(30,6),
    mean_value numeric(30,6),
    p50_value numeric(30,6),
    p95_value numeric(30,6),
    min_date timestamp(6) without time zone,
    max_date timestamp(6) without time zone,
    top_values jsonb DEFAULT '[]'::jsonb NOT NULL,
    sample_values jsonb DEFAULT '[]'::jsonb NOT NULL,
    sensitive_override_used boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: field_profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.field_profiles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: field_profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.field_profiles_id_seq OWNED BY public.field_profiles.id;


--
-- Name: good_job_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_job_batches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    description text,
    serialized_properties jsonb,
    on_finish text,
    on_success text,
    on_discard text,
    callback_queue_name text,
    callback_priority integer,
    enqueued_at timestamp(6) without time zone,
    discarded_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    jobs_finished_at timestamp(6) without time zone
);


--
-- Name: good_job_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_job_executions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    active_job_id uuid NOT NULL,
    job_class text,
    queue_name text,
    serialized_params jsonb,
    scheduled_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    error text,
    error_event smallint,
    error_backtrace text[],
    process_id uuid,
    duration interval
);


--
-- Name: good_job_processes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_job_processes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    state jsonb,
    lock_type smallint
);


--
-- Name: good_job_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_job_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    key text,
    value jsonb
);


--
-- Name: good_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.good_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    queue_name text,
    priority integer,
    serialized_params jsonb,
    scheduled_at timestamp(6) without time zone,
    performed_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    error text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    active_job_id uuid,
    concurrency_key text,
    cron_key text,
    retried_good_job_id uuid,
    cron_at timestamp(6) without time zone,
    batch_id uuid,
    batch_callback_id uuid,
    is_discrete boolean,
    executions_count integer,
    job_class text,
    error_event smallint,
    labels text[],
    locked_by_id uuid,
    locked_at timestamp(6) without time zone,
    lock_type smallint
);


--
-- Name: mapping_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mapping_entries (
    id bigint NOT NULL,
    cashline_snapshot_id bigint NOT NULL,
    source_field_id bigint,
    updated_by_id bigint,
    target_class character varying,
    target_field character varying,
    mapping_type character varying,
    confidence character varying,
    reviewed boolean DEFAULT false NOT NULL,
    transformation_note text,
    source_citation text,
    needs_crosswalk boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: mapping_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mapping_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mapping_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mapping_entries_id_seq OWNED BY public.mapping_entries.id;


--
-- Name: mapping_proposals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mapping_proposals (
    id bigint NOT NULL,
    source_field_id bigint NOT NULL,
    cashline_snapshot_id bigint NOT NULL,
    target_class character varying NOT NULL,
    target_field character varying NOT NULL,
    score double precision DEFAULT 0.0 NOT NULL,
    signals jsonb DEFAULT '{}'::jsonb NOT NULL,
    state character varying DEFAULT 'open'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: mapping_proposals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mapping_proposals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mapping_proposals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mapping_proposals_id_seq OWNED BY public.mapping_proposals.id;


--
-- Name: mapping_value_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mapping_value_entries (
    id bigint NOT NULL,
    mapping_entry_id bigint NOT NULL,
    source_value character varying NOT NULL,
    target_enum_value character varying,
    notes text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: mapping_value_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mapping_value_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mapping_value_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mapping_value_entries_id_seq OWNED BY public.mapping_value_entries.id;


--
-- Name: object_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.object_profiles (
    id bigint NOT NULL,
    extraction_run_id bigint NOT NULL,
    sobject_id bigint NOT NULL,
    record_count bigint,
    profiled_at timestamp(6) without time zone,
    sampled boolean DEFAULT false NOT NULL,
    sample_size integer,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    failure_reason text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: object_profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.object_profiles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: object_profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.object_profiles_id_seq OWNED BY public.object_profiles.id;


--
-- Name: run_diffs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.run_diffs (
    id bigint NOT NULL,
    run_a_id bigint NOT NULL,
    run_b_id bigint NOT NULL,
    computed_at timestamp(6) without time zone NOT NULL,
    diff jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: run_diffs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.run_diffs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: run_diffs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.run_diffs_id_seq OWNED BY public.run_diffs.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    ip_address character varying,
    user_agent character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sessions_id_seq OWNED BY public.sessions.id;


--
-- Name: sfields; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sfields (
    id bigint NOT NULL,
    sobject_id bigint NOT NULL,
    api_name character varying NOT NULL,
    label character varying,
    data_type character varying,
    length integer,
    nillable boolean DEFAULT true NOT NULL,
    calculated boolean DEFAULT false NOT NULL,
    calculated_formula text,
    encrypted boolean DEFAULT false NOT NULL,
    name_field boolean DEFAULT false NOT NULL,
    compound_field_name character varying,
    picklist_count integer DEFAULT 0 NOT NULL,
    references_count integer DEFAULT 0 NOT NULL,
    namespace_prefix character varying,
    accessible boolean DEFAULT true NOT NULL,
    createable boolean DEFAULT true NOT NULL,
    updateable boolean DEFAULT true NOT NULL,
    filterable boolean DEFAULT true NOT NULL,
    raw_describe jsonb DEFAULT '{}'::jsonb NOT NULL,
    tooling_metadata jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    sensitivity character varying DEFAULT 'unknown_sensitivity'::character varying NOT NULL,
    sensitivity_signals jsonb DEFAULT '[]'::jsonb NOT NULL,
    compliance_group character varying,
    security_classification character varying
);


--
-- Name: sfields_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sfields_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sfields_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sfields_id_seq OWNED BY public.sfields.id;


--
-- Name: sobjects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sobjects (
    id bigint NOT NULL,
    extraction_run_id bigint NOT NULL,
    api_name character varying NOT NULL,
    label character varying,
    namespace_prefix character varying,
    custom boolean DEFAULT false NOT NULL,
    is_name_field boolean DEFAULT false NOT NULL,
    raw_describe jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: sobjects_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sobjects_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sobjects_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sobjects_id_seq OWNED BY public.sobjects.id;


--
-- Name: spicklist_values; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.spicklist_values (
    id bigint NOT NULL,
    sfield_id bigint NOT NULL,
    value character varying NOT NULL,
    label character varying,
    active boolean DEFAULT true NOT NULL,
    default_value boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: spicklist_values_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.spicklist_values_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: spicklist_values_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.spicklist_values_id_seq OWNED BY public.spicklist_values.id;


--
-- Name: srecord_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.srecord_types (
    id bigint NOT NULL,
    sobject_id bigint NOT NULL,
    salesforce_id character varying NOT NULL,
    developer_name character varying,
    label character varying,
    available boolean DEFAULT true NOT NULL,
    default_mapping boolean DEFAULT false NOT NULL,
    picklist_values jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: srecord_types_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.srecord_types_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: srecord_types_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.srecord_types_id_seq OWNED BY public.srecord_types.id;


--
-- Name: srelationships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.srelationships (
    id bigint NOT NULL,
    extraction_run_id bigint NOT NULL,
    source_sobject_id bigint NOT NULL,
    target_sobject_id bigint,
    source_field_id bigint,
    relationship_name character varying,
    cascade_delete boolean DEFAULT false NOT NULL,
    restricted_delete boolean DEFAULT false NOT NULL,
    polymorphic boolean DEFAULT false NOT NULL,
    reference_to_api_names jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: srelationships_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.srelationships_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: srelationships_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.srelationships_id_seq OWNED BY public.srelationships.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email_address character varying NOT NULL,
    password_digest character varying NOT NULL,
    role integer DEFAULT 0 NOT NULL,
    sensitive_data_access boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: cashline_snapshots id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cashline_snapshots ALTER COLUMN id SET DEFAULT nextval('public.cashline_snapshots_id_seq'::regclass);


--
-- Name: cluster_assignments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cluster_assignments ALTER COLUMN id SET DEFAULT nextval('public.cluster_assignments_id_seq'::regclass);


--
-- Name: clusters id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clusters ALTER COLUMN id SET DEFAULT nextval('public.clusters_id_seq'::regclass);


--
-- Name: embedding_caches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embedding_caches ALTER COLUMN id SET DEFAULT nextval('public.embedding_caches_id_seq'::regclass);


--
-- Name: embedding_sources id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embedding_sources ALTER COLUMN id SET DEFAULT nextval('public.embedding_sources_id_seq'::regclass);


--
-- Name: extraction_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extraction_runs ALTER COLUMN id SET DEFAULT nextval('public.extraction_runs_id_seq'::regclass);


--
-- Name: field_profiles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.field_profiles ALTER COLUMN id SET DEFAULT nextval('public.field_profiles_id_seq'::regclass);


--
-- Name: mapping_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mapping_entries ALTER COLUMN id SET DEFAULT nextval('public.mapping_entries_id_seq'::regclass);


--
-- Name: mapping_proposals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mapping_proposals ALTER COLUMN id SET DEFAULT nextval('public.mapping_proposals_id_seq'::regclass);


--
-- Name: mapping_value_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mapping_value_entries ALTER COLUMN id SET DEFAULT nextval('public.mapping_value_entries_id_seq'::regclass);


--
-- Name: object_profiles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.object_profiles ALTER COLUMN id SET DEFAULT nextval('public.object_profiles_id_seq'::regclass);


--
-- Name: run_diffs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_diffs ALTER COLUMN id SET DEFAULT nextval('public.run_diffs_id_seq'::regclass);


--
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: sfields id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sfields ALTER COLUMN id SET DEFAULT nextval('public.sfields_id_seq'::regclass);


--
-- Name: sobjects id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sobjects ALTER COLUMN id SET DEFAULT nextval('public.sobjects_id_seq'::regclass);


--
-- Name: spicklist_values id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.spicklist_values ALTER COLUMN id SET DEFAULT nextval('public.spicklist_values_id_seq'::regclass);


--
-- Name: srecord_types id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.srecord_types ALTER COLUMN id SET DEFAULT nextval('public.srecord_types_id_seq'::regclass);


--
-- Name: srelationships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.srelationships ALTER COLUMN id SET DEFAULT nextval('public.srelationships_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: cashline_snapshots cashline_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cashline_snapshots
    ADD CONSTRAINT cashline_snapshots_pkey PRIMARY KEY (id);


--
-- Name: cluster_assignments cluster_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cluster_assignments
    ADD CONSTRAINT cluster_assignments_pkey PRIMARY KEY (id);


--
-- Name: clusters clusters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clusters
    ADD CONSTRAINT clusters_pkey PRIMARY KEY (id);


--
-- Name: embedding_caches embedding_caches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embedding_caches
    ADD CONSTRAINT embedding_caches_pkey PRIMARY KEY (id);


--
-- Name: embedding_sources embedding_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embedding_sources
    ADD CONSTRAINT embedding_sources_pkey PRIMARY KEY (id);


--
-- Name: extraction_runs extraction_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extraction_runs
    ADD CONSTRAINT extraction_runs_pkey PRIMARY KEY (id);


--
-- Name: field_profiles field_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.field_profiles
    ADD CONSTRAINT field_profiles_pkey PRIMARY KEY (id);


--
-- Name: good_job_batches good_job_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_job_batches
    ADD CONSTRAINT good_job_batches_pkey PRIMARY KEY (id);


--
-- Name: good_job_executions good_job_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_job_executions
    ADD CONSTRAINT good_job_executions_pkey PRIMARY KEY (id);


--
-- Name: good_job_processes good_job_processes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_job_processes
    ADD CONSTRAINT good_job_processes_pkey PRIMARY KEY (id);


--
-- Name: good_job_settings good_job_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_job_settings
    ADD CONSTRAINT good_job_settings_pkey PRIMARY KEY (id);


--
-- Name: good_jobs good_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.good_jobs
    ADD CONSTRAINT good_jobs_pkey PRIMARY KEY (id);


--
-- Name: mapping_entries mapping_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mapping_entries
    ADD CONSTRAINT mapping_entries_pkey PRIMARY KEY (id);


--
-- Name: mapping_proposals mapping_proposals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mapping_proposals
    ADD CONSTRAINT mapping_proposals_pkey PRIMARY KEY (id);


--
-- Name: mapping_value_entries mapping_value_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mapping_value_entries
    ADD CONSTRAINT mapping_value_entries_pkey PRIMARY KEY (id);


--
-- Name: object_profiles object_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.object_profiles
    ADD CONSTRAINT object_profiles_pkey PRIMARY KEY (id);


--
-- Name: run_diffs run_diffs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_diffs
    ADD CONSTRAINT run_diffs_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: sfields sfields_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sfields
    ADD CONSTRAINT sfields_pkey PRIMARY KEY (id);


--
-- Name: sobjects sobjects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sobjects
    ADD CONSTRAINT sobjects_pkey PRIMARY KEY (id);


--
-- Name: spicklist_values spicklist_values_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.spicklist_values
    ADD CONSTRAINT spicklist_values_pkey PRIMARY KEY (id);


--
-- Name: srecord_types srecord_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.srecord_types
    ADD CONSTRAINT srecord_types_pkey PRIMARY KEY (id);


--
-- Name: srelationships srelationships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.srelationships
    ADD CONSTRAINT srelationships_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: idx_on_cashline_snapshot_id_target_class_target_fie_701aa660bf; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_cashline_snapshot_id_target_class_target_fie_701aa660bf ON public.mapping_entries USING btree (cashline_snapshot_id, target_class, target_field);


--
-- Name: idx_on_mapping_entry_id_source_value_f1873b6212; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_mapping_entry_id_source_value_f1873b6212 ON public.mapping_value_entries USING btree (mapping_entry_id, source_value);


--
-- Name: idx_on_source_field_id_target_class_target_field_st_892dcbea46; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_source_field_id_target_class_target_field_st_892dcbea46 ON public.mapping_proposals USING btree (source_field_id, target_class, target_field, state);


--
-- Name: idx_srels_run_src_tgt; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_srels_run_src_tgt ON public.srelationships USING btree (extraction_run_id, source_sobject_id, target_sobject_id);


--
-- Name: index_cashline_snapshots_on_loaded_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_cashline_snapshots_on_loaded_at ON public.cashline_snapshots USING btree (loaded_at);


--
-- Name: index_cluster_assignments_on_cluster_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_cluster_assignments_on_cluster_id ON public.cluster_assignments USING btree (cluster_id);


--
-- Name: index_cluster_assignments_on_cluster_id_and_sobject_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_cluster_assignments_on_cluster_id_and_sobject_id ON public.cluster_assignments USING btree (cluster_id, sobject_id);


--
-- Name: index_cluster_assignments_on_sobject_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_cluster_assignments_on_sobject_id ON public.cluster_assignments USING btree (sobject_id);


--
-- Name: index_cluster_assignments_on_sobject_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_cluster_assignments_on_sobject_unique ON public.cluster_assignments USING btree (sobject_id);


--
-- Name: index_clusters_on_extraction_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_clusters_on_extraction_run_id ON public.clusters USING btree (extraction_run_id);


--
-- Name: index_clusters_on_extraction_run_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_clusters_on_extraction_run_id_and_name ON public.clusters USING btree (extraction_run_id, name);


--
-- Name: index_embedding_caches_on_content_sha256; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_embedding_caches_on_content_sha256 ON public.embedding_caches USING btree (content_sha256);


--
-- Name: index_embedding_sources_on_content_sha256; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_embedding_sources_on_content_sha256 ON public.embedding_sources USING btree (content_sha256);


--
-- Name: index_embedding_sources_on_sfield_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_embedding_sources_on_sfield_id ON public.embedding_sources USING btree (sfield_id);


--
-- Name: index_embedding_sources_on_sfield_id_and_content_sha256; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_embedding_sources_on_sfield_id_and_content_sha256 ON public.embedding_sources USING btree (sfield_id, content_sha256);


--
-- Name: index_extraction_runs_on_directory_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_extraction_runs_on_directory_token ON public.extraction_runs USING btree (directory_token);


--
-- Name: index_extraction_runs_on_include_sensitive; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_extraction_runs_on_include_sensitive ON public.extraction_runs USING btree (include_sensitive);


--
-- Name: index_extraction_runs_on_started_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_extraction_runs_on_started_at ON public.extraction_runs USING btree (started_at);


--
-- Name: index_extraction_runs_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_extraction_runs_on_status ON public.extraction_runs USING btree (status);


--
-- Name: index_extraction_runs_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_extraction_runs_on_user_id ON public.extraction_runs USING btree (user_id);


--
-- Name: index_field_profiles_on_object_profile_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_field_profiles_on_object_profile_id ON public.field_profiles USING btree (object_profile_id);


--
-- Name: index_field_profiles_on_object_profile_id_and_sfield_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_field_profiles_on_object_profile_id_and_sfield_id ON public.field_profiles USING btree (object_profile_id, sfield_id);


--
-- Name: index_field_profiles_on_sfield_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_field_profiles_on_sfield_id ON public.field_profiles USING btree (sfield_id);


--
-- Name: index_good_job_executions_on_active_job_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_job_executions_on_active_job_id_and_created_at ON public.good_job_executions USING btree (active_job_id, created_at);


--
-- Name: index_good_job_executions_on_process_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_job_executions_on_process_id_and_created_at ON public.good_job_executions USING btree (process_id, created_at);


--
-- Name: index_good_job_jobs_for_candidate_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_job_jobs_for_candidate_lookup ON public.good_jobs USING btree (priority, created_at) WHERE (finished_at IS NULL);


--
-- Name: index_good_job_settings_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_good_job_settings_on_key ON public.good_job_settings USING btree (key);


--
-- Name: index_good_jobs_for_candidate_dequeue_unlocked; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_for_candidate_dequeue_unlocked ON public.good_jobs USING btree (priority, scheduled_at, id) WHERE ((finished_at IS NULL) AND (locked_by_id IS NULL));


--
-- Name: index_good_jobs_jobs_on_finished_at_only; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_jobs_on_finished_at_only ON public.good_jobs USING btree (finished_at) WHERE (finished_at IS NOT NULL);


--
-- Name: index_good_jobs_jobs_on_priority_created_at_when_unfinished; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_jobs_on_priority_created_at_when_unfinished ON public.good_jobs USING btree (priority DESC NULLS LAST, created_at) WHERE (finished_at IS NULL);


--
-- Name: index_good_jobs_on_active_job_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_active_job_id_and_created_at ON public.good_jobs USING btree (active_job_id, created_at);


--
-- Name: index_good_jobs_on_batch_callback_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_batch_callback_id ON public.good_jobs USING btree (batch_callback_id) WHERE (batch_callback_id IS NOT NULL);


--
-- Name: index_good_jobs_on_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_batch_id ON public.good_jobs USING btree (batch_id) WHERE (batch_id IS NOT NULL);


--
-- Name: index_good_jobs_on_concurrency_key_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_concurrency_key_and_created_at ON public.good_jobs USING btree (concurrency_key, created_at);


--
-- Name: index_good_jobs_on_concurrency_key_when_unfinished; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_concurrency_key_when_unfinished ON public.good_jobs USING btree (concurrency_key) WHERE (finished_at IS NULL);


--
-- Name: index_good_jobs_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_created_at ON public.good_jobs USING btree (created_at);


--
-- Name: index_good_jobs_on_cron_key_and_created_at_cond; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_cron_key_and_created_at_cond ON public.good_jobs USING btree (cron_key, created_at) WHERE (cron_key IS NOT NULL);


--
-- Name: index_good_jobs_on_cron_key_and_cron_at_cond; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_good_jobs_on_cron_key_and_cron_at_cond ON public.good_jobs USING btree (cron_key, cron_at) WHERE (cron_key IS NOT NULL);


--
-- Name: index_good_jobs_on_discarded; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_discarded ON public.good_jobs USING btree (finished_at DESC) WHERE ((finished_at IS NOT NULL) AND (error IS NOT NULL));


--
-- Name: index_good_jobs_on_job_class; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_job_class ON public.good_jobs USING btree (job_class);


--
-- Name: index_good_jobs_on_labels; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_labels ON public.good_jobs USING gin (labels) WHERE (labels IS NOT NULL);


--
-- Name: index_good_jobs_on_locked_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_locked_by_id ON public.good_jobs USING btree (locked_by_id) WHERE (locked_by_id IS NOT NULL);


--
-- Name: index_good_jobs_on_priority_scheduled_at_unfinished; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_priority_scheduled_at_unfinished ON public.good_jobs USING btree (priority, scheduled_at, id) WHERE (finished_at IS NULL);


--
-- Name: index_good_jobs_on_priority_scheduled_at_unfinished_unlocked; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_priority_scheduled_at_unfinished_unlocked ON public.good_jobs USING btree (priority, scheduled_at) WHERE ((finished_at IS NULL) AND (locked_by_id IS NULL));


--
-- Name: index_good_jobs_on_queue_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_queue_name ON public.good_jobs USING btree (queue_name);


--
-- Name: index_good_jobs_on_queue_name_and_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_queue_name_and_scheduled_at ON public.good_jobs USING btree (queue_name, scheduled_at) WHERE (finished_at IS NULL);


--
-- Name: index_good_jobs_on_queue_name_priority_scheduled_at_unfinished; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_queue_name_priority_scheduled_at_unfinished ON public.good_jobs USING btree (queue_name, scheduled_at, id) WHERE (finished_at IS NULL);


--
-- Name: index_good_jobs_on_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_scheduled_at ON public.good_jobs USING btree (scheduled_at) WHERE (finished_at IS NULL);


--
-- Name: index_good_jobs_on_scheduled_at_and_queue_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_scheduled_at_and_queue_name ON public.good_jobs USING btree (scheduled_at, queue_name);


--
-- Name: index_good_jobs_on_unfinished_or_errored; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_good_jobs_on_unfinished_or_errored ON public.good_jobs USING btree (id) WHERE ((finished_at IS NULL) OR (error IS NOT NULL));


--
-- Name: index_mapping_entries_on_cashline_snapshot_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mapping_entries_on_cashline_snapshot_id ON public.mapping_entries USING btree (cashline_snapshot_id);


--
-- Name: index_mapping_entries_on_null_target; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_mapping_entries_on_null_target ON public.mapping_entries USING btree (cashline_snapshot_id, COALESCE(source_field_id, ('-1'::integer)::bigint)) WHERE (target_class IS NULL);


--
-- Name: index_mapping_entries_on_source_field_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mapping_entries_on_source_field_id ON public.mapping_entries USING btree (source_field_id);


--
-- Name: index_mapping_entries_on_targeted_edge; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_mapping_entries_on_targeted_edge ON public.mapping_entries USING btree (cashline_snapshot_id, COALESCE(source_field_id, ('-1'::integer)::bigint), target_class, target_field) WHERE (target_class IS NOT NULL);


--
-- Name: index_mapping_entries_on_updated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mapping_entries_on_updated_by_id ON public.mapping_entries USING btree (updated_by_id);


--
-- Name: index_mapping_proposals_on_cashline_snapshot_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mapping_proposals_on_cashline_snapshot_id ON public.mapping_proposals USING btree (cashline_snapshot_id);


--
-- Name: index_mapping_proposals_on_cashline_snapshot_id_and_state; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mapping_proposals_on_cashline_snapshot_id_and_state ON public.mapping_proposals USING btree (cashline_snapshot_id, state);


--
-- Name: index_mapping_proposals_on_edge; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_mapping_proposals_on_edge ON public.mapping_proposals USING btree (source_field_id, cashline_snapshot_id, target_class, target_field);


--
-- Name: index_mapping_proposals_on_source_field_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mapping_proposals_on_source_field_id ON public.mapping_proposals USING btree (source_field_id);


--
-- Name: index_mapping_value_entries_on_mapping_entry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mapping_value_entries_on_mapping_entry_id ON public.mapping_value_entries USING btree (mapping_entry_id);


--
-- Name: index_object_profiles_on_extraction_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_object_profiles_on_extraction_run_id ON public.object_profiles USING btree (extraction_run_id);


--
-- Name: index_object_profiles_on_extraction_run_id_and_sobject_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_object_profiles_on_extraction_run_id_and_sobject_id ON public.object_profiles USING btree (extraction_run_id, sobject_id);


--
-- Name: index_object_profiles_on_sobject_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_object_profiles_on_sobject_id ON public.object_profiles USING btree (sobject_id);


--
-- Name: index_run_diffs_on_run_a_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_run_diffs_on_run_a_id ON public.run_diffs USING btree (run_a_id);


--
-- Name: index_run_diffs_on_run_a_id_and_run_b_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_run_diffs_on_run_a_id_and_run_b_id ON public.run_diffs USING btree (run_a_id, run_b_id);


--
-- Name: index_run_diffs_on_run_b_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_run_diffs_on_run_b_id ON public.run_diffs USING btree (run_b_id);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_sfields_on_api_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sfields_on_api_name ON public.sfields USING btree (api_name);


--
-- Name: index_sfields_on_calculated; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sfields_on_calculated ON public.sfields USING btree (calculated);


--
-- Name: index_sfields_on_sensitivity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sfields_on_sensitivity ON public.sfields USING btree (sensitivity);


--
-- Name: index_sfields_on_sobject_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sfields_on_sobject_id ON public.sfields USING btree (sobject_id);


--
-- Name: index_sfields_on_sobject_id_and_api_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sfields_on_sobject_id_and_api_name ON public.sfields USING btree (sobject_id, api_name);


--
-- Name: index_sobjects_on_api_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sobjects_on_api_name ON public.sobjects USING btree (api_name);


--
-- Name: index_sobjects_on_extraction_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sobjects_on_extraction_run_id ON public.sobjects USING btree (extraction_run_id);


--
-- Name: index_sobjects_on_extraction_run_id_and_api_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_sobjects_on_extraction_run_id_and_api_name ON public.sobjects USING btree (extraction_run_id, api_name);


--
-- Name: index_spicklist_values_on_sfield_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_spicklist_values_on_sfield_id ON public.spicklist_values USING btree (sfield_id);


--
-- Name: index_spicklist_values_on_sfield_id_and_value; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_spicklist_values_on_sfield_id_and_value ON public.spicklist_values USING btree (sfield_id, value);


--
-- Name: index_srecord_types_on_sobject_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_srecord_types_on_sobject_id ON public.srecord_types USING btree (sobject_id);


--
-- Name: index_srecord_types_on_sobject_id_and_salesforce_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_srecord_types_on_sobject_id_and_salesforce_id ON public.srecord_types USING btree (sobject_id, salesforce_id);


--
-- Name: index_srelationships_on_extraction_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_srelationships_on_extraction_run_id ON public.srelationships USING btree (extraction_run_id);


--
-- Name: index_srelationships_on_polymorphic; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_srelationships_on_polymorphic ON public.srelationships USING btree (polymorphic);


--
-- Name: index_srelationships_on_source_field_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_srelationships_on_source_field_id ON public.srelationships USING btree (source_field_id);


--
-- Name: index_srelationships_on_source_sobject_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_srelationships_on_source_sobject_id ON public.srelationships USING btree (source_sobject_id);


--
-- Name: index_srelationships_on_target_sobject_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_srelationships_on_target_sobject_id ON public.srelationships USING btree (target_sobject_id);


--
-- Name: index_users_on_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email_address ON public.users USING btree (email_address);


--
-- Name: index_users_on_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_role ON public.users USING btree (role);


--
-- Name: mapping_entries fk_rails_009d07f0f5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mapping_entries
    ADD CONSTRAINT fk_rails_009d07f0f5 FOREIGN KEY (source_field_id) REFERENCES public.sfields(id);


--
-- Name: field_profiles fk_rails_06ce0ffcd5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.field_profiles
    ADD CONSTRAINT fk_rails_06ce0ffcd5 FOREIGN KEY (sfield_id) REFERENCES public.sfields(id);


--
-- Name: run_diffs fk_rails_0a68f3ac63; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_diffs
    ADD CONSTRAINT fk_rails_0a68f3ac63 FOREIGN KEY (run_a_id) REFERENCES public.extraction_runs(id);


--
-- Name: mapping_entries fk_rails_22da455ed6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mapping_entries
    ADD CONSTRAINT fk_rails_22da455ed6 FOREIGN KEY (cashline_snapshot_id) REFERENCES public.cashline_snapshots(id);


--
-- Name: sfields fk_rails_2e78504528; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sfields
    ADD CONSTRAINT fk_rails_2e78504528 FOREIGN KEY (sobject_id) REFERENCES public.sobjects(id);


--
-- Name: field_profiles fk_rails_306fd95d96; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.field_profiles
    ADD CONSTRAINT fk_rails_306fd95d96 FOREIGN KEY (object_profile_id) REFERENCES public.object_profiles(id);


--
-- Name: sobjects fk_rails_31b28ecd97; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sobjects
    ADD CONSTRAINT fk_rails_31b28ecd97 FOREIGN KEY (extraction_run_id) REFERENCES public.extraction_runs(id);


--
-- Name: object_profiles fk_rails_40cefa1d40; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.object_profiles
    ADD CONSTRAINT fk_rails_40cefa1d40 FOREIGN KEY (extraction_run_id) REFERENCES public.extraction_runs(id);


--
-- Name: srelationships fk_rails_52d16ba36b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.srelationships
    ADD CONSTRAINT fk_rails_52d16ba36b FOREIGN KEY (target_sobject_id) REFERENCES public.sobjects(id);


--
-- Name: embedding_sources fk_rails_640539ee07; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.embedding_sources
    ADD CONSTRAINT fk_rails_640539ee07 FOREIGN KEY (sfield_id) REFERENCES public.sfields(id);


--
-- Name: cluster_assignments fk_rails_687f411867; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cluster_assignments
    ADD CONSTRAINT fk_rails_687f411867 FOREIGN KEY (cluster_id) REFERENCES public.clusters(id);


--
-- Name: srelationships fk_rails_6c908176dd; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.srelationships
    ADD CONSTRAINT fk_rails_6c908176dd FOREIGN KEY (source_field_id) REFERENCES public.sfields(id);


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: mapping_value_entries fk_rails_7e93349e8c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mapping_value_entries
    ADD CONSTRAINT fk_rails_7e93349e8c FOREIGN KEY (mapping_entry_id) REFERENCES public.mapping_entries(id);


--
-- Name: object_profiles fk_rails_7f4c3cd680; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.object_profiles
    ADD CONSTRAINT fk_rails_7f4c3cd680 FOREIGN KEY (sobject_id) REFERENCES public.sobjects(id);


--
-- Name: mapping_proposals fk_rails_88e1b1a430; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mapping_proposals
    ADD CONSTRAINT fk_rails_88e1b1a430 FOREIGN KEY (source_field_id) REFERENCES public.sfields(id);


--
-- Name: srelationships fk_rails_89c0ffb537; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.srelationships
    ADD CONSTRAINT fk_rails_89c0ffb537 FOREIGN KEY (source_sobject_id) REFERENCES public.sobjects(id);


--
-- Name: mapping_proposals fk_rails_8c70dcd3c0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mapping_proposals
    ADD CONSTRAINT fk_rails_8c70dcd3c0 FOREIGN KEY (cashline_snapshot_id) REFERENCES public.cashline_snapshots(id);


--
-- Name: extraction_runs fk_rails_a0981ca581; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extraction_runs
    ADD CONSTRAINT fk_rails_a0981ca581 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: srecord_types fk_rails_a2f48c6930; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.srecord_types
    ADD CONSTRAINT fk_rails_a2f48c6930 FOREIGN KEY (sobject_id) REFERENCES public.sobjects(id);


--
-- Name: run_diffs fk_rails_a42840fa71; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.run_diffs
    ADD CONSTRAINT fk_rails_a42840fa71 FOREIGN KEY (run_b_id) REFERENCES public.extraction_runs(id);


--
-- Name: srelationships fk_rails_a9ad89c1b7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.srelationships
    ADD CONSTRAINT fk_rails_a9ad89c1b7 FOREIGN KEY (extraction_run_id) REFERENCES public.extraction_runs(id);


--
-- Name: mapping_entries fk_rails_aecb1ad626; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mapping_entries
    ADD CONSTRAINT fk_rails_aecb1ad626 FOREIGN KEY (updated_by_id) REFERENCES public.users(id);


--
-- Name: cluster_assignments fk_rails_bdb7c6adbe; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cluster_assignments
    ADD CONSTRAINT fk_rails_bdb7c6adbe FOREIGN KEY (sobject_id) REFERENCES public.sobjects(id);


--
-- Name: spicklist_values fk_rails_e8555a132d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.spicklist_values
    ADD CONSTRAINT fk_rails_e8555a132d FOREIGN KEY (sfield_id) REFERENCES public.sfields(id);


--
-- Name: clusters fk_rails_ff97e2ea26; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clusters
    ADD CONSTRAINT fk_rails_ff97e2ea26 FOREIGN KEY (extraction_run_id) REFERENCES public.extraction_runs(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260528000007'),
('20260528000006'),
('20260528000005'),
('20260528000004'),
('20260528000003'),
('20260528000002'),
('20260528000001'),
('20260527202400'),
('20260527202300'),
('20260524021000'),
('20260524020000'),
('20260524014600'),
('20260524014500'),
('20260524014400'),
('20260524014300'),
('20260524014200'),
('20260524014100'),
('20260524014000'),
('20260524013900'),
('20260524000927'),
('20260524000926'),
('20260524000856');

