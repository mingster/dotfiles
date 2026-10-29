#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# Hosts without shasum (Linux) must still get a checklist digest through sha256sum.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/.." && pwd)/head-checks.sh" <<'PY'
import hashlib, os, pathlib, subprocess, sys, tempfile
runner = sys.argv[1]
with tempfile.TemporaryDirectory() as temp:
    root = pathlib.Path(temp); repo = root/'fixture'; repo.mkdir(); binpath = root/'bin'; binpath.mkdir()
    # Every tool on PATH except shasum, so only the fallback can supply a digest.
    for directory in os.environ['PATH'].split(os.pathsep):
        if not os.path.isdir(directory): continue
        for name in os.listdir(directory):
            if name == 'shasum' or os.path.lexists(binpath/name): continue
            os.symlink(os.path.join(directory, name), binpath/name)
    reader = root/'reader'
    reader.write_text('#!/usr/bin/env bash\ncase "$1" in hardware) echo "12 8 1000000000";; model) echo fixture;; *) echo "0 90";; esac\n'); reader.chmod(0o755)
    sums = root/'sums'
    (binpath/'sha256sum').unlink(missing_ok=True)
    stub = binpath/'sha256sum'
    stub.write_text('#!/usr/bin/env python3\nimport hashlib,sys\nopen(%r,"a").write("called\\n")\nfor p in sys.argv[1:]:\n    print(hashlib.sha256(open(p,"rb").read()).hexdigest()+"  "+p)\n' % str(sums)); stub.chmod(0o755)
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True, stderr=subprocess.DEVNULL).strip()
    git('init', '-q'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.invalid')
    (repo/'code.txt').write_text('base\n'); git('add', '.'); git('commit', '-qm', 'base'); git('update-ref', 'refs/remotes/origin/main', git('rev-parse', 'HEAD'))
    (repo/'.agents').mkdir(); conf = repo/'.agents/head-checks.conf'; conf.write_text('true\n')
    (repo/'code.txt').write_text('head\n'); git('add', '.'); git('commit', '-qm', 'head'); head = git('rev-parse', 'HEAD')
    env = dict(os.environ, PATH=str(binpath), HOME=str(root/'home'), HEAVY_GATE_READER=str(reader), HEAVY_GATE_POLL_SECONDS='0.02', HEAD_CHECKS_WAIT_SECONDS='0')
    env.pop('HEAD_CHECKS_SLOTS', None)
    assert subprocess.run(['sh', '-c', 'command -v shasum'], env=env, capture_output=True).returncode != 0, 'shasum still on PATH'
    result = subprocess.run(['/bin/bash', runner, '--repo', str(repo), '--ref', head], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    digest = hashlib.sha256(b'true\n').hexdigest()
    ok = result.returncode == 0 and 'Checklist: ' + digest in result.stdout and sums.exists()
    print('ok   sha256sum digest when shasum is absent' if ok else 'FAIL sha256sum fallback rc=%s\n%s' % (result.returncode, result.stdout))
    if not ok: sys.exit(1)
    # A two-check checklist records a Duration line per check and a closing Total line.
    conf.write_text('true\nsleep 1\n'); git('add', '.'); git('commit', '-qm', 'two checks'); head = git('rev-parse', 'HEAD')
    result = subprocess.run(['/bin/bash', runner, '--repo', str(repo), '--ref', head], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    import re
    durations = re.findall(r'^Duration: (\d+)s$', result.stdout, re.M)
    total = re.search(r'^Total: (\d+)s\n?\Z', result.stdout, re.M)
    ok = result.returncode == 0 and len(durations) == 2 and total is not None and len(result.stdout) <= 65536
    print('ok   per-check Duration and closing Total in the receipt' if ok else 'FAIL duration/total rc=%s\n%s' % (result.returncode, result.stdout))
    if not ok: sys.exit(1)
    # A capped receipt keeps every Duration line and ends with Total.
    n = 210
    conf.write_text(''.join('true # %s\n' % ('x' * 500) for _ in range(n))); git('add', '.'); git('commit', '-qm', 'many checks'); head = git('rev-parse', 'HEAD')
    capenv = dict(env, HEAD_CHECKS_RECEIPT_CAP='65536', HEAD_CHECKS_LOG_DIR=str(root))
    result = subprocess.run(['/bin/bash', runner, '--repo', str(repo), '--ref', head], env=capenv, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    receipt = result.stdout[result.stdout.index('Checks: '):]
    durations = re.findall(r'^Duration: (\d+)s$', receipt, re.M)
    ok = result.returncode == 0 and len(receipt) <= 65536 and 'Receipt cut to fit' in receipt and len(durations) == n and re.search(r'^Total: (\d+)s\n?\Z', receipt, re.M) is not None
    print('ok   capped receipt keeps all Duration lines and closing Total' if ok else 'FAIL capped receipt rc=%s len=%d durations=%d' % (result.returncode, len(receipt), len(durations)))
    if not ok: sys.exit(1)
    # Too many checks for every Duration line: slowest kept, the rest summarised, Total still last.
    n = 1500
    conf.write_text(''.join('true # %s\n' % ('x' * 500) for _ in range(n))); git('add', '.'); git('commit', '-qm', 'huge checks'); head = git('rev-parse', 'HEAD')
    result = subprocess.run(['/bin/bash', runner, '--repo', str(repo), '--ref', head], env=capenv, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    receipt = result.stdout[result.stdout.index('Checks: '):]
    durations = re.findall(r'^Duration: (\d+)s$', receipt, re.M)
    omitted = re.search(r'^Duration: (\d+) more checks omitted \(see full log\)$', receipt, re.M)
    ok = result.returncode == 0 and len(receipt) <= 65536 and re.search(r'^Total: (\d+)s\n\Z', receipt, re.M) is not None and omitted is not None and len(durations) + int(omitted.group(1)) == n
    print('ok   1500 checks stay within the cap with an omitted Duration line and Total last' if ok else 'FAIL huge receipt rc=%s len=%d durations=%d omitted=%s' % (result.returncode, len(receipt), len(durations), omitted and omitted.group(1)))
    sys.exit(0 if ok else 1)
PY
