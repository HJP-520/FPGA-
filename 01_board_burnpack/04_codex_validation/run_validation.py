from pathlib import Path
import subprocess,sys
h=Path(__file__).resolve().parent
for name in ["run_unit_tests.py","run_integration.py"]:
    code=subprocess.call([sys.executable,str(h/name)])
    if code:sys.exit(code)
print("ALL VALIDATION PASSED")
