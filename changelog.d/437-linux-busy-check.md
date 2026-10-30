Fix Linux cleanup checks without lsof by preferring a single scan of process holders and batching the fuser fallback with psmisc-compatible arguments. Keep items when inspection fails.
