"""Log the CareGenie agent to MLflow, register it in Unity Catalog and (with --deploy) deploy it to Model Serving.

  .venv/bin/python scripts/deploy_agent.py          # log + register only
  .venv/bin/python scripts/deploy_agent.py --deploy # also create the serving endpoint (scale to zero)
Declared resources let Databricks issue the endpoint short-lived credentials for exactly these assets (automatic auth passthrough).
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
os.environ.setdefault("MLFLOW_DISABLE_AGENT_HINT", "1")
import mlflow
from mlflow.models.resources import (DatabricksFunction, DatabricksServingEndpoint, DatabricksSQLWarehouse,
                                     DatabricksTable, DatabricksVectorSearchIndex)
from agent.caregenie_agent import WAREHOUSE_ID, LLM_ENDPOINT, EMBED_ENDPOINT, setup_tracing

MODEL = "caregenie.caregenie.caregenie_agent"
resources = [
    DatabricksServingEndpoint(endpoint_name=LLM_ENDPOINT),
    DatabricksServingEndpoint(endpoint_name=EMBED_ENDPOINT),
    DatabricksSQLWarehouse(warehouse_id=WAREHOUSE_ID),
    DatabricksVectorSearchIndex(index_name="caregenie.caregenie.guidelines_index"),
    DatabricksVectorSearchIndex(index_name="caregenie.caregenie.encounter_chunks_v2_index"),
    DatabricksFunction(function_name="caregenie.caregenie.overdue_hba1c_patients"),
    DatabricksFunction(function_name="caregenie.caregenie.patient_summary"),
    DatabricksTable(table_name="caregenie.caregenie.gold_hba1c_gap"),
    DatabricksTable(table_name="caregenie.caregenie.gold_patient_panel"),
]

if __name__ == "__main__":
    setup_tracing()
    mlflow.set_registry_uri("databricks-uc")
    example = {"input": [{"role": "user", "content": "How many diabetic patients have an HbA1c older than 9 months?"}]}
    with mlflow.start_run(run_name="caregenie-agent-log"):
        info = mlflow.pyfunc.log_model(
            name="agent", python_model="agent/serving_entry.py", code_paths=["agent"], resources=resources,
            input_example=example, registered_model_name=MODEL,
            pip_requirements=[f"mlflow=={mlflow.__version__}", "databricks-sdk>=0.157", "openai", "databricks-agents"])
    print("logged:", info.model_uri, "version:", info.registered_model_version)
    if "--deploy" in sys.argv:
        from databricks import agents
        d = agents.deploy(MODEL, info.registered_model_version, scale_to_zero=True)
        print("endpoint:", d.endpoint_name, "| review app:", getattr(d, "review_app_url", None))
