"""Disposable product workflow adapter for the hosted registry drill."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('plan', '.github/actions/native-plan/plan.py')
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)
repo = os.environ['GITHUB_REPOSITORY']
source = json.loads(subprocess.check_output(['gh','api',f'repos/{repo}/releases/tags/{os.environ["SOURCE_TAG"]}']))
pages = json.loads(subprocess.check_output(['gh','api','--paginate','--slurp',f'repos/{repo}/releases?per_page=100']))
plan = planner.build_plan('server', source, [r for page in pages for r in page], {}, os.environ['REPACK']=='true')
Path('/tmp/fixture-plan.json').write_text(json.dumps(plan))
if not plan:
    print('Already packaged: empty plan')
    raise SystemExit(0)
item=plan[0]
print(json.dumps(item))
Path('packages').mkdir()
for arch,deb_arch in [('x86_64','amd64'),('aarch64','arm64')]:
    selected=item['sources'][arch]
    tarball=Path('/tmp')/f'fixture-{arch}.tar.zst'
    subprocess.run(['curl','-fsSL',selected['url'],'-o',str(tarball)],check=True)
    assert hashlib.sha256(tarball.read_bytes()).hexdigest()==selected['sha256']
    assert tarball.stat().st_size==selected['size']
    content=Path('/tmp')/f'fixture-content-{arch}'
    subprocess.run(['tar','--zstd','-xf',str(tarball),'-C','/tmp'],check=True)
    content.write_text(Path('/tmp/gel-server-7.1/content').read_text()+f'revision {item["revision"]}\n')
    config=Path('/tmp')/f'nfpm-{arch}.json'
    config.write_text(json.dumps({'name':'gel-server-7','arch':deb_arch,'platform':'linux','version_schema':'none','version':item['native_version'],'release':str(item['revision']),'epoch':'1','maintainer':'Disposable Fixture <fixture@example.invalid>','description':'Disposable acceptance fixture','contents':[{'src':str(content),'dst':'/usr/share/gel-server-7/fixture'}]}))
    for fmt in ['deb','rpm']:
        name=f'gel-server-7-{item["native_version"]}-{item["revision"]}-{deb_arch if fmt=="deb" else arch}.{fmt}'
        subprocess.run(['nfpm','package','--config',str(config),'--packager',fmt,'--target',f'packages/{name}'],check=True)
Path('/tmp/fixture-tag').write_text(item['tag'])
