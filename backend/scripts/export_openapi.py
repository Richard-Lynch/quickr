"""Write the FastAPI-generated OpenAPI spec to disk (deterministically)."""

import json
import sys
from pathlib import Path

from app.main import app

out = Path(sys.argv[1] if len(sys.argv) > 1 else "../openapi.json")
out.write_text(json.dumps(app.openapi(), indent=2, sort_keys=False) + "\n")
print(f"wrote {out}")
