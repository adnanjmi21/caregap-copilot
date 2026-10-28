"""WRITE tool: queue one outreach request (synthetic patients only).

UC SQL functions are read-only, so the write goes through the `queue_outreach` stored procedure, which validates
the patient and channel and records user + timestamp in outreach_queue. `agent/agent.py` lists this tool in
REQUIRE_APPROVAL, so a human must approve every call before it runs.
"""
import os

from databricks_agentkit import workspace_client
from langchain_core.tools import tool

WAREHOUSE_ID = os.environ.get("DATABRICKS_WAREHOUSE_ID", "acbfda553f05a6ec")


@tool
def queue_outreach(patient_id: str, channel: str, reason: str) -> str:
    """WRITE ACTION: queue one outreach request for a patient. channel is one of phone, sms, email, mail.
    Use only when the user explicitly asks to queue outreach."""
    reason = reason.replace("'", "''")[:200]
    r = workspace_client().statement_execution.execute_statement(
        warehouse_id=WAREHOUSE_ID, wait_timeout="50s",
        statement=f"CALL caregenie.caregenie.queue_outreach('{patient_id}', '{channel}', '{reason}')")
    if r.status.state.value != "SUCCEEDED":
        return f"Not queued: {r.status.error.message if r.status.error else r.status.state}"
    return "Queued."
