fleet-pull tests stub the secrets gate with SECRETS_GATE, so they no longer call sudo or /opt/secrets-gate/secrets-gate on hosts where the gate is installed (#1983).
