import os
import sys
import json
import asyncio
import subprocess
import platform
from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes

CONFIG_FILE = "config.json"


def load_config():
    if not os.path.exists(CONFIG_FILE):
        config = {"authorized_users": [], "bot_token": "YOUR_BOT_TOKEN_HERE", "shell": "/bin/bash"}
        with open(CONFIG_FILE, "w") as f:
            json.dump(config, f, indent=4)
        print(f"[!] Created {CONFIG_FILE} - edit it with your bot token and user IDs")
        sys.exit(1)
    with open(CONFIG_FILE) as f:
        return json.load(f)


config = load_config()
AUTHORIZED_USERS = config["authorized_users"]
BOT_TOKEN = config["bot_token"]
SHELL = config.get("shell", "/bin/bash")
IS_WINDOWS = platform.system() == "Windows"


async def safe_reply(update: Update, text: str, **kwargs):
    try:
        return await update.message.reply_text(text, **kwargs)
    except Exception:
        try:
            return await update.get_bot().send_message(chat_id=update.effective_chat.id, text=text, **kwargs)
        except Exception:
            return None

def restricted(func):
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE, *args, **kwargs):
        if update.effective_user.id not in AUTHORIZED_USERS:
            await safe_reply(update, "Unauthorized.")
            return
        return await func(update, context, *args, **kwargs)
    return wrapper


class Session:
    def __init__(self):
        self.cwd = os.getcwd()

    async def execute(self, command: str, timeout: int = 120):
        try:
            def run():
                if IS_WINDOWS:
                    return subprocess.run(
                        ["powershell.exe", "-NoProfile", "-Command", command],
                        capture_output=True,
                        text=True,
                        timeout=timeout,
                        cwd=self.cwd,
                    )
                else:
                    return subprocess.run(
                        command,
                        shell=True,
                        executable=SHELL,
                        capture_output=True,
                        text=True,
                        timeout=timeout,
                        cwd=self.cwd,
                    )
            result = await asyncio.to_thread(run)
            output = result.stdout + result.stderr

            if command.strip().startswith("cd "):
                parts = command.strip().split(None, 1)
                if len(parts) == 2:
                    new_dir = os.path.expanduser(parts[1])
                    possible = os.path.join(self.cwd, new_dir) if not os.path.isabs(new_dir) else new_dir
                    if os.path.isdir(possible):
                        self.cwd = os.path.abspath(possible)
                        output = f"Changed directory to: {self.cwd}"
                    else:
                        output = output or f"cd: {new_dir}: No such directory"

            return output, None
        except subprocess.TimeoutExpired:
            return "", f"Command timed out ({timeout}s)"
        except Exception as e:
            return "", str(e)

    async def download(self, url: str, timeout: int = 300):
        import urllib.request
        try:
            def dl():
                fname = url.split("/")[-1].split("?")[0] or "downloaded_file"
                urllib.request.urlretrieve(url, os.path.join(self.cwd, fname))
                return f"Downloaded: {fname}"
            result = await asyncio.to_thread(dl)
            return result, None
        except Exception as e:
            return "", str(e)


session = Session()


async def run_and_reply(update: Update, command: str, timeout: int = 120):
    msg = await safe_reply(update, "Running...")
    output, error = await session.execute(command, timeout=timeout)
    text = output if not error else f"Error: {error}"
    MAX = 4000
    if len(text) > MAX:
        text = text[:MAX] + "\n\n... (truncated)"
    try:
        if msg:
            await msg.edit_text(f"```\n{text}\n```", parse_mode="Markdown")
    except Exception:
        await safe_reply(update, f"```\n{text}\n```", parse_mode="Markdown")


@restricted
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    await safe_reply(update, f"Your ID: {uid} | CWD: {session.cwd}")


@restricted
async def cmd_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    command = " ".join(context.args)
    if not command:
        await safe_reply(update, "Usage: /cmd <command>")
        return
    await run_and_reply(update, command)


@restricted
async def shell_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    command = update.message.text.strip()
    if not command:
        return
    await run_and_reply(update, command)


@restricted
async def download_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    url = " ".join(context.args)
    if not url:
        await safe_reply(update, "Usage: /download <url>")
        return
    await safe_reply(update, f"Downloading {url}...")
    output, error = await session.download(url)
    text = output if not error else f"Error: {error}"
    MAX = 4000
    if len(text) > MAX:
        text = text[:MAX] + "\n\n... (truncated)"
    await safe_reply(update, f"```\n{text}\n```", parse_mode="Markdown")


@restricted
async def pwd_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await safe_reply(update, session.cwd)


@restricted
async def upload_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    file_path = " ".join(context.args)
    if not file_path:
        await safe_reply(update, "Usage: /upload <filepath>")
        return
    file_path = os.path.expanduser(file_path)
    if not os.path.isabs(file_path):
        file_path = os.path.join(session.cwd, file_path)
    if not os.path.isfile(file_path):
        await safe_reply(update, f"File not found: {file_path}")
        return
    try:
        with open(file_path, "rb") as f:
            await update.message.reply_document(f, filename=os.path.basename(file_path))
    except Exception as e:
        await safe_reply(update, f"Upload error: {e}")


def main():
    if BOT_TOKEN == "YOUR_BOT_TOKEN_HERE":
        print("[!] Edit config.json with your bot token and authorized user IDs first")
        sys.exit(1)

    if "--bg" not in sys.argv:
        if IS_WINDOWS:
            subprocess.Popen(
                ["powershell.exe", "-WindowStyle", "Hidden", "-Command",
                 f"python \"{os.path.abspath(__file__)}\" --bg"],
                creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0,
            )
        else:
            pid = os.fork()
            if pid > 0:
                sys.exit(0)
        print("[+] Bot running in background")
        return

    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("cmd", cmd_handler))
    app.add_handler(CommandHandler("download", download_handler))
    app.add_handler(CommandHandler("upload", upload_handler))
    app.add_handler(CommandHandler("pwd", pwd_handler))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, shell_handler))

    app.run_polling()


if __name__ == "__main__":
    main()
