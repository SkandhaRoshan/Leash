#!/usr/bin/env bash
# One-time setup: installs Foundry deps. Requires Foundry (https://getfoundry.sh) and git.
set -e
[ -d .git ] || git init -q
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0
forge build
echo "Setup done. Run: forge test"
