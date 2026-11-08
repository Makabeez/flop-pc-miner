@echo off
title FLOP Miner - Status
wsl -d flop-miner --cd ~ -- bash -lc "./flop-miner.sh status"
pause
