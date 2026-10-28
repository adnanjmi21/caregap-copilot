import os, sys
os.environ.setdefault("MLFLOW_DISABLE_AGENT_HINT", "1")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from agent.caregenie_agent import CareGenieAgent, setup_tracing
setup_tracing()
a = CareGenieAgent()
tid = None
for q in sys.argv[1:]:
    r = a.ask(q, tid); tid = r["thread_id"]
    print(f"\nQ: {q}\n  tools: {r['tools_used']}\n  A: {r['answer'][:700]}")
