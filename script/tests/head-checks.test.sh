#!/usr/bin/env bash
# Real fixture commits and worktrees; only the forge is faked.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)/head-checks.sh" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
runner=sys.argv[1]
passed=failed=0
with tempfile.TemporaryDirectory() as temp:
    root=pathlib.Path(temp); repo=root/'fixture'; repo.mkdir(); binpath=root/'bin'; binpath.mkdir()
    gh=binpath/'gh'
    gh.write_text('''#!/usr/bin/env python3
import json,os,sys,pathlib
if sys.argv[2]=='view': print(json.dumps({'headRefOid':os.environ['GH_HEAD'],'baseRefOid':os.environ['GH_BASE']}))
elif sys.argv[2]=='comment': pathlib.Path(os.environ['COMMENTS']).write_text(pathlib.Path(sys.argv[sys.argv.index('--body-file')+1]).read_text())
else: sys.exit(1)
'''); gh.chmod(0o755)
    def git(*args):
        return subprocess.check_output(['git','-C',str(repo),*args],text=True,stderr=subprocess.DEVNULL).strip()
    git('init','-q'); git('config','user.name','Fixture'); git('config','user.email','fixture@example.invalid')
    (repo/'code.txt').write_text('base\n'); git('add','.'); git('commit','-qm','base'); base=git('rev-parse','HEAD'); git('update-ref','refs/remotes/origin/main',base)
    (repo/'.agents').mkdir(); conf=repo/'.agents/head-checks.conf'; order=root/'order'; comments=root/'comments'
    env=dict(os.environ,PATH=str(binpath)+os.pathsep+os.environ['PATH'],HOME=str(root/'home'),GH_BASE=base,COMMENTS=str(comments),ORCA_TEST_SECRET='SECRET_MUST_NOT_APPEAR')
    def run(name,commands,expected,pr=True,override=False):
        global passed,failed
        conf.write_text(commands+'\n'); (repo/'code.txt').write_text(name+'\n'); git('add','.'); git('commit','-qm',name); head=git('rev-parse','HEAD'); env['GH_HEAD']=head
        order.unlink(missing_ok=True); comments.unlink(missing_ok=True)
        (repo/'.env.local').write_text('secret=SECRET_MUST_NOT_APPEAR\n')
        result=subprocess.run(['bash',runner,'--repo',str(repo),*(['--pr','7'] if pr else ['--ref',head]),*(['--config',str(conf)] if override else [])],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        receipt=comments.read_text() if comments.exists() else ''
        good=(result.returncode==expected and ('Checks: '+('PASS' if expected==0 else 'FAIL')+' head='+head in receipt if pr else not comments.exists()) and 'SECRET_MUST_NOT_APPEAR' not in result.stdout+receipt and not (root/'home/orca/workspaces/fixture/_checks').exists())
        if good: passed+=1; print('ok  ',name)
        else: failed+=1; print('FAIL',name,result.returncode,result.stdout,receipt)
        return result,head
    line=lambda text: "printf '%s\\n' '"+text+"' >> '"+str(order)+"'"
    run('ordered exact head checks',line('lint')+'\n'+line('typecheck')+'\n'+line('tests')+'\n'+'test ! -f .env.local\ntest "$(git rev-parse HEAD)" = "$HEAD_CHECK_SHA"\nprintf "%s" "${ORCA_TEST_SECRET:-}"',0)
    if order.read_text()=='lint\ntypecheck\ntests\n': passed+=1; print('ok   cheapest first order')
    else: failed+=1; print('FAIL order')
    run('stop at first red',line('lint')+'\nexit 9\n'+line('tests'),1)
    if order.read_text()=='lint\n': passed+=1; print('ok   later checks never start')
    else: failed+=1; print('FAIL later checks ran')
    run('ref checks do not post',line('ref'),0,False)
    (repo/'path with space.txt').write_text('quoted path\n')
    run('local baseline checklist override',line('baseline override'),0,False,True)
    comments.unlink(missing_ok=True)
    rejected=subprocess.run(['bash',runner,'--repo',str(repo),'--pr','7','--config',str(conf)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    if rejected.returncode==1 and not comments.exists(): passed+=1; print('ok   PR cannot override committed checklist')
    else: failed+=1; print('FAIL PR checklist override accepted')
    run('quoted changed paths',"files=({files}); printf '%s\\n' \"${files[@]}\"; test ${#files[@]} -gt 0",0)
    result,_=run('redact database URLs',"printf '%s\\n' 'postgresql://user:password@host/database'",0)
    if 'password@host' not in result.stdout+comments.read_text(): passed+=1; print('ok   database URI is fully redacted')
    else: failed+=1; print('FAIL database URI leaked')
    env['GH_BASE']=git('commit-tree',git('rev-parse',base+'^{tree}'),'-m','unrelated history')
    run('unrelated base refuses checks',line('should not run'),1)
    env['GH_BASE']=base
    run('empty checklist fails closed','# only a comment',1)
    result,_=run('unchecked receipt lists all paths',"printf 'UNCHECKED: jellyfin/Thing.cs\\n'; printf 'UNCHECKED: roku/main.brs\\n'",0)
    if 'Unchecked paths: jellyfin/Thing.cs, roku/main.brs' in comments.read_text(): passed+=1; print('ok   unchecked receipt summary')
    else: failed+=1; print('FAIL missing unchecked receipt summary',comments.read_text())
    # Run both real repository checklists against committed component fixtures.
    tools_home=root/'home/dotfiles/script'; tools_home.mkdir(parents=True)
    (tools_home/'run-scoped-tests.py').symlink_to(pathlib.Path(runner).with_name('run-scoped-tests.py'))
    tool_log=root/'tool-calls'
    for tool in ['bun','bunx']:
        path=binpath/tool
        path.write_text('#!/usr/bin/env python3\nimport pathlib,sys\nwith open('+repr(str(tool_log))+', "a") as f: f.write(str(pathlib.Path.cwd())+" "+" ".join(sys.argv[1:])+"\\n")\n')
        path.chmod(0o755)
    for component in ['web','web2/pstv_web','marketing','bin','pstv_op/bin','jellyfin','roku','.github/workflows']:
        (repo/component).mkdir(parents=True,exist_ok=True)
    for path,contents in {'marketing/src.ts':'export const x = 1;', 'bin/task.ts':'export const x = 1;', 'bin/task.test.ts':'', 'pstv_op/bin/task.py':'x = 1', 'jellyfin/Thing.cs':'class Thing {}', 'roku/main.brs':'', '.github/workflows/build.yml':'name: Build'}.items():
        (repo/path).write_text(contents)
    for project in ['riben.life','pstv']:
        checklist=pathlib.Path('/Users/mtsai/orca/workspaces')/project/'merge-gates/.agents/head-checks.conf'
        result,_=run(project+' real component checklist',checklist.read_text(),0)
        summary=comments.read_text()
        if 'Unchecked paths:' in summary and 'jellyfin/Thing.cs' in summary and 'roku/main.brs' in summary and 'Unsupported check scope' not in summary:
            passed+=1; print('ok  ',project,'unchecked components remain mergeable')
        else: failed+=1; print('FAIL',project,'component coverage receipt',summary)
    git('update-ref','refs/remotes/origin/main',env['GH_HEAD'])
    historical=subprocess.run(['bash',runner,'--repo',str(repo),'--ref',env['GH_HEAD']],env=env,text=True,capture_output=True)
    if historical.returncode==1 and '--base' in historical.stdout+historical.stderr: passed+=1; print('ok   historical ref requires base')
    else: failed+=1; print('FAIL historical ref accepted',historical.stdout,historical.stderr)
    conf.write_text(line('explicit base')+'\n'); git('add','.agents/head-checks.conf'); git('commit','-qm','explicit base config')
    explicit=subprocess.run(['bash',runner,'--repo',str(repo),'--ref',env['GH_HEAD'],'--base',base,'--config',str(conf)],env=env,text=True,capture_output=True)
    if explicit.returncode==0: passed+=1; print('ok   historical ref with explicit base')
    else: failed+=1; print('FAIL explicit base',explicit.stdout,explicit.stderr)
print(f'passed {passed}, failed {failed}')
sys.exit(bool(failed))
PY
