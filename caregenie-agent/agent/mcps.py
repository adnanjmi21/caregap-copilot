"""MCP servers offered to the agent. None: the UC functions are bound in agent.toml (`agentbricks tools add uc-function`)."""

from databricks_langchain import DatabricksMCPServer


def build_mcp_servers() -> list[DatabricksMCPServer]:
    return []
