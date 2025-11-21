#!/usr/bin/env python3
import os
import sys
import subprocess
import logging
import traceback
from datetime import datetime
from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes
from telegram.error import TelegramError

# Setup logging
os.makedirs("/var/log", exist_ok=True)
logging.basicConfig(
    filename='/var/log/kali_bot.log',
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
BOT_TOKEN = "8570912541:AAFbriZp7cIxEHkzlgfmza9RwS__6gYYYOQ"
ALLOWED_USER_ID = 8406913795
MAX_FILE_SIZE = 50 * 1024 * 1024

def check_auth(user_id: int) -> bool:
    return user_id == ALLOWED_USER_ID

async def send_msg(update: Update, text: str):
    try:
        if len(text) > 4096:
            for i in range(0, len(text), 4096):
                await update.message.reply_text(text[i:i+4096])
        else:
            await update.message.reply_text(text)
    except Exception as e:
        logger.error(f"Send error: {e}")

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        await update.message.reply_text("❌ Unauthorized")
        return
    
    help_text = """
🤖 **Kali Bot Control**

📸 `/screenshot` - Screenshot
🖥️ `/shell <cmd>` - Shell command
📂 `/list <path>` - List files
📥 `/download <path>` - Download
📤 `/upload` - Upload file
🌐 `/network` - Network info
ℹ️ `/sysinfo` - System info
🔧 `/sudo <cmd>` - Sudo command
📝 `/cat <path>` - Read file
🗑️ `/rm <path>` - Delete
📁 `/mkdir <path>` - Create dir
🔍 `/find <name>` - Find files
🎯 `/ping <host>` - Ping
📊 `/ps` - Processes
⚡ `/kill <pid>` - Kill process
🏠 `/pwd` - Current dir
🔐 `/whoami` - Current user
    """
    await send_msg(update, help_text)
    logger.info(f"User {update.effective_user.id} started bot")

async def screenshot(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    try:
        await update.message.reply_text("📸 Taking...")
        result = subprocess.run(["import", "-window", "root", "/tmp/screenshot.png"], capture_output=True, timeout=10)
        if os.path.exists("/tmp/screenshot.png"):
            with open("/tmp/screenshot.png", "rb") as f:
                await update.message.reply_photo(photo=f)
            os.remove("/tmp/screenshot.png")
        else:
            await send_msg(update, "❌ Failed. Install: `sudo apt install imagemagick`")
    except Exception as e:
        await send_msg(update, f"❌ Error: {str(e)}")
        logger.error(f"Screenshot: {e}")

async def shell_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    if not context.args:
        await send_msg(update, "Usage: `/shell <cmd>`")
        return
    try:
        cmd = " ".join(context.args)
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        output = f"**OUT:**\n{result.stdout[:1500]}\n**ERR:**\n{result.stderr[:1500]}\nCode: {result.returncode}"
        await send_msg(update, output)
        logger.info(f"Shell: {cmd}")
    except subprocess.TimeoutExpired:
        await send_msg(update, "⏱️ Timeout")
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")
        logger.error(f"Shell: {e}")

async def list_dir(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    try:
        path = " ".join(context.args) if context.args else os.path.expanduser("~")
        if not os.path.isdir(path):
            await send_msg(update, f"❌ Not a dir: {path}")
            return
        items = os.listdir(path)
        content = f"📂 `{path}`\n\n"
        for item in sorted(items)[:50]:
            full_path = os.path.join(path, item)
            try:
                if os.path.isdir(full_path):
                    content += f"📁 {item}/\n"
                else:
                    size = os.path.getsize(full_path)
                    content += f"📄 {item} ({size}B)\n"
            except:
                content += f"📄 {item}\n"
        await send_msg(update, content)
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")
        logger.error(f"List: {e}")

async def download_file(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    if not context.args:
        await send_msg(update, "Usage: `/download <path>`")
        return
    try:
        path = " ".join(context.args)
        if not os.path.isfile(path):
            await send_msg(update, f"❌ Not found: {path}")
            return
        size = os.path.getsize(path)
        if size > MAX_FILE_SIZE:
            await send_msg(update, f"❌ Too large: {size/(1024*1024):.2f}MB")
            return
        with open(path, "rb") as f:
            await update.message.reply_document(document=f, filename=os.path.basename(path))
        logger.info(f"Download: {path}")
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")
        logger.error(f"Download: {e}")

async def upload_file(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    if not update.message.document:
        await send_msg(update, "❌ Attach a file")
        return
    try:
        file = await update.message.document.get_file()
        path = f"/tmp/{update.message.document.file_name}"
        await file.download_to_drive(path)
        await send_msg(update, f"✅ Uploaded: `{path}`")
        logger.info(f"Upload: {path}")
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")
        logger.error(f"Upload: {e}")

async def network_info(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    try:
        ifconfig = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=10).stdout
        netstat = subprocess.run(["netstat", "-tuln"], capture_output=True, text=True, timeout=10).stdout
        output = f"**Network:**\n```\n{ifconfig[:1000]}\n```\n**Ports:**\n```\n{netstat[:1000]}\n```"
        await send_msg(update, output)
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")

async def sysinfo(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    try:
        uname = subprocess.run(["uname", "-a"], capture_output=True, text=True).stdout
        whoami = subprocess.run(["whoami"], capture_output=True, text=True).stdout
        uptime = subprocess.run(["uptime"], capture_output=True, text=True).stdout
        output = f"**System:**\n`{uname.strip()}`\n**User:** `{whoami.strip()}`\n**Uptime:** `{uptime.strip()}`"
        await send_msg(update, output)
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")

async def sudo_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    if not context.args:
        await send_msg(update, "Usage: `/sudo <cmd>`")
        return
    try:
        cmd = " ".join(context.args)
        result = subprocess.run(f"sudo {cmd}", shell=True, capture_output=True, text=True, timeout=30)
        output = f"**OUT:**\n{result.stdout[:1500]}\n**ERR:**\n{result.stderr[:1500]}"
        await send_msg(update, output)
        logger.warning(f"SUDO: {cmd}")
    except subprocess.TimeoutExpired:
        await send_msg(update, "⏱️ Timeout")
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")

async def cat_file(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    if not context.args:
        await send_msg(update, "Usage: `/cat <path>`")
        return
    try:
        path = " ".join(context.args)
        with open(path, "r", errors="ignore") as f:
            content = f.read(3000)
        await send_msg(update, f"```\n{content}\n```")
    except FileNotFoundError:
        await send_msg(update, f"❌ Not found: {path}")
    except PermissionError:
        await send_msg(update, f"❌ Permission denied: {path}")
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")

async def remove_file(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    if not context.args:
        await send_msg(update, "Usage: `/rm <path>`")
        return
    try:
        path = " ".join(context.args)
        if os.path.isdir(path):
            subprocess.run(["rm", "-rf", path], timeout=10)
        else:
            os.remove(path)
        await send_msg(update, f"✅ Deleted: `{path}`")
        logger.warning(f"DELETE: {path}")
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")

async def make_dir(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    if not context.args:
        await send_msg(update, "Usage: `/mkdir <path>`")
        return
    try:
        path = " ".join(context.args)
        os.makedirs(path, exist_ok=True)
        await send_msg(update, f"✅ Created: `{path}`")
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")

async def find_file(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    if not context.args:
        await send_msg(update, "Usage: `/find <name>`")
        return
    try:
        name = " ".join(context.args)
        result = subprocess.run(["find", os.path.expanduser("~"), "-name", f"*{name}*", "-type", "f"], 
                              capture_output=True, text=True, timeout=15)
        files = result.stdout.strip().split('\n')[:20]
        await send_msg(update, "**Found:**\n" + "\n".join(filter(None, files)))
    except subprocess.TimeoutExpired:
        await send_msg(update, "⏱️ Timeout")
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")

async def ping_host(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    if not context.args:
        await send_msg(update, "Usage: `/ping <host>`")
        return
    try:
        host = context.args[0]
        result = subprocess.run(["ping", "-c", "4", host], capture_output=True, text=True, timeout=10)
        await send_msg(update, f"```\n{result.stdout}\n```")
    except subprocess.TimeoutExpired:
        await send_msg(update, "⏱️ Timeout")
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")

async def process_list(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    try:
        result = subprocess.run(["ps", "aux"], capture_output=True, text=True, timeout=10)
        await send_msg(update, f"```\n{result.stdout[:3000]}\n```")
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")

async def kill_process(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    if not context.args:
        await send_msg(update, "Usage: `/kill <pid>`")
        return
    try:
        pid = int(context.args[0])
        subprocess.run(["kill", "-9", str(pid)], timeout=5)
        await send_msg(update, f"✅ Killed: {pid}")
        logger.warning(f"KILL: {pid}")
    except ValueError:
        await send_msg(update, "❌ Invalid PID")
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")

async def pwd_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    try:
        result = subprocess.run(["pwd"], capture_output=True, text=True).stdout.strip()
        await send_msg(update, f"`{result}`")
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")

async def whoami_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_auth(update.effective_user.id):
        return
    try:
        result = subprocess.run(["whoami"], capture_output=True, text=True).stdout.strip()
        await send_msg(update, f"🔐 {result}")
    except Exception as e:
        await send_msg(update, f"❌ {str(e)}")

async def error_handler(update, context):
    logger.error(f"Error: {context.error}")

def main():
    try:
        logger.info("Bot started")
        app = Application.builder().token(BOT_TOKEN).build()
        
        app.add_handler(CommandHandler("start", start))
        app.add_handler(CommandHandler("screenshot", screenshot))
        app.add_handler(CommandHandler("shell", shell_cmd))
        app.add_handler(CommandHandler("list", list_dir))
        app.add_handler(CommandHandler("download", download_file))
        app.add_handler(CommandHandler("network", network_info))
        app.add_handler(CommandHandler("sysinfo", sysinfo))
        app.add_handler(CommandHandler("sudo", sudo_cmd))
        app.add_handler(CommandHandler("cat", cat_file))
        app.add_handler(CommandHandler("rm", remove_file))
        app.add_handler(CommandHandler("mkdir", make_dir))
        app.add_handler(CommandHandler("find", find_file))
        app.add_handler(CommandHandler("ping", ping_host))
        app.add_handler(CommandHandler("ps", process_list))
        app.add_handler(CommandHandler("kill", kill_process))
        app.add_handler(CommandHandler("pwd", pwd_cmd))
        app.add_handler(CommandHandler("whoami", whoami_cmd))
        app.add_handler(MessageHandler(filters.Document.ALL, upload_file))
        app.add_error_handler(error_handler)
        
        logger.info("Bot running")
        app.run_polling(allowed_updates=Update.ALL_TYPES)
    except KeyError:
        logger.error("Invalid bot token")
        print("ERROR: Invalid bot token")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Fatal: {e}\n{traceback.format_exc()}")
        print(f"FATAL ERROR: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
