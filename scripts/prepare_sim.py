"""Generate reproducible test vectors excluded from version control."""
from pathlib import Path
import subprocess,sys
root=Path(__file__).resolve().parents[1]/'project'
for name in ['local_fixture.py','edge_fixture.py','edge_detail_fixture.py']:
    subprocess.run([sys.executable,str(root/'tools'/name)],cwd=root,check=True)
print('Simulation fixtures ready. Run project/_build/verify.py next.')
