#!/bin/bash
sudo mkdir -p /opt/.projects/m
cd /opt/.projects/m
mkdir boot
cd boot

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Config
BOT_DIR="/opt/kali-bot"
VENV="$BOT_DIR/venv"
SERVICE="/etc/systemd/system/kali-bot.service"
LOG="/var/log/kali_bot.log"

echo -e "${BLUE}[*] Tool  Installer${NC}"

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Run as root: sudo bash install.sh${NC}"
    exit 1
fi

# Function to retry command
retry_cmd() {
    local cmd="$1"
    local retries="${2:-3}"
    local count=0
    
    while [ $count -lt $retries ]; do
        echo -e "${BLUE}[*] Executing: $cmd${NC}"
        if eval "$cmd" 2>&1; then
            return 0
        fi
        count=$((count + 1))
        if [ $count -lt $retries ]; then
            echo -e "${YELLOW}[!] Failed, retrying ($count/$retries)...${NC}"
            sleep 2
        fi
    done
    
    echo -e "${RED}[!] Failed after $retries attempts: $cmd${NC}"
    return 1
}

# Fix APT issues
fix_apt() {
    echo -e "${BLUE}[*] Fixing APT...${NC}"
    pkill -9 apt apt-get 2>/dev/null || true
    sleep 1
    rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null || true
    dpkg --configure -a 2>/dev/null || true
    return 0
}

# Update system
echo -e "${BLUE}[*] Updating package lists...${NC}"
if ! apt-get update -qq 2>/dev/null; then
    echo -e "${YELLOW}[!] First update failed, fixing APT...${NC}"
    fix_apt
    apt-get update -qq || true
fi

# Install dependencies
echo -e "${BLUE}[*] Installing dependencies...${NC}"
retry_cmd "apt-get install -y -qq python3 python3-pip python3-venv imagemagick curl" 5 || true

# Create bot directory
echo -e "${BLUE}[*] Creating bot directory...${NC}"
mkdir -p "$BOT_DIR"

# Copy bot script
echo -e "${BLUE}[*] Installing bot script...${NC}"
if [ ! -f "run.py" ]; then
    echo -e "${RED}[!] run.py not found in current directory${NC}"
    exit 1
fi
cp run.py "$BOT_DIR/run.py"
chmod +x "$BOT_DIR/run.py"

# Setup virtual environment
echo -e "${BLUE}[*] Creating virtual environment...${NC}"
if [ -d "$VENV" ]; then
    echo -e "${YELLOW}[!] Removing old venv...${NC}"
    rm -rf "$VENV"
fi

if ! python3 -m venv "$VENV" 2>&1; then
    echo -e "${RED}[!] Venv creation failed, attempting fix...${NC}"
    apt-get install -y -qq python3-venv 2>/dev/null || true
    python3 -m venv "$VENV" || {
        echo -e "${RED}[!] Could not create venv${NC}"
        exit 1
    }
fi

# Install Python packages
echo -e "${BLUE}[*] Installing Python packages...${NC}"
"$VENV/bin/pip" install -q --upgrade pip setuptools wheel 2>/dev/null || true
retry_cmd "$VENV/bin/pip install -q python-telegram-bot" 3 || {
    echo -e "${RED}[!] Failed to install python-telegram-bot${NC}"
    exit 1
}

# Create systemd service
echo -e "${BLUE}[*] Creating systemd service...${NC}"
cat > "$SERVICE" << EOF
[Unit]
Description=Kali Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$BOT_DIR
ExecStart=$VENV/bin/python3 $BOT_DIR/run.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Enable service
systemctl daemon-reload
systemctl enable kali-bot.service

# Create log file
touch "$LOG"
chmod 666 "$LOG"

# Set permissions
chown -R root:root "$BOT_DIR"
chmod 755 "$BOT_DIR"
chmod 755 "$BOT_DIR/run.py"

# Create helper command
echo -e "${BLUE}[*] Creating helper command...${NC}"
cat > /usr/local/bin/kalibot << 'EOF'
#!/bin/bash
case "$1" in
    start)
        systemctl start kali-bot
        echo "[+] Bot started"
        ;;
    stop)
        systemctl stop kali-bot
        echo "[+] Bot stopped"
        ;;
    restart)
        systemctl restart kali-bot
        echo "[+] Bot restarted"
        ;;
    status)
        systemctl status kali-bot
        ;;
    logs)
        journalctl -u kali-bot -f
        ;;
    *)
        echo "Usage: kalibot {start|stop|restart|status|logs}"
        exit 1
        ;;
esac
EOF
chmod +x /usr/local/bin/kalibot

# Start bot
echo -e "${BLUE}[*] Starting bot...${NC}"
systemctl start kali-bot

sleep 2

# Check status
if systemctl is-active --quiet kali-bot; then
    echo -e "${GREEN}[✓] Installation Complete!${NC}"
    echo ""
    echo -e "${GREEN}[✓] Bot is running in background${NC}"
    echo -e "${GREEN}[✓] Auto-start on boot enabled${NC}"
    echo ""
    echo -e "${BLUE}[*] Commands:${NC}"
    echo "    kalibot start      - Start bot"
    echo "    kalibot stop       - Stop bot"
    echo "    kalibot restart    - Restart bot"
    echo "    kalibot status     - Check status"
    echo "    kalibot logs       - View logs"
    echo ""
    echo -e "${BLUE}[*] Logs: $LOG${NC}"
else
    echo -e "${YELLOW}[!] Bot failed to start, checking logs...${NC}"
    journalctl -u kali-bot -n 20
    echo -e "${YELLOW}[!] Trying to fix and restart...${NC}"
    systemctl restart kali-bot
    sleep 2
    systemctl status kali-bot
fi

clear
