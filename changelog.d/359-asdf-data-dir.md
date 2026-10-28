Tests that change HOME now also pin ASDF_DATA_DIR, so the asdf shims keep working under a temp HOME. A new check fails when a HOME-changing test skips the asdf pin (#359).
