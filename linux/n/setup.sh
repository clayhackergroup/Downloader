#!/bin/bash
set -e

SERVICE_NAME="telegram-admin"
USER_NAME=$(whoami)
SCRIPT_DIR="$HOME/control"
PYTHON_ENV="$HOME/miniconda3/envs/tgbot/bin/python3"
SCRIPT_PATH="$SCRIPT_DIR/run.py"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}@.service"

echo "[*] Cleaning old/bad telegram packages..."
$PYTHON_ENV -m pip uninstall -y telegram python-telegram-bot || true

echo "[*] Installing required packages..."
$PYTHON_ENV -m pip install --upgrade pip
$PYTHON_ENV -m pip install python-telegram-bot==20.7 mss pillow

echo "[*] Verifying installation..."
$PYTHON_ENV -m pip show python-telegram-bot | grep Version || {
  echo "[!] python-telegram-bot not installed correctly."
  exit 1
}

# Check bot script exists
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "[!] Bot script not found at $SCRIPT_PATH"
    exit 1
fi

echo "[*] Creating systemd service file..."
sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=Telegram Admin Bot for %i
After=network.target

[Service]
Type=simple
User=%i
WorkingDirectory=/home/%i/control
ExecStart=/home/%i/miniconda3/envs/tgbot/bin/python3 /home/%i/Banana/run.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Reloading systemd..."
sudo systemctl daemon-reload

echo "[*] Enabling service for $USER_NAME..."
sudo systemctl enable ${SERVICE_NAME}@${USER_NAME}.service

echo "[*] Starting service now..."
sudo systemctl restart ${SERVICE_NAME}@${USER_NAME}.service

echo "[+] Done!"
echo "Check status with: systemctl status ${SERVICE_NAME}@${USER_NAME}.service"
echo "View logs with:   journalctl -u ${SERVICE_NAME}@${USER_NAME}.service -f"

python3 run.py
