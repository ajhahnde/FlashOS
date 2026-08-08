from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))


def load_script(module_name: str, filename: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(module_name, TOOLS_DIR / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module
