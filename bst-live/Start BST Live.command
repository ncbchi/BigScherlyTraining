#!/bin/bash
# Starts the BST Live listener (the phone sends live sessions here over Wi-Fi). Leave the window open.
cd "$(dirname "$0")"
exec /usr/bin/python3 listen.py
