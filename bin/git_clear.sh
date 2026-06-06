#!/bin/bash
#
#git gc --prune=now
git gc --prune=now --aggressive
git remote prune origin
