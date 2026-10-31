"""Disposable native Orca responses for real admission and launch tests."""
import json
import os
from datetime import datetime, timezone
from pathlib import Path

HEAD = 'a' * 40
REPO = 'o/n'
PATH = '/fixture/review'


class NativeFixture:
    def __init__(self, root, path=PATH, repo=REPO):
        self.root = Path(root)
        self.path, self.repo = path, repo
        self.config = {'host_caps': {'alpha': 2, 'beta': 2},
                       'host_load_ceilings': {'alpha': 12, 'beta': 8}}
        self.loads = {h: {'load_1m': 1, 'cores': 8,
                         'observed_at': datetime.now(timezone.utc).isoformat()}
                      for h in self.config['host_caps']}
        self.data = {'environments': [{'id': h+'-saved', 'name': h} for h in ('alpha', 'beta')]}
        for host in ('alpha', 'beta'):
            row = {'id': 'repo-id::'+path, 'repoId': 'repo-id',
                   'projectId': 'github:'+repo, 'hostId': 'local', 'path': path, 'head': HEAD,
                   'identity': {'key': 'wt2:local:'+host+'-instance', 'executionHostId': 'local',
                                'instanceId': host+'-instance'},
                   'git': {'path': path, 'head': HEAD, 'isBare': False}}
            run_id = 'run-'+host
            workers = {'workers': [], 'page': {'hasMore': False},
                       'scope': {'source': 'flag', 'run': run_id}}
            self.data[host] = {
                'repos': [{'id': 'repo-id', 'gitRemoteIdentity': {'canonicalKey': 'github.com/'+repo}}],
                'worktrees': {'worktrees': [row], 'truncated': False,
                              'hostScope': {'hostIds': ['local'], 'omittedHostIds': []}},
                'runs': {'runs': [{'id': run_id}], 'nextCursor': None},
                'workers_by_run': {run_id: workers},
                'workers': workers}
        self.write_executable('orca', '''import json,os,sys
from pathlib import Path
root=Path(os.environ['NATIVE_FIXTURE_ROOT']); data=json.loads((root/'native.json').read_text())
a=sys.argv[1:]
with (root/'calls').open('a') as f: f.write(json.dumps(a)+'\\n')
if a[:2]==['orchestration','worker-start']:
 (root/'launch.json').write_text(json.dumps(a)); print('{"ok":true}'); sys.exit(0)
if a[:2]==['environment','list']: result={'environments':data['environments']}
elif a[:2]==['orchestration','run-list']:
 host=a[a.index('--environment')+1].removesuffix('-saved') if '--environment' in a else 'local'
 if host not in data: print('{"ok":false}'); sys.exit(1)
 result=data[host]['runs']
 if '--cursor' in a:
  cursor=a[a.index('--cursor')+1]
  pages=data[host].get('run_pages', {})
  if cursor not in pages: print('{"ok":false}'); sys.exit(1)
  result=pages[cursor]
elif a[:2]==['orchestration','worker-list']:
 host=a[a.index('--environment')+1].removesuffix('-saved') if '--environment' in a else 'local'
 if host not in data or '--run' not in a: print('{"ok":false}'); sys.exit(1)
 run=a[a.index('--run')+1]
 by_run=data[host].get('workers_by_run', {})
 result=by_run.get(run, data[host]['workers'])
 if '--cursor' in a: result=data[host].get('next_page', result)
else:
 host=a[a.index('--environment')+1].removesuffix('-saved') if '--environment' in a else 'local'
 if host not in data: print('{"ok":false}'); sys.exit(1)
 key={('repo','list'):'repos',('worktree','list'):'worktrees'}[tuple(a[:2])]
 result=data[host][key]
 if key=='repos': result={'repos':result}
print(json.dumps({'ok':True,'result':result}))
''')

    def write_executable(self, name, body):
        p = self.root/name
        p.write_text('#!/usr/bin/env python3\n'+body)
        p.chmod(0o755)
        return p

    def occupy(self, host, count, status='running', run_id=None):
        run_id = run_id or 'run-'+host
        workers = [
            {'dispatchId': run_id+'-ctx-'+str(i), 'dispatchStatus': status,
             'projection': {'host': {'id': 'local'}},
             'resource': {'terminalHandle': run_id+'-term-'+str(i),
                          'releaseState': 'not_requested'}}
            for i in range(count)]
        payload = {'workers': workers, 'page': {'hasMore': False},
                   'scope': {'source': 'flag', 'run': run_id}}
        self.data[host]['workers_by_run'][run_id] = payload
        if run_id == 'run-'+host:
            self.data[host]['workers'] = payload

    def add_run(self, host, run_id):
        runs = self.data[host]['runs']['runs']
        if not any(row['id'] == run_id for row in runs):
            runs.append({'id': run_id})
        self.data[host]['workers_by_run'].setdefault(
            run_id, {'workers': [], 'page': {'hasMore': False},
                     'scope': {'source': 'flag', 'run': run_id}})

    def env(self):
        (self.root/'native.json').write_text(json.dumps(self.data))
        (self.root/'config.json').write_text(json.dumps(self.config))
        env = dict(os.environ, NATIVE_FIXTURE_ROOT=str(self.root),
                   ORCA_CLI_COMMAND=str(self.root/'orca'),
                   ON_WORKER_DONE_FLEET_CONFIG=str(self.root/'config.json'),
                   QA_ADMISSION_LOAD_OBS=json.dumps(self.loads))
        env.pop('ON_WORKER_DONE_ADMISSION_POLICY', None)
        env.pop('ON_WORKER_DONE_QA_ADMISSION', None)
        return env
