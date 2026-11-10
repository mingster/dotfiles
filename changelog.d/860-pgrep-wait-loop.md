The Orca upgrade in the fleet toolchain check now waits for the old process by pid instead of looping on `pgrep -f`, which satisfies the head-checks lint and still waits up to 30 seconds.
