#!/bin/bash
set -e

INSTALL_DIR="/new/temp"
BOT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[+] Creating install directory..."
mkdir -p "$INSTALL_DIR" 2>/dev/null || sudo mkdir -p "$INSTALL_DIR"
sudo chown "$(whoami)":"$(whoami)" "$INSTALL_DIR" 2>/dev/null || true

echo "[+] Copying bot files..."
cp "$BOT_DIR/bot.py" "$INSTALL_DIR/"
[ -f "$BOT_DIR/requirements.txt" ] && cp "$BOT_DIR/requirements.txt" "$INSTALL_DIR/"
[ -f "$BOT_DIR/config.json" ] && cp "$BOT_DIR/config.json" "$INSTALL_DIR/"

cd "$INSTALL_DIR"

echo "[+] Installing Python & pip..."
apt-get update -y 2>/dev/null || sudo apt-get update -y
apt-get install -y python3 python3-pip python3-venv 2>/dev/null || sudo apt-get install -y python3 python3-pip python3-venv

echo "[+] Installing python-telegram-bot..."
pip3 install python-telegram-bot 2>/dev/null || pip install python-telegram-bot

if [ ! -f config.json ]; then
    echo "[+] Creating config template..."
    cat > config.json << 'EOF'
{
    "authorized_users": [],
    "bot_token": "YOUR_BOT_TOKEN_HERE",
    "shell": "/bin/bash"
}
EOF
fi

echo ""
echo "===================================="
echo "  SETUP COMPLETE"
echo "===================================="
echo ""

if grep -q "YOUR_BOT_TOKEN_HERE" config.json 2>/dev/null; then
    echo "[!] config.json still has placeholder token."
    echo "    Edit it first: nano $INSTALL_DIR/config.json"
    echo "    Then run: cd $INSTALL_DIR && python3 bot.py"
else
    echo "[+] Starting bot in background..."
    cd "$INSTALL_DIR" && python3 bot.py
    echo "[+] Bot is running! Send /start on Telegram."
    echo ""
    echo "    Stop bot: pkill -f bot.py"
fi
echo ""
