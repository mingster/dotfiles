#!/usr/bin/env bash
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
    sys.exit(0 if ok else 1)
PY
