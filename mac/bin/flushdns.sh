#!/bin/sh
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder; say DNS cache flushed
