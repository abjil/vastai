# Spin off to GitHub

This directory is the **entire future repository**. HomeLAN only hosts it until a public GitHub repo exists, so Vast.ai onstart can `git clone` without reaching `gitea.lan`.

## Why GitHub, not Gitea

Vast.ai instances are on the public internet. They cannot use a private LAN Gitea URL unless you also expose Gitea, which this project does not want. GitHub clone + onstart is the deployment path.

## Steps

1. Create an empty public GitHub repository (working name: `vastai-wakeup`).
2. Copy **the contents** of `machines/vastai/` to that repo root (not the `machines/vastai` folder name itself).

   ```sh
   git clone https://github.com/YOUR_USER/vastai-wakeup.git
   rsync -a --exclude '.git' machines/vastai/ vastai-wakeup/
   cd vastai-wakeup
   git add .
   git commit -m "Initial import from HomeLAN machines/vastai"
   git push -u origin main
   ```

3. Replace placeholders:
   - `YOUR_USER/vastai-wakeup` in README, DEPLOY, and `templates/onstart.vastai.sh`
   - Choose a real license and replace `LICENSE.txt`
4. Confirm GitHub Actions `CI` is green (`bin/selftest.sh`).
5. Point Vast.ai onstart at `WAKEUP_REPO_URL=https://github.com/YOUR_USER/vastai-wakeup.git`.
6. Keep HomeLAN `machines/vastai` as a snapshot or delete it after the move — do not develop in both places.

## What not to copy

- Any real `wakeup.env`
- `ACK`, `wakeup.log`, `wakeup.pid`, `runtime/`
- HomeLAN `.cursor/` context

## Later development

All further features (extra SMS providers, Vast.ai API helper, etc.) should land on GitHub, not in HomeLAN.
