"""AI Search retriever tools, declared with the Agent Framework class (no tool code to write).

Managed-embedding index: the service embeds the query text. Self-managed-embedding index (precomputed vectors):
the same embedding model is supplied so the tool can embed the query itself.
"""
from databricks_langchain import DatabricksEmbeddings, VectorSearchRetrieverTool

search_guidelines = VectorSearchRetrieverTool(
    index_name="caregenie.caregenie.guidelines_index",
    tool_name="search_guidelines",
    tool_description="Semantic search over FICTIONAL care guideline text. Use for 'what do the guidelines say about ...'. Not for counts or patient data.",
    num_results=3,
)

search_encounters = VectorSearchRetrieverTool(
    index_name="caregenie.caregenie.encounter_chunks_v2_index",
    tool_name="search_encounters",
    tool_description="Semantic search over synthetic encounter narratives. Use for 'find visits or cases like ...'. Not for exact counts. Prefer clinical terms (myocardial infarction, not heart attack).",
    embedding=DatabricksEmbeddings(endpoint="databricks-gte-large-en"),
    text_column="chunk_text",
    columns=["encounter_date"],
    num_results=5,
)
