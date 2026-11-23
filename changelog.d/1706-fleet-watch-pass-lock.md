fleet-watch takes an exclusive lock beside the state file for each pass, so the loop, the automation and a manual run cannot start two verifiers for the same PR head (#1706).
