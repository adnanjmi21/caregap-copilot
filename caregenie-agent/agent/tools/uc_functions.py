"""Unity Catalog functions as agent tools, with no tool code: the toolkit reads each function's signature and COMMENT.

Execution uses Databricks Connect (serverless), so the identity running the agent needs EXECUTE on the functions and
SELECT on the gold tables they read. Tool names are the three-part function names joined with double underscores.
"""
from databricks_agentkit import workspace_client
from databricks_langchain import UCFunctionToolkit
from unitycatalog.ai.core.databricks import DatabricksFunctionClient

# Explicit client = the app identity; Databricks Connect (serverless) is configured from its credentials.
_toolkit = UCFunctionToolkit(client=DatabricksFunctionClient(client=workspace_client()), function_names=[
    "caregenie.caregenie.overdue_hba1c_patients",
    "caregenie.caregenie.patient_summary",
])
overdue_hba1c_patients, patient_summary = _toolkit.tools  # module-level so agent/tools/__init__.py collects them
