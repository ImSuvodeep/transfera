#!/bin/bash
cd /Users/suvodeepchowdhury/Transfera/server
while true; do
  echo "Starting LocalTunnel..."
  npx localtunnel --port 3000 --subdomain transfera-signaling-999
  echo "LocalTunnel crashed. Restarting in 2 seconds..."
  sleep 2
done
