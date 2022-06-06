#!/bin/sh

# https://www.npmjs.com/package/ftx-cli
# main account
ftx login --key 9Aqpj3qTZGlEyaDJR7o5tMJETw4GynelNWu95MsF --secret yglHNSEx_K5A2pPmbffWb2KxTpDX3pAWHLWqMOoo
# fire every hour at xx:05 minutes for dai at 2% min rate

ftx lend --min-rate 0.5 --repeat "5 * * * *"
