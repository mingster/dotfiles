fleet-watch baseline and leads tests no longer read the real fleet-pull ship log or template sync state, so old failed pulls or a red bump PR on the host cannot fail the baseline test (Refs #1811).
