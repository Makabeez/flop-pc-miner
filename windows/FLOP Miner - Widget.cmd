@echo off
rem Opens the compact always-available widget window (Microsoft Edge app mode).
wsl -d flop-miner --cd ~ -- bash -lc "curl -s -m 2 -o /dev/null http://127.0.0.1:8650/api || { (setsid nohup python3 ~/flop-dash.py > ~/.flop-dash.log 2>&1 &); sleep 5; }"
start "" msedge --app="http://127.0.0.1:8650/?mini=1" --window-size=440,680
