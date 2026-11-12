agy always runs through `bin/agy`, which unsets the SSH variables so it reads the keychain token store. `pr-review.sh`, `fleet-toolchain-check.sh` and `usage-gate.py` launch it that way (#897).
