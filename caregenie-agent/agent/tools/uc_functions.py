"""Unity Catalog functions as agent tools, with no tool code: the toolkit reads each function's signature and COMMENT.

Execution uses Databricks Connect (serverless), so the identity running the agent needs EXECUTE on the functions and
SELECT on the gold tables they read. Tool names are the three-part function names joined with double underscores.
"""
from databricks_langchain import UCFunctionToolkit

_toolkit = UCFunctionToolkit(function_names=[
    "caregenie.caregenie.overdue_hba1c_patients",
    "caregenie.caregenie.patient_summary",
])
overdue_hba1c_patients, patient_summary = _toolkit.tools  # module-level so agent/tools/__init__.py collects them
