# Encrypt web2 database connections (owner runbook, run on ht3)

Goal: every DATABASE_URL_* gets `encrypt=true;trustServerCertificate=true` (replaces `encrypt=DANGER_PLAINTEXT`). Staging first, production only after staging is clean. No secret is printed by any command below. Run in Git Bash on ht3 as user pstv.

Paths:
- Staging: `/pstv/test.5ik.tv/pstv_web/.env`, node log `/pstv/test.5ik.tv/node-test.log` (+ `.err`), port 3100, IIS site `test.5ik.tv`
- Production: `/pstv/w2.5ik.tv/pstv_web/.env`, node log `/pstv/w2.5ik.tv/node-w2.log` (+ `.err`), port 3000, IIS site `w2.5ik.tv`

Set once per environment (staging shown; production: `SITE=w2.5ik.tv PORT=3000 LOG=node-w2.log`):

    SITE=test.5ik.tv; PORT=3100; LOG=node-test.log; ROOT=/pstv/$SITE; ENVF=$ROOT/pstv_web/.env

## 1. Backup (mode 600)

    cp -p "$ENVF" "$ENVF.bak-20261005" && chmod 600 "$ENVF.bak-20261005" && ls -l "$ENVF.bak-20261005"

## 2. Rewrite only encrypt= and trustServerCertificate= (prints only a count)

    python3 - "$ENVF" <<'PY'
    import re,sys
    p=sys.argv[1]; out=[]; n=0
    for line in open(p,newline='').read().split('\n'):
        m=re.match(r'^(\s*DATABASE_URL_\w+\s*=\s*)(.*)$',line)
        if m:
            v=m.group(2).rstrip('\r'); cr=m.group(2)[len(v):]; q=''
            if v[:1] in '"\'' and v[-1:]==v[:1]: q=v[0]; v=v[1:-1]
            parts=[x for x in v.split(';') if not re.match(r'^\s*(encrypt|trustServerCertificate)\s*=',x,re.I)]
            while parts and parts[-1]=='': parts.pop()
            parts+=['encrypt=true','trustServerCertificate=true']
            line=m.group(1)+q+';'.join(parts)+q+cr; n+=1
        out.append(line)
    open(p,'w',newline='').write('\n'.join(out)); print('rewrote',n,'lines (expect 4)')
    PY

Check without showing secrets (prints variable name and the two flags only):

    grep -E '^DATABASE_URL_' "$ENVF" | sed -E 's/^([A-Z_]+)=.*(encrypt=[A-Za-z_]+).*(trustServerCertificate=[a-z]+).*/\1 \2 \3/' 

Expect 4 lines, each `encrypt=true trustServerCertificate=true`. If the order differs the sed shows nothing for that line, which is fine, check with `grep -c 'encrypt=true' "$ENVF"` (expect 4) and `grep -c DANGER_PLAINTEXT "$ENVF"` (expect 0).

## 3. Restart (same method as bin/deploy-win.sh: stop the site's node on its port, start it detached; IIS stays up)

    powershell.exe -NoProfile -Command "Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id \$_.OwningProcess -Force }"
    sleep 5
    WEBDIR=$(cygpath -w $ROOT/pstv_web); JS=$(cygpath -w $ROOT/pstv_web/server.js); LOGW=$(cygpath -w $ROOT/$LOG)
    powershell.exe -NoProfile -Command "\$env:PORT='$PORT'; \$env:NODE_ENV='production'; Start-Process -FilePath 'node.exe' -ArgumentList '\"$JS\"' -WorkingDirectory '$WEBDIR' -RedirectStandardOutput '$LOGW' -RedirectStandardError '$LOGW.err' -WindowStyle Hidden" </dev/null >/dev/null 2>&1
    sleep 15; powershell.exe -NoProfile -Command "Get-NetTCPConnection -LocalPort $PORT -State Listen | Select LocalPort,OwningProcess"

(Production restart drops in-flight requests for about 15 seconds. Inside the 15:00 to 17:00 Asia/Taipei window, or say deploy now.)

## 4. Verify

    curl -s -o /dev/null -w '%{http_code}\n' https://$SITE/                       # expect 200
    curl -s -X POST https://$SITE/api/pstv/devices/get-pin -H 'Content-Type: application/json' -d '{}'   # expect JSON containing a PIN (if it rejects the empty body, use the body the Roku sends)
    curl -s -o /dev/null -w '%{http_code}\n' -X POST https://$SITE/api/pstv/devices/get-pin-result -H 'Content-Type: application/json' -d '{"pin":"000000"}'   # expect 501 (as specified)
    # watch 5 min (staging) or 10 min (production) for errors:
    tail -n 200 $ROOT/$LOG $ROOT/$LOG.err | grep -i -E 'prisma|tls|ssl|certificate|handshake|ECONN|login failed' || echo "no db or tls errors"

Server side, from the web2 login (SSMS or sqlcmd as that login; do not paste the password in chat). One query per run, any of the four databases:

    SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id=@@SPID;   -- expect TRUE

Without VIEW SERVER STATE the query still works for your own session. For all web2 sessions at once (needs VIEW SERVER STATE):

    SELECT c.encrypt_option, COUNT(*) FROM sys.dm_exec_connections c JOIN sys.dm_exec_sessions s ON s.session_id=c.session_id WHERE s.program_name LIKE '%prisma%' OR s.is_user_process=1 GROUP BY c.encrypt_option;

Note: `sqlcmd` itself must be run with `-N -C` to encrypt, otherwise the check shows FALSE for the check session only, not for web2. Better evidence: run the query from inside web2's login after restart and see TRUE for web2's pooled sessions (the second query).

## 5. Rollback (restore, then restart as in step 3)

    cp -p "$ENVF.bak-20261005" "$ENVF"

Then repeat step 3. Roll back at the first Prisma, TLS or login error in the log or any non-200 on `/`.

## 6. Order and stop rule

Staging clean for 5 minutes, then production. The staging site uses `_test` databases, production uses the non-`_test` ones, so a clean staging proves the TLS handshake against the same server but not production credentials. Watch production 10 minutes.

## Local dev

Already done by the release-manager session: `/Users/mtsai/pstv/web2/pstv_web/.env` has the four entries rewritten, backup `.env.bak-20261005` (mode 600) next to it.
