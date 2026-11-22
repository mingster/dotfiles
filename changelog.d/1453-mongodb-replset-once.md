* `mac/install_mongodb.sh` adds the `replication:` block to `mongod.conf` only when it has no `replSetName`, so a second run no longer writes a duplicate key that stops mongod from starting (#1453).
