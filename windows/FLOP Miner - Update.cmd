@echo off
title FLOP Miner - Update
rem After Flop upgrades the chain: newest official images that support it, then restarts the miner if it was running.
wsl -d flop-miner --cd ~ -- bash -lc "./flop-miner.sh update"
pause
