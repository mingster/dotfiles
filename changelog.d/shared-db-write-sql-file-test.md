The shared database write check now tests a SQL file that is written to disk before the call, and it has an allowed case for a SELECT-only SQL file. Test-only change; the hook itself is unchanged.
