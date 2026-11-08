@echo off
title FLOP Miner
rem Starts the dashboard (if needed) and the miner, then follows the worker log. Closing this window does NOT stop the miner.
start "" cmd /c "timeout /t 12 /nobreak >nul & start http://127.0.0.1:8650"
wsl -d flop-miner --cd ~ -- bash -lc "(curl -s -m 2 -o /dev/null http://127.0.0.1:8650/api || setsid nohup python3 ~/flop-dash.py > ~/.flop-dash.log 2>&1 &); ./flop-miner.sh up && ./flop-miner.sh logs; exec bash"
