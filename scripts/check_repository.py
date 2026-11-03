"""Static packaging checks; does not run RTL simulation or vendor tools."""
from pathlib import Path
import hashlib,json,re,xml.etree.ElementTree as ET
R=Path(__file__).resolve().parents[1];T=R/'project'
hs=json.loads((R/'docs/evidence/production_sha256.json').read_text(encoding='utf-8'))
actual={p.relative_to(T).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in (T/'user_source').rglob('*') if p.is_file()}
assert actual==hs,'Production files differ from the final engineering baseline'
projects=list(T.rglob('*.al'))
assert len(projects)==1,'Expected exactly one TD project'
for node in ET.parse(projects[0]).findall('.//Source_Files/*/File'):
    target=(projects[0].parent/node.attrib['Path']).resolve()
    assert target.is_file(),f'Missing project dependency: {target}'
for kind in ('syn','phy'):
    template=T/f'_build/templates/{kind}/camera_to_dsi_display.prj'
    run=T/f'td_project/camera_to_dsi_display_Runs/{kind}_1'
    for node in ET.parse(template).findall('.//Source_Files/Verilog/File'):
        target=(run/node.attrib['Path']).resolve()
        assert target.is_file(),f'Missing build dependency: {target}'
for p in R.rglob('*.py'):
    if '.git' not in p.parts:compile(p.read_text(encoding='utf-8-sig'),str(p),'exec')
for p in R.rglob('*.md'):
    text=p.read_text(encoding='utf-8-sig')
    for target in re.findall(r'!?\[[^\]]*\]\(([^)]+)\)',text):
        if '://' in target or target.startswith('#'):continue
        assert (p.parent/target.split('#')[0]).exists(),f'Broken link in {p.relative_to(R)}: {target}'
bit=R/'firmware/SC520_view_manual_v17.bit'
expected='e0c147ed5133b1bdc336799fa405b0aab4d65b9b33572a5eb34633a473f3b020'
assert hashlib.sha256(bit.read_bytes()).hexdigest()==expected,'Firmware SHA256 mismatch'
assert len(list((R/'firmware').glob('*.bit')))==1
jobs=json.loads((T/'_build/simulation_jobs.json').read_text())
assert len(jobs)==41 and len({j['name'] for j in jobs})==41
for job in jobs:
    for dep in job['files']:
        assert 'sim/reference' not in dep and (T/dep).is_file(),dep
assert not any(p.is_file() for p in T.glob('sim/reference/**/*'))
assert not list((T/'_build').glob('v*.json'))
summary=json.loads((R/'docs/evidence/implementation.json').read_text())
assert summary['recorded_rtl_tasks']==65 and summary['packaged_current_only_rtl_tasks']==41
print(f'PASS: {len(actual)} production files, one TD project, one original firmware, 41 current-design test definitions, source links and build templates.')
print('This static audit does not claim a fresh RTL run, new place-and-route, or board verification.')
