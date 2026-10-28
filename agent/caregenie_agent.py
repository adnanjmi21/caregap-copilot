"""CareGenie agent: UC function tools + AI Search retrievers + memory. All data is synthetic; guidelines are FICTIONAL.

Runs anywhere the Databricks SDK can authenticate (DATABRICKS_HOST / DATABRICKS_TOKEN).
Tool families (used by the evaluation in Phase 5):
  uc_function  -> exact or aggregate questions (overdue_hba1c_patients, patient_summary, queue_outreach)
  ai_search    -> guideline wording or similar cases (search_guidelines, search_encounters)
  memory       -> user preferences (get_user_preferences)
"""
import json, os, re, uuid
from dataclasses import dataclass, field

import mlflow
from databricks.sdk import WorkspaceClient

CATALOG_SCHEMA = "caregenie.caregenie"
WAREHOUSE_ID = os.environ.get("DATABRICKS_WAREHOUSE_ID", "acbfda553f05a6ec")
LLM_ENDPOINT = os.environ.get("CAREGENIE_LLM", "databricks-meta-llama-3-3-70b-instruct")
EMBED_ENDPOINT = "databricks-gte-large-en"
UUID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")

SYSTEM_PROMPT = """You are CareGenie, an assistant for care coordinators. All patients and guidelines are SYNTHETIC; guidelines are FICTIONAL and not medical advice. Say so when you quote a guideline.
Routing rules, follow them strictly:
- Exact or aggregate questions (counts, lists of overdue patients, one patient's status) -> use the SQL tools overdue_hba1c_patients or patient_summary.
- Questions about guideline wording -> search_guidelines. Questions about similar cases or what happened in visits -> search_encounters.
- Questions about the user's own preferences (preferred contact channel, clinic) -> get_user_preferences.
- queue_outreach is a WRITE action: call it only when the user explicitly asks to queue outreach, with a channel the user named or their saved preference.
Resolve follow-up words like 'that patient' or 'her' from earlier turns in this conversation. Never invent patient ids. Always state the as-of date or threshold you used."""

# --- tool descriptions live in a dict so the tool-confusion demo can swap them -----------------------------
GOOD_DESCRIPTIONS = {
    "overdue_hba1c_patients": "EXACT/AGGREGATE lookup in the gold table. Lists living diabetic patients (not prediabetic) whose last HbA1c is more than `months` months old or who were never tested. Use for 'how many', 'which patients', 'at which clinic'.",
    "patient_summary": "EXACT lookup for ONE patient id: cohort flags and HbA1c status. Use only when a patient id is known.",
    "queue_outreach": "WRITE action: queue one outreach request for a patient. Only when the user explicitly asks to queue outreach.",
    "search_guidelines": "Semantic search over FICTIONAL care guideline text. Use for 'what do the guidelines say about ...'. Not for counts or patient data.",
    "search_encounters": "Semantic search over synthetic encounter narratives. Use for 'find visits/cases like ...'. Not for exact counts.",
    "get_user_preferences": "Reads the saved preferences of the current user (preferred contact channel, default clinic).",
}
CONFUSING_DESCRIPTIONS = {**GOOD_DESCRIPTIONS,
    "overdue_hba1c_patients": "Finds patient information and HbA1c care information.",
    "patient_summary": "Finds patient information and HbA1c care information for a patient.",
    "search_guidelines": "Searches care information.",
    "search_encounters": "Searches care information.",
}

TOOL_FAMILY = {"overdue_hba1c_patients": "uc_function", "patient_summary": "uc_function", "queue_outreach": "uc_function",
               "search_guidelines": "ai_search", "search_encounters": "ai_search", "get_user_preferences": "memory"}


def _schema(name, desc, props, required):
    return {"type": "function", "function": {"name": name, "description": desc,
            "parameters": {"type": "object", "properties": props, "required": required}}}


def tool_specs(descriptions):
    d = descriptions
    return [
        _schema("overdue_hba1c_patients", d["overdue_hba1c_patients"],
                {"clinic_name": {"type": "string", "description": "Exact clinic name, omit for all clinics"},
                 "months": {"type": "integer", "description": "Months threshold, default 12"}}, []),
        _schema("patient_summary", d["patient_summary"], {"patient_id": {"type": "string"}}, ["patient_id"]),
        _schema("queue_outreach", d["queue_outreach"],
                {"patient_id": {"type": "string"}, "channel": {"type": "string", "enum": ["phone", "sms", "email", "mail"]},
                 "reason": {"type": "string"}}, ["patient_id", "channel", "reason"]),
        _schema("search_guidelines", d["search_guidelines"], {"query": {"type": "string"}}, ["query"]),
        _schema("search_encounters", d["search_encounters"], {"query": {"type": "string"}}, ["query"]),
        _schema("get_user_preferences", d["get_user_preferences"], {}, []),
    ]


@dataclass
class AgentConfig:
    num_results: int = 5            # chunks returned by AI Search tools
    scoped_output: bool = True      # True: trim tool output to the fields the model needs
    descriptions: dict = field(default_factory=lambda: GOOD_DESCRIPTIONS)
    max_tool_rounds: int = 5
    model: str = LLM_ENDPOINT


class Tools:
    def __init__(self, w, cfg, prefs=None):
        self.w, self.cfg, self.prefs = w, cfg, prefs
        self._openai = w.serving_endpoints.get_open_ai_client()

    def sql(self, stmt):
        r = self.w.statement_execution.execute_statement(warehouse_id=WAREHOUSE_ID, statement=stmt, wait_timeout="50s")
        if r.status.state.value != "SUCCEEDED":
            raise RuntimeError(r.status.error.message if r.status.error else str(r.status.state))
        cols = [c.name for c in r.manifest.schema.columns]
        return [dict(zip(cols, row)) for row in (r.result.data_array or [])]

    @mlflow.trace(span_type="TOOL")
    def overdue_hba1c_patients(self, clinic_name=None, months=12):
        clinic = "NULL" if not clinic_name else "'" + clinic_name.replace("'", "''") + "'"
        rows = self.sql(f"SELECT * FROM {CATALOG_SCHEMA}.overdue_hba1c_patients({clinic}, {int(months)})")
        out = {"threshold_months": int(months), "count": len(rows)}
        keep = ("patient_id", "clinic", "months_since_last_hba1c") if self.cfg.scoped_output else None
        out["patients"] = [{k: v for k, v in r.items() if keep is None or k in keep} for r in rows[:25]]
        return out

    @mlflow.trace(span_type="TOOL")
    def patient_summary(self, patient_id):
        if not UUID_RE.match(patient_id):
            return {"error": "patient_id must be a UUID"}
        return {"rows": self.sql(f"SELECT * FROM {CATALOG_SCHEMA}.patient_summary('{patient_id}')")}

    @mlflow.trace(span_type="TOOL")
    def queue_outreach(self, patient_id, channel, reason):
        if not UUID_RE.match(patient_id):
            return {"error": "patient_id must be a UUID"}
        r = reason.replace("'", "''")[:200]
        try:
            self.sql(f"CALL {CATALOG_SCHEMA}.queue_outreach('{patient_id}', '{channel}', '{r}')")
            return {"queued": True}
        except RuntimeError as e:
            return {"queued": False, "error": str(e)[:200]}

    def _search(self, index, columns, query, vector=False):
        kw = dict(index_name=f"{CATALOG_SCHEMA}.{index}", columns=columns, num_results=self.cfg.num_results)
        if vector:
            kw["query_vector"] = self._openai.embeddings.create(model=EMBED_ENDPOINT, input=[query]).data[0].embedding
        else:
            kw["query_text"] = query
        res = self.w.vector_search_indexes.query_index(**kw)
        return [dict(zip(columns + ["score"], row)) for row in (res.result.data_array or [])]

    @mlflow.trace(span_type="RETRIEVER")
    def search_guidelines(self, query):
        rows = self._search("guidelines_index", ["guideline_id", "title", "content"], query)
        return {"note": "FICTIONAL guidelines", "results": rows}

    @mlflow.trace(span_type="RETRIEVER")
    def search_encounters(self, query):
        cols = ["chunk_id", "encounter_date", "chunk_text"] if self.cfg.scoped_output else \
               ["chunk_id", "patient_id", "clinic", "encounter_date", "chunk_text"]
        return {"results": self._search("encounter_chunks_v2_index", cols, query, vector=True)}

    @mlflow.trace(span_type="TOOL")
    def get_user_preferences(self):
        if self.prefs is None:
            return {"error": "No preference store is configured"}
        return self.prefs.get(self.w.current_user.me().user_name)


class LakebaseCatalogPreferences:
    """Long-term memory read path: Lakebase registered in Unity Catalog (caregenie_lakebase), read-only, via the SQL warehouse.
    Writes go straight to Postgres (agent/lakebase_prefs.py), which needs network access to the Lakebase host."""
    def __init__(self, tools):
        self.t = tools

    def get(self, user_name):
        u = user_name.replace("'", "''")
        rows = self.t.sql(f"SELECT preferred_channel, default_clinic FROM caregenie_lakebase.public.user_preferences WHERE user_name = '{u}'")
        return rows[0] if rows else {"error": "No saved preferences for this user"}


class ThreadStore:
    """Short-term memory: conversation turns checkpointed to a Delta table, keyed by thread_id."""
    TABLE = f"{CATALOG_SCHEMA}.agent_threads"

    def __init__(self, tools):
        self.t = tools
        self.t.sql(f"CREATE TABLE IF NOT EXISTS {self.TABLE} (thread_id STRING, seq BIGINT, role STRING, content STRING, ts TIMESTAMP) "
                   "COMMENT 'Agent short-term memory: one row per user or assistant message per conversation thread.' CLUSTER BY (thread_id)")

    def load(self, thread_id):
        rows = self.t.sql(f"SELECT role, content FROM {self.TABLE} WHERE thread_id = '{thread_id}' ORDER BY seq")
        return [{"role": r["role"], "content": r["content"]} for r in rows]

    def append(self, thread_id, start_seq, messages):
        vals = ", ".join(f"('{thread_id}', {start_seq + i}, '{m['role']}', '{m['content'].replace(chr(39), chr(39) * 2)}', current_timestamp())"
                         for i, m in enumerate(messages))
        self.t.sql(f"INSERT INTO {self.TABLE} VALUES {vals}")


class CareGenieAgent:
    def __init__(self, cfg=None, prefs=None, w=None):
        self.cfg = cfg or AgentConfig()
        self.w = w or WorkspaceClient()
        self.tools = Tools(self.w, self.cfg, prefs)
        if prefs is None:
            self.tools.prefs = LakebaseCatalogPreferences(self.tools)
        self.client = self.tools._openai
        self.threads = ThreadStore(self.tools)
        self.specs = tool_specs(self.cfg.descriptions)

    @mlflow.trace(span_type="AGENT")
    def ask(self, question, thread_id=None):
        thread_id = thread_id or str(uuid.uuid4())
        history = self.threads.load(thread_id)
        messages = [{"role": "system", "content": SYSTEM_PROMPT}] + history + [{"role": "user", "content": question}]
        used = []
        for _ in range(self.cfg.max_tool_rounds):
            resp = self.client.chat.completions.create(model=self.cfg.model, messages=messages, tools=self.specs, temperature=0)
            msg = resp.choices[0].message
            if not msg.tool_calls:
                answer = msg.content or ""
                break
            messages.append({"role": "assistant", "content": msg.content or "",
                             "tool_calls": [tc.model_dump() for tc in msg.tool_calls]})
            for tc in msg.tool_calls:
                args = json.loads(tc.function.arguments or "{}")
                used.append(tc.function.name)
                try:
                    result = getattr(self.tools, tc.function.name)(**args)
                except Exception as e:  # tool errors go back to the model, not up the stack
                    result = {"error": str(e)[:300]}
                messages.append({"role": "tool", "tool_call_id": tc.id, "content": json.dumps(result, default=str)[:6000]})
        else:
            answer = "I could not finish within the tool-call limit."
        self.threads.append(thread_id, len(history), [{"role": "user", "content": question}, {"role": "assistant", "content": answer}])
        return {"answer": answer, "thread_id": thread_id, "tools_used": used,
                "tool_families": sorted({TOOL_FAMILY[t] for t in used if t in TOOL_FAMILY})}


def setup_tracing(experiment_suffix="caregenie-agent"):
    user = WorkspaceClient().current_user.me().user_name
    mlflow.set_tracking_uri("databricks")
    mlflow.set_experiment(f"/Users/{user}/{experiment_suffix}")
    mlflow.openai.autolog()
