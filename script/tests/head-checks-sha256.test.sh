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
    conf.write_text('true\ntrue\n'); git('add', '.'); git('commit', '-qm', 'two checks'); head = git('rev-parse', 'HEAD')
    result = subprocess.run(['/bin/bash', runner, '--repo', str(repo), '--ref', head], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    import re
    durations = re.findall(r'^Duration: (\d+)s$', result.stdout, re.M)
    total = re.search(r'^Total: (\d+)s\n?\Z', result.stdout, re.M)
    ok = result.returncode == 0 and len(durations) == 2 and total is not None and len(result.stdout) <= 65536
    print('ok   per-check Duration and closing Total in the receipt' if ok else 'FAIL duration/total rc=%s\n%s' % (result.returncode, result.stdout))
    if not ok: sys.exit(1)
    # Generate receipt inputs instead of running thousands of shell checks.
    formatter = pathlib.Path(runner).read_text().split("| python3 -c '\n", 1)[1].split("\n' \"$receipt_cap\"", 1)[0]
    failures = 0
    # The receipt must not depend on how long TMPDIR is: run each case with a short
    # and a 300-character log path.
    long_dir = root.joinpath(*(['d' * 60] * 5)); long_dir.mkdir(parents=True)
    cases = [(n, cap, path) for n, cap in [(50, 500), (700, 20000), (3000, 65536), (210, 65536), (1500, 65536)]
             for path in (root/'full.log', long_dir/'full.log')]
    for n, cap, path in cases:
        log = 'Checks: FAIL head=' + head + '\n\nChecklist: fixture\n'
        log += ''.join('Command: true # ' + 'x' * 500 + '\nResult: exit 0\nDuration: 1s\n' for _ in range(n - 1))
        log += 'Command: false\nResult: exit 1; remaining checks stopped\nDuration: 9s\nTotal: 12s\n'
        result = subprocess.run([sys.executable, '-c', formatter, str(cap), str(path)], input=log, text=True, capture_output=True)
        receipt = result.stdout
        durations = re.findall(r'^Duration: (\d+)s$', receipt, re.M)
        omitted = re.search(r'^Durations omitted: (\d+) \(see full log\)$', receipt, re.M)
        skipped = int(omitted.group(1)) if omitted else 0
        ok = (result.returncode == 0 and len(receipt) <= cap
              and receipt.splitlines()[0] == 'Checks: FAIL head=' + head
              and receipt.endswith('Total: 12s\n')
              and 'Result: exit 1; remaining checks stopped\n' in receipt
              and ('Result: exit 0' not in receipt
                   or receipt.index('Result: exit 1') < receipt.index('Result: exit 0')))
        ok = (ok and len(durations) + skipped == n and '9' in durations
              and (n not in (210, 1500) or len(durations) == n)
              # The failing check's Duration follows its Result directly.
              and 'Result: exit 1; remaining checks stopped\nDuration: 9s\n' in receipt)
        print('%s %d checks cap=%d path=%d length=%d' % ('ok  ' if ok else 'FAIL', n, cap, len(str(path)), len(receipt)), flush=True)
        failures += not ok
    # Tiny budgets and long boundary lines exercise the final truncation backstop.
    for cap in (0, 1, 10, 70, 100, 300, 500):
        header = 'Checks: FAIL head=' + head + ' train-heads=' + head * 8
        log = header + '\n' + 'x' * 2000 + '\nTotal: 12s\n'
        result = subprocess.run([sys.executable, '-c', formatter, str(cap), str(root/('x' * 200))], input=log, text=True, capture_output=True)
        ok = result.returncode == 0 and len(result.stdout) <= cap
        if cap >= len(header) + len('\nTotal: 12s\n'):
            ok = ok and result.stdout.startswith(header + '\n') and result.stdout.endswith('Total: 12s\n')
        print('%s backstop cap=%d length=%d' % ('ok  ' if ok else 'FAIL', cap, len(result.stdout)))
        failures += not ok
    sys.exit(bool(failures))
PY
