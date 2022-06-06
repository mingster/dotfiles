#!/bin/sh

# https://www.npmjs.com/package/ftx-cli

ftx login --key 9Aqpj3qTZGlEyaDJR7o5tMJETw4GynelNWu95MsF --secret yglHNSEx_K5A2pPmbffWb2KxTpDX3pAWHLWqMOoo --subaccount save

# fire every hour at xx:05 minutes for dai at 2% min rate
ftx lend --currency dai --min-rate 1 --repeat "5 * * * *"
