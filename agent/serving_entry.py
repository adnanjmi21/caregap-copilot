"""Model-serving entry point: wraps CareGenieAgent in the Mosaic AI Agent Framework ResponsesAgent interface.
Logged with mlflow.pyfunc.log_model(python_model="agent/serving_entry.py"); `set_model` at the bottom registers the instance."""
import uuid

import mlflow
from mlflow.pyfunc import ResponsesAgent
from mlflow.types.responses import ResponsesAgentRequest, ResponsesAgentResponse

from agent.caregenie_agent import AgentConfig, CareGenieAgent


def _text(content):
    if isinstance(content, str):
        return content
    return " ".join(p.get("text", "") if isinstance(p, dict) else getattr(p, "text", "") for p in content)


class CareGenieResponsesAgent(ResponsesAgent):
    def __init__(self):
        self._agent = None  # created lazily so importing the module never touches the workspace

    def _get_agent(self):
        if self._agent is None:
            self._agent = CareGenieAgent(AgentConfig())
        return self._agent

    def predict(self, request: ResponsesAgentRequest) -> ResponsesAgentResponse:
        user_msgs = [m for m in request.input if getattr(m, "role", None) == "user"]
        question = _text(user_msgs[-1].content)
        thread_id = (request.custom_inputs or {}).get("thread_id")
        r = self._get_agent().ask(question, thread_id)
        return ResponsesAgentResponse(
            output=[self.create_text_output_item(text=r["answer"], id=str(uuid.uuid4()))],
            custom_outputs={"thread_id": r["thread_id"], "tools_used": r["tools_used"], "tool_families": r["tool_families"]})


mlflow.models.set_model(CareGenieResponsesAgent())
