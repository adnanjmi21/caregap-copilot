"""Long-term memory: per-user preferences in Lakebase (managed Postgres), read with an ordinary structured query.

Lakebase Autoscaling note: connections use a short-lived OAuth token as the Postgres password (user = your Databricks
login), and the compute suspends when idle, so the first query after a pause takes a few seconds to wake it.
"""
import psycopg
from databricks.sdk import WorkspaceClient

ENDPOINT = "projects/caregenie-memory/branches/production/endpoints/primary"
DBNAME = "databricks_postgres"


class LakebasePreferences:
    def __init__(self, w=None):
        self.w = w or WorkspaceClient()
        ep = self.w.postgres.get_endpoint(name=ENDPOINT)
        self.host = ep.status.hosts.host

    def _conn(self):
        token = self.w.postgres.generate_database_credential(endpoint=ENDPOINT).token
        return psycopg.connect(host=self.host, dbname=DBNAME, user=self.w.current_user.me().user_name,
                               password=token, sslmode="require", connect_timeout=30)

    def init_schema(self):
        with self._conn() as c:
            c.execute("""CREATE TABLE IF NOT EXISTS user_preferences (
                user_name TEXT PRIMARY KEY, preferred_channel TEXT, default_clinic TEXT,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now())""")

    def set(self, user_name, preferred_channel=None, default_clinic=None):
        with self._conn() as c:
            c.execute("""INSERT INTO user_preferences (user_name, preferred_channel, default_clinic) VALUES (%s, %s, %s)
                ON CONFLICT (user_name) DO UPDATE SET preferred_channel = EXCLUDED.preferred_channel,
                default_clinic = EXCLUDED.default_clinic, updated_at = now()""",
                      (user_name, preferred_channel, default_clinic))

    def get(self, user_name):
        with self._conn() as c:
            row = c.execute("SELECT preferred_channel, default_clinic FROM user_preferences WHERE user_name = %s",
                            (user_name,)).fetchone()
        return {"preferred_channel": row[0], "default_clinic": row[1]} if row else {"error": "No saved preferences for this user"}
