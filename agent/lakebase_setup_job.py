"""One-off serverless job: create the Lakebase user_preferences table and upsert a demo preference.
Runs inside the workspace because the Postgres port is not reachable from the dev sandbox."""
import sys
# serverless Python tasks run via exec(), so __file__ is undefined: use the uploaded workspace folder
sys.path.insert(0, "/Workspace/Users/adnan21.javed@gmail.com/caregenie/agent")
from lakebase_prefs import LakebasePreferences

p = LakebasePreferences()
p.init_schema()
me = p.w.current_user.me().user_name
p.set(me, "phone", "SOUTH SHORE HOSPITAL")  # demo preference for this synthetic project
print("saved:", me, p.get(me))
