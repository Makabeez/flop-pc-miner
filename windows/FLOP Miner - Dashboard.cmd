@echo off
rem Opens the live dashboard in your browser (starts it first if needed).
wsl -d flop-miner --cd ~ -- bash -lc "curl -s -m 2 -o /dev/null http://127.0.0.1:8650/api || { (setsid nohup python3 ~/flop-dash.py > ~/.flop-dash.log 2>&1 &); sleep 5; }"
start "" http://127.0.0.1:8650
