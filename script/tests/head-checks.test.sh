#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# Real fixture commits and worktrees; only the forge is faked.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)/head-checks.sh" <<'PY'
import hashlib, json, os, pathlib, select, subprocess, sys, tempfile, time
runner=sys.argv[1]
passed=failed=0
with tempfile.TemporaryDirectory() as temp:
    root=pathlib.Path(temp); repo=root/'fixture'; repo.mkdir(); binpath=root/'bin'; binpath.mkdir()
    gh=binpath/'gh'
    reader=binpath/'reader'
    reader.write_text('#!/usr/bin/env bash\ncase "$1" in hardware) echo "12 8 1000000000";; model) echo fixture;; *) echo "0 90";; esac\n'); reader.chmod(0o755)
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
    env=dict(os.environ,PATH=str(binpath)+os.pathsep+os.environ['PATH'],HOME=str(root/'home'),GH_BASE=base,COMMENTS=str(comments),ORCA_TEST_SECRET='SECRET_MUST_NOT_APPEAR',HEAVY_GATE_READER=str(reader),HEAVY_GATE_POLL_SECONDS='0.02',HEAD_CHECKS_WAIT_SECONDS='0')
    env.pop('HEAD_CHECKS_SLOTS',None)
    def run(name,commands,expected,pr=True,override=False):
        global passed,failed
        conf.write_text(commands+'\n'); (repo/'code.txt').write_text(name+'\n'); git('add','.'); git('commit','-qm',name); head=git('rev-parse','HEAD'); env['GH_HEAD']=head
        order.unlink(missing_ok=True); comments.unlink(missing_ok=True)
        (repo/'.env.local').write_text('secret=SECRET_MUST_NOT_APPEAR\n')
        result=subprocess.run(['bash',runner,'--repo',str(repo),*(['--pr','7'] if pr else ['--ref',head]),*(['--config',str(conf)] if override else [])],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        receipt=comments.read_text() if comments.exists() else ''
        good=(result.returncode==expected and ('Checks: '+('PASS' if expected==0 else 'FAIL')+' head='+head in receipt if pr else not comments.exists()) and 'SECRET_MUST_NOT_APPEAR' not in result.stdout+receipt and not (root/'home/orca/workspaces/fixture/_checks.lock').exists())
        if good: passed+=1; print('ok  ',name)
        else: failed+=1; print('FAIL',name,result.returncode,result.stdout,receipt)
        return result,head
    line=lambda text: "printf '%s\\n' '"+text+"' >> '"+str(order)+"'"
    run('ordered exact head checks',line('lint')+'\n'+line('typecheck')+'\n'+line('tests')+'\n'+'test ! -f .env.local\ntest "$(git rev-parse HEAD)" = "$HEAD_CHECK_SHA"\nprintf "%s" "${ORCA_TEST_SECRET:-}"',0)
    if order.read_text()=='lint\ntypecheck\ntests\n': passed+=1; print('ok   cheapest first order')
    else: failed+=1; print('FAIL order')
    # Checklist helpers follow the remote dotfiles checkout, including paths with spaces.
    helper='python3 "${DOTFILES_DIR:-$HOME/dotfiles}/script/check-path.py"'
    custom=root/'remote dotfiles'
    (custom/'script').mkdir(parents=True)
    (custom/'script/check-path.py').write_text('print("custom dotfiles helper")\n')
    env['DOTFILES_DIR']=str(custom)
    run('checklist receives DOTFILES_DIR',helper,0)
    env.pop('DOTFILES_DIR')
    default=root/'home/dotfiles/script'
    default.mkdir(parents=True)
    (default/'check-path.py').write_text('print("default dotfiles helper")\n')
    run('checklist defaults to home dotfiles',helper,0)
    # The fetched PR base can be ahead of stale origin/main and diverge from HEAD.
    fresh=git('commit-tree',git('rev-parse',env['GH_HEAD']+'^{tree}'),'-p',env['GH_HEAD'],'-m','fresh PR base')
    env['GH_BASE']=fresh
    expected=env['GH_HEAD']
    run('checklist receives actual PR merge base', 'test "$HEAD_CHECK_BASE" = "'+expected+'"',0)
    env['GH_BASE']=base
    # An asdf shim exits 126 when its HOME has no .tool-versions; a step that sets its own HOME must still get the real python3.
    shims=root/'home/.asdf/shims'; shims.mkdir(parents=True); realbin=root/'real-python'; realbin.mkdir()
    (realbin/'python3').symlink_to(sys.executable)
    (shims/'python3').write_text('#!/usr/bin/env bash\n[ -f "$HOME/.tool-versions" ] || { echo "asdf: no version set for python" >&2; exit 126; }\nexec "'+str(realbin/'python3')+'" "$@"\n'); (shims/'python3').chmod(0o755)
    (binpath/'asdf').write_text('#!/usr/bin/env bash\n[ "$1 $2" = "which python3" ] && echo "'+str(realbin/'python3')+'"\n'); (binpath/'asdf').chmod(0o755)
    (root/'home/.tool-versions').write_text('python 3.0.0\n')
    run('step python3 survives a test-owned HOME',"HOME=$(mktemp -d) python3 -c 'print(1)'",0)
    (binpath/'asdf').unlink(); (root/'home/.tool-versions').unlink()
    import shutil; shutil.rmtree(root/'home/.asdf')
    # A huge log yields a receipt at or under the cap that names the full log file.
    env['HEAD_CHECKS_LOG_DIR']=str(root/'logs'); (root/'logs').mkdir(exist_ok=True)
    big,big_head=run('large log receipt is bounded',"head -c 200000 /dev/zero | tr '\\0' x; echo",0)
    text=comments.read_text()
    full=root/'logs'/('head-checks-'+big_head[:12]+'.log')
    if len(text)<=20000 and ('Full log: '+str(full)) in text and full.exists() and len(full.read_text())>200000 and text.startswith('Checks: PASS head='+big_head):
        passed+=1; print('ok   receipt is capped and names the full log')
    else: failed+=1; print('FAIL bounded receipt',len(text),full.exists())
    run('stop at first red',line('lint')+'\nexit 9\n'+line('tests'),1)
    if order.read_text()=='lint\n': passed+=1; print('ok   later checks never start')
    else: failed+=1; print('FAIL later checks ran')
    # A killed check (exit 137) still blocks, but says the code was not judged.
    run('kill signal check',line('before')+'\nkill -9 $$\n'+line('after'),1)
    receipt=comments.read_text(); result_line=[l for l in receipt.splitlines() if l.startswith('Result: ')][-1]
    if receipt.startswith('Checks: FAIL head=') and result_line=='Result: exit 137; remaining checks stopped; interrupted by a kill signal, the code was not judged, rerun Checks' and order.read_text()=='before\n':
        passed+=1; print('ok   exit 137 keeps FAIL and says the run was interrupted')
    else: failed+=1; print('FAIL exit 137 receipt',result_line,receipt)
    run('ordinary failure',line('lint')+'\nexit 9',1)
    if 'Result: exit 9; remaining checks stopped\n' in comments.read_text() and 'kill signal' not in comments.read_text():
        passed+=1; print('ok   other exit codes keep their result line')
    else: failed+=1; print('FAIL exit 9 receipt',comments.read_text())
    run('tsc step uses measure without slots',
        "printf 'tsc --noEmit\\n'; test ! -d \"$HOME/.cache/heavy-gate/slot-1\"",0)
    run('build step claims weight 2 gate slots',
        "printf 'run build\\n'; test -d \"$HOME/.cache/heavy-gate/slot-1\" -a -d \"$HOME/.cache/heavy-gate/slot-2\"",0)
    run('ref checks do not post',line('ref'),0,False)
    train_heads=base+','+env['GH_HEAD']
    train=subprocess.run(['bash',runner,'--repo',str(repo),'--ref',env['GH_HEAD'],'--base',base,'--config',str(conf),'--train-heads',train_heads],env=env,text=True,capture_output=True)
    if train.returncode==0 and 'Checks: PASS head='+env['GH_HEAD']+' main='+base+' train-heads='+train_heads in train.stdout:
        passed+=1; print('ok   train receipt names train and every PR head')
    else: failed+=1; print('FAIL train receipt',train.stdout,train.stderr)
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
    # A PR that adds a path matched by the base's .claude/deploy-guard-paths fails before any check runs.
    (repo/'.claude').mkdir(); (repo/'.claude/deploy-guard-paths').write_text('# deploy refuses these\nweb/.env*\n')
    git('add','.'); git('commit','-qm','deploy guard config'); env['GH_BASE']=git('rev-parse','HEAD')
    run('guarded path is allowed when not added',line('guard clean'),0)
    (repo/'web').mkdir(exist_ok=True); (repo/'web/.env.example').write_text('KEY=\n')
    # T30: a deploy guard refusal checked nothing, so it posts no Checks comment.
    (repo/'code.txt').write_text('guard refusal\n'); conf.write_text(line('guard should not run')+'\n'); git('add','.'); git('commit','-qm','guard refusal'); env['GH_HEAD']=git('rev-parse','HEAD')
    order.unlink(missing_ok=True); comments.unlink(missing_ok=True)
    guarded=subprocess.run(['bash',runner,'--repo',str(repo),'--pr','7'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if guarded.returncode==1 and 'Deploy guard: PR adds web/.env.example' in guarded.stdout and not comments.exists() and not order.exists(): passed+=1; print('ok   deploy guard refusal names the path, posts no comment, no check ran')
    else: failed+=1; print('FAIL deploy guard refusal',guarded.returncode,guarded.stdout,comments.exists())
    env['GH_BASE']=base
    result,_=run('unchecked receipt lists all paths',"printf 'UNCHECKED: jellyfin/Thing.cs\\n'; printf 'UNCHECKED: roku/main.brs\\n'",0)
    if 'Unchecked paths: jellyfin/Thing.cs, roku/main.brs' in comments.read_text(): passed+=1; print('ok   unchecked receipt summary')
    else: failed+=1; print('FAIL missing unchecked receipt summary',comments.read_text())
    result,_=run('selection remains visible after verbose tests', "printf 'Scoped tests: 3\\nSelected: ./notification-service.test.ts\\nSelected: ./no-update-many-claims-contract.test.ts\\nSelected: ./route.test.ts\\n'; for i in {1..30}; do echo test-output; done",0)
    if all(name in comments.read_text().splitlines() for name in ['Scoped tests: 3','Selected: ./notification-service.test.ts','Selected: ./no-update-many-claims-contract.test.ts','Selected: ./route.test.ts']): passed+=1; print('ok   scoped selection survives output tail')
    else: failed+=1; print('FAIL scoped selection was truncated')
    # Run both real repository checklists against committed component fixtures.
    tools_home=root/'home/dotfiles/script'; tools_home.mkdir(parents=True,exist_ok=True)
    (tools_home/'run-scoped-tests.py').symlink_to(pathlib.Path(runner).with_name('run-scoped-tests.py'))
    tool_log=root/'tool-calls'
    for tool in ['bun','bunx']:
        path=binpath/tool
        path.write_text('#!/usr/bin/env python3\nimport pathlib,sys\nwith open('+repr(str(tool_log))+', "a") as f: f.write(str(pathlib.Path.cwd())+" "+" ".join(sys.argv[1:])+"\\n")\n')
        path.chmod(0o755)
    for component in ['web','web2/projb_web','marketing','bin','projb_op/bin','jellyfin','roku','.github/workflows']:
        (repo/component).mkdir(parents=True,exist_ok=True)
        (repo/component/'.keep').write_text('fixture')
    for path,contents in {'marketing/src.ts':'export const x = 1;', 'bin/task.ts':'export const x = 1;', 'bin/task.test.ts':'', 'projb_op/bin/task.py':'x = 1', 'jellyfin/Thing.cs':'class Thing {}', 'roku/main.brs':'', '.github/workflows/build.yml':'name: Build'}.items():
        (repo/path).write_text(contents)
    for project in ['proja','projb']:
        default=pathlib.Path(runner).resolve().parents[3]/project/'merge-gates/.agents/head-checks.conf'
        checklist=pathlib.Path(os.environ.get(project.upper().replace('.', '_')+'_CHECKLIST', str(default)))
        if not checklist.is_file():
            print('skip',project,'optional sibling checklist integration (set '+project.upper().replace('.', '_')+'_CHECKLIST)')
            continue
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
    # The check worktree persists: ignored caches survive a rerun, untracked files do not, and a held lock refuses a second run.
    wt=root/'home/orca/workspaces/fixture/_checks'
    (repo/'.git/info/exclude').write_text('node_modules\n'); (wt/'node_modules').mkdir(exist_ok=True); (wt/'node_modules/cache').write_text('kept'); (wt/'stray.txt').write_text('gone')
    conf.write_text(line('reuse')+'\n'); git('add','.agents/head-checks.conf'); git('commit','-qm','reuse config')
    reuse=subprocess.run(['bash',runner,'--repo',str(repo),'--ref',git('rev-parse','HEAD'),'--base',base,'--config',str(conf)],env=env,text=True,capture_output=True)
    if reuse.returncode==0 and (wt/'node_modules/cache').exists() and not (wt/'stray.txt').exists(): passed+=1; print('ok   check worktree reused, caches kept')
    else: failed+=1; print('FAIL worktree reuse',reuse.stdout,reuse.stderr)
    lock=pathlib.Path(str(wt)+'.lock'); lock.mkdir(); (lock/'pid').write_text(str(os.getppid()))
    second=subprocess.run(['bash',runner,'--repo',str(repo),'--ref',git('rev-parse','HEAD'),'--base',base,'--config',str(conf)],env=env,text=True,capture_output=True)
    if second.returncode==0 and pathlib.Path(str(wt)+'-2').exists() and lock.exists(): passed+=1; print('ok   locked worktree sends a second run to the next slot')
    else: failed+=1; print('FAIL second slot',second.stdout,second.stderr)
    locked=subprocess.run(['bash',runner,'--repo',str(repo),'--ref',git('rev-parse','HEAD'),'--base',base,'--config',str(conf)],env={**env,'HEAD_CHECKS_SLOTS':'1'},text=True,capture_output=True)
    if locked.returncode==1 and 'in use' in locked.stdout+locked.stderr and 'Checks:' not in locked.stdout and lock.exists(): passed+=1; print('ok   all slots busy refuses without a verdict')
    else: failed+=1; print('FAIL lock',locked.stdout,locked.stderr)
    # T18: with every check worktree held, wait HEAD_CHECKS_WAIT_SECONDS, then refuse with no verdict.
    comments.unlink(missing_ok=True); started=time.monotonic()
    waited=subprocess.run(['bash',runner,'--repo',str(repo),'--pr','7'],env={**env,'HEAD_CHECKS_SLOTS':'1','HEAD_CHECKS_WAIT_SECONDS':'2','GH_HEAD':git('rev-parse','HEAD')},text=True,capture_output=True,timeout=30)
    elapsed=time.monotonic()-started
    if waited.returncode!=0 and elapsed>=2 and 'Checks:' not in waited.stdout and not comments.exists() and lock.exists(): passed+=1; print('ok   busy worktrees wait, then refuse with no comment')
    else: failed+=1; print('FAIL busy wait',waited.returncode,elapsed,waited.stdout,waited.stderr)
    # A run killed while it waits checked nothing, so it posts no verdict.
    comments.unlink(missing_ok=True)
    killed=subprocess.Popen(['bash',runner,'--repo',str(repo),'--pr','7'],env={**env,'HEAD_CHECKS_SLOTS':'1','HEAD_CHECKS_WAIT_SECONDS':'20','GH_HEAD':git('rev-parse','HEAD')},text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    # Kill only once the run sleeps in the wait loop; a fixed delay raced setup on a loaded host.
    for _ in range(150):
        if subprocess.run(['pgrep','-P',str(killed.pid),'sleep'],capture_output=True).returncode==0: break
        time.sleep(0.1)
    killed.terminate(); out=killed.communicate(timeout=30)[0]
    if killed.returncode!=0 and 'Checks:' not in out and not comments.exists() and lock.exists(): passed+=1; print('ok   a run killed while waiting posts no comment')
    else: failed+=1; print('FAIL killed wait',killed.returncode,out)
    # A worktree freed during the wait is taken instead of refusing.
    releaser=subprocess.Popen(['bash','-c','sleep 1; rm -rf "$0"',str(lock)])
    freed=subprocess.run(['bash',runner,'--repo',str(repo),'--ref',git('rev-parse','HEAD'),'--base',base,'--config',str(conf)],env={**env,'HEAD_CHECKS_SLOTS':'1','HEAD_CHECKS_WAIT_SECONDS':'20'},text=True,capture_output=True,timeout=30)
    releaser.wait()
    if freed.returncode==0: passed+=1; print('ok   worktree freed during the wait is used')
    else: failed+=1; print('FAIL freed wait',freed.stdout,freed.stderr)
    lock.mkdir(); (lock/'pid').write_text(str(os.getppid()))
    import shutil; shutil.rmtree(lock)
    # Persisted limits govern both worktree selection and the shared machine budget.
    settings=root/'home/.config/heavy-gate/slots.conf'; settings.parent.mkdir(parents=True)
    fingerprint=hashlib.sha256(json.dumps({'hw.model':'fixture','hw.ncpu':12,'hw.memsize':1000000000},sort_keys=True).encode()).hexdigest()
    def limits(slots):
        settings.write_text(f'slots={slots}\nload_max=12\n# fingerprint={fingerprint}\n')
    def invoke(extra=None):
        return subprocess.run(['bash',runner,'--repo',str(repo),'--ref',git('rev-parse','HEAD'),'--base',base,'--config',str(conf)],env={**env,**(extra or {})},text=True,capture_output=True,timeout=30)
    limits(1); lock.mkdir(); (lock/'pid').write_text(str(os.getpid()))
    limited=invoke()
    if limited.returncode==1 and 'in use' in limited.stdout+limited.stderr:
        passed+=1; print('ok   persisted slot count limits check worktrees')
    else: failed+=1; print('FAIL persisted count',limited.stdout,limited.stderr)
    overridden=invoke({'HEAD_CHECKS_SLOTS':'2'})
    if overridden.returncode==0:
        passed+=1; print('ok   explicit HEAD_CHECKS_SLOTS overrides persisted count')
    else: failed+=1; print('FAIL persisted override',overridden.stdout,overridden.stderr)
    limits(3)
    lock2=pathlib.Path(str(wt)+'-2.lock'); lock2.mkdir(); (lock2/'pid').write_text(str(os.getpid()))
    third=invoke()
    if third.returncode==0 and pathlib.Path(str(wt)+'-3').is_dir():
        passed+=1; print('ok   calibrated third slot can select third worktree')
    else: failed+=1; print('FAIL calibrated third slot',third.stdout,third.stderr)
    shutil.rmtree(lock); shutil.rmtree(lock2)
    order.unlink(missing_ok=True)
    ungated=invoke()
    if ungated.returncode==0 and order.exists():
        passed+=1; print('ok   head-checks runs without a whole-run gate slot')
    else: failed+=1; print('FAIL ungated head-checks',ungated.stdout,ungated.stderr)
    settings.write_text(settings.read_text().replace('# fingerprint=','# old='))
    gate=str(pathlib.Path(runner).with_name('heavy-gate.sh'))
    mismatch=subprocess.run(['bash',gate,'--measure','--','true'],env=env,text=True,capture_output=True)
    if mismatch.returncode==0 and mismatch.stderr.count('recalibrate')==1:
        passed+=1; print('ok   measure mode warns once on hardware mismatch and falls back')
    else: failed+=1; print('FAIL fingerprint fallback',mismatch.stdout,mismatch.stderr)
    # dotfiles runs without heavy-gate.py even when every heavy-gate slot is held.
    limits(3)
    dotrepo=root/'dotfiles'; dotrepo.mkdir()
    subprocess.run(['git','-C',str(dotrepo),'init','-q'],check=True)
    subprocess.run(['git','-C',str(dotrepo),'config','user.name','Fixture'],check=True)
    subprocess.run(['git','-C',str(dotrepo),'config','user.email','fixture@example.invalid'],check=True)
    (dotrepo/'.agents').mkdir()
    (dotrepo/'.agents/head-checks.conf').write_text("printf 'playwright\\n' >/dev/null; ls -d \"$HOME\"/.cache/heavy-gate/slot-* 2>/dev/null | wc -l | tr -d ' ' > '"+str(order)+"'\n")
    (dotrepo/'README.md').write_text('base\n')
    subprocess.run(['git','-C',str(dotrepo),'add','.'],check=True)
    subprocess.run(['git','-C',str(dotrepo),'commit','-qm','base'],check=True)
    dotbase=subprocess.check_output(['git','-C',str(dotrepo),'rev-parse','HEAD'],text=True).strip()
    subprocess.run(['git','-C',str(dotrepo),'update-ref','refs/remotes/origin/main',dotbase],check=True)
    (dotrepo/'README.md').write_text('change\n')
    subprocess.run(['git','-C',str(dotrepo),'commit','-qam','change'],check=True)
    dothead=subprocess.check_output(['git','-C',str(dotrepo),'rev-parse','HEAD'],text=True).strip()
    heavy=subprocess.Popen(['bash',str(pathlib.Path(runner).with_name('heavy-gate.sh')),'--weight','3','--','sleep','30'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        deadline=time.time()+10
        while len(list((root/'home/.cache/heavy-gate').glob('slot-*')))!=3 and time.time()<deadline:
            time.sleep(0.02)
        order.unlink(missing_ok=True); comments.unlink(missing_ok=True)
        dotrun=subprocess.run(['bash',runner,'--repo',str(dotrepo),'--pr','7'],env={**env,'GH_BASE':dotbase,'GH_HEAD':dothead},text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
        if dotrun.returncode==0 and comments.read_text().startswith('Checks: PASS head='+dothead) and order.read_text().strip()=='3':
            passed+=1; print('ok   dotfiles skips heavy-gate even while all heavy-gate slots are full')
        else: failed+=1; print('FAIL dotfiles heavy-gate bypass',dotrun.returncode,dotrun.stdout,order.read_text() if order.exists() else '')
    finally:
        if heavy.poll() is None: heavy.terminate()
        heavy.communicate(timeout=10)
    # A _checks gitfile that points at a deleted repo is replaced and the checks run.
    # A gitfile that still points at a live repo is left in place and posts no receipt.
    shutil.rmtree(wt, ignore_errors=True)
    subprocess.run(['git','-C',str(repo),'worktree','prune'],check=True)
    conf.write_text(line('orphan recovered')+'\n')
    git('add','.agents/head-checks.conf'); git('commit','-qm','orphan checklist')
    orphan_head=git('rev-parse','HEAD'); env['GH_HEAD']=orphan_head
    scratch=root/'scratch-orphan'; scratch.mkdir()
    for args in (['init','-q'],['config','user.email','fixture@example.invalid'],['config','user.name','Fixture']):
        subprocess.run(['git','-C',str(scratch),*args],check=True)
    (scratch/'s.txt').write_text('scratch\n')
    subprocess.run(['git','-C',str(scratch),'add','.'],check=True)
    subprocess.run(['git','-C',str(scratch),'commit','-qm','scratch'],check=True)
    subprocess.run(['git','-C',str(scratch),'worktree','add','--detach',str(wt),'HEAD'],check=True)
    (wt/'orphan-marker').write_text('old\n')
    dead_gitdir=pathlib.Path((wt/'.git').read_text().split(' ',1)[1].strip())
    shutil.rmtree(scratch)
    if dead_gitdir.exists():
        failed+=1; print('FAIL orphan setup',dead_gitdir)
    else:
        order.unlink(missing_ok=True); comments.unlink(missing_ok=True)
        recovered=subprocess.run(['bash',runner,'--repo',str(repo),'--pr','7'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
        same=subprocess.run(['git','-C',str(wt),'rev-parse','--path-format=absolute','--git-common-dir'],text=True,capture_output=True)
        repo_common=subprocess.run(['git','-C',str(repo),'rev-parse','--path-format=absolute','--git-common-dir'],text=True,capture_output=True)
        if (recovered.returncode==0 and comments.exists() and comments.read_text().startswith('Checks: PASS head='+orphan_head)
                and order.read_text()=='orphan recovered\n' and not (wt/'orphan-marker').exists()
                and same.returncode==0 and same.stdout.strip()==repo_common.stdout.strip()):
            passed+=1; print('ok   orphan check worktree is replaced and checks run')
        else:
            failed+=1; print('FAIL orphan check worktree',recovered.returncode,recovered.stdout,comments.read_text() if comments.exists() else '',same.stdout,same.stderr)
    foreign=root/'scratch-live'; foreign.mkdir()
    for args in (['init','-q'],['config','user.email','fixture@example.invalid'],['config','user.name','Fixture']):
        subprocess.run(['git','-C',str(foreign),*args],check=True)
    (foreign/'f.txt').write_text('live\n')
    subprocess.run(['git','-C',str(foreign),'add','.'],check=True)
    subprocess.run(['git','-C',str(foreign),'commit','-qm','live'],check=True)
    foreign_wt=root/'foreign-wt'
    subprocess.run(['git','-C',str(foreign),'worktree','add','--detach',str(foreign_wt),'HEAD'],check=True)
    (foreign_wt/'live-marker').write_text('stay\n')
    wt.mkdir(parents=True, exist_ok=True)
    (wt/'kept-marker').write_text('stay\n')
    (wt/'.git').write_text((foreign_wt/'.git').read_text())
    order.unlink(missing_ok=True); comments.unlink(missing_ok=True)
    refused=subprocess.run(['bash',runner,'--repo',str(repo),'--pr','7'],env={**env,'HEAD_CHECKS_SLOTS':'1'},text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
    if (refused.returncode==1 and 'cannot replace unusable check worktree' in refused.stdout and 'Checks:' not in refused.stdout
            and not comments.exists() and not order.exists() and (wt/'kept-marker').is_file() and (foreign_wt/'live-marker').is_file()):
        passed+=1; print('ok   unusable check worktree refuses with no receipt')
    else:
        failed+=1; print('FAIL unusable check worktree receipt',refused.returncode,refused.stdout,comments.exists(),order.exists(),(wt/'kept-marker').exists(),(foreign_wt/'live-marker').exists())
print(f'passed {passed}, failed {failed}')
sys.exit(bool(failed))
PY
