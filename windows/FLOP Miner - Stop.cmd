@echo off
title FLOP Miner - Stop
wsl -d flop-miner --cd ~ -- bash -lc "./flop-miner.sh down"
wsl --terminate flop-miner
echo.
echo Miner, tunnel and dashboard stopped. You can switch the PC off.
pause
