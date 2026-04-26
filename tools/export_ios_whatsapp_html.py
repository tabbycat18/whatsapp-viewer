#!/usr/bin/env python3
import argparse
import html
import json
import mimetypes
import os
import re
import shutil
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import quote


IOS_EPOCH = datetime(2001, 1, 1)
DEFAULT_INPUT = Path("data/iphone-whatsapp-export/AppDomainGroup-group.net.whatsapp.WhatsApp.shared")
DEFAULT_OUTPUT = Path("data/ios-html-export")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Export an extracted iOS WhatsApp ChatStorage.sqlite database to browsable HTML."
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=DEFAULT_INPUT,
        help="Extracted WhatsApp shared folder containing ChatStorage.sqlite.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="Output folder for the generated HTML viewer.",
    )
    parser.add_argument(
        "--title",
        default="WhatsApp iOS Export",
        help="Title shown in the generated viewer.",
    )
    parser.add_argument(
        "--limit-chats",
        type=int,
        help="Export only the first N chats, useful for quick test runs.",
    )
    parser.add_argument(
        "--copy-media",
        action="store_true",
        help="Copy linked media into the HTML export instead of linking back to the extracted backup folder.",
    )
    return parser.parse_args()


def connect_database(db_path):
    uri = f"file:{quote(str(db_path.resolve()))}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA query_only = ON")
    return conn


def ios_datetime(value):
    if value is None:
        return ""
    try:
        return (IOS_EPOCH + timedelta(seconds=float(value))).strftime("%Y-%m-%d %H:%M:%S")
    except (TypeError, ValueError, OverflowError):
        return ""


def safe_name(value):
    value = value or "chat"
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", value.strip())
    value = value.strip(".-")
    return value[:80] or "chat"


def chat_title(row):
    for key in ("ZPARTNERNAME", "ZCONTACTIDENTIFIER", "ZCONTACTJID"):
        value = row[key]
        if value:
            return str(value)
    return f"Chat {row['Z_PK']}"


def html_page(title, body, extra_head=""):
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)}</title>
  <meta name="theme-color" content="#f5f3ee">
  <link rel="manifest" href="manifest.webmanifest">
  <link rel="stylesheet" href="assets/style.css">
  {extra_head}
</head>
<body>
{body}
</body>
</html>
"""


def write_text(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def query_chats(conn, limit):
    sql = """
        SELECT
            c.Z_PK,
            c.ZCONTACTJID,
            c.ZCONTACTIDENTIFIER,
            c.ZPARTNERNAME,
            c.ZLASTMESSAGEDATE,
            c.ZMESSAGECOUNTER,
            c.ZREMOVED,
            c.ZHIDDEN,
            count(m.Z_PK) AS exported_message_count,
            max(m.ZMESSAGEDATE) AS exported_last_message_date
        FROM ZWACHATSESSION c
        LEFT JOIN ZWAMESSAGE m ON m.ZCHATSESSION = c.Z_PK
        GROUP BY
            c.Z_PK,
            c.ZCONTACTJID,
            c.ZCONTACTIDENTIFIER,
            c.ZPARTNERNAME,
            c.ZLASTMESSAGEDATE,
            c.ZMESSAGECOUNTER,
            c.ZREMOVED,
            c.ZHIDDEN
        ORDER BY exported_last_message_date DESC
    """
    if limit:
        sql += " LIMIT ?"
        return conn.execute(sql, (limit,)).fetchall()
    return conn.execute(sql).fetchall()


def query_messages(conn, chat_pk):
    return conn.execute(
        """
        SELECT
            m.Z_PK,
            m.ZISFROMME,
            m.ZFROMJID,
            m.ZTOJID,
            m.ZPUSHNAME,
            m.ZTEXT,
            m.ZMESSAGEDATE,
            m.ZMESSAGETYPE,
            m.ZMESSAGESTATUS,
            mi.ZMEDIALOCALPATH,
            mi.ZTHUMBNAILLOCALPATH,
            mi.ZTITLE,
            mi.ZFILESIZE,
            mi.ZMOVIEDURATION,
            mi.ZLATITUDE,
            mi.ZLONGITUDE,
            mi.ZMEDIAURL
        FROM ZWAMESSAGE m
        LEFT JOIN ZWAMEDIAITEM mi ON mi.ZMESSAGE = m.Z_PK
        WHERE m.ZCHATSESSION = ?
        ORDER BY m.ZMESSAGEDATE ASC, m.Z_PK ASC
        """,
        (chat_pk,),
    )


def relative_media_url(source_root, output_dir, base_dir, media_path, copy_media):
    if not media_path:
        return ""

    source = (source_root / media_path).resolve()
    if not source.exists():
        return ""

    if copy_media:
        destination = output_dir / "media" / media_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists() or source.stat().st_mtime > destination.stat().st_mtime:
            shutil.copy2(source, destination)
        return os.path.relpath(destination, base_dir)

    return os.path.relpath(source, base_dir)


def render_media(url, title):
    if not url:
        return ""

    escaped_url = html.escape(url)
    escaped_title = html.escape(title or Path(url).name)
    mime, _encoding = mimetypes.guess_type(url)

    if mime and mime.startswith("image/"):
        return f'<a class="media-link" href="{escaped_url}"><img src="{escaped_url}" alt="{escaped_title}" loading="lazy"></a>'
    if mime and mime.startswith("video/"):
        return f'<video controls preload="metadata" src="{escaped_url}"></video>'
    if mime and mime.startswith("audio/"):
        return f'<audio controls src="{escaped_url}"></audio>'

    return f'<a class="attachment" href="{escaped_url}">{escaped_title}</a>'


def render_message(row, source_root, output_dir, base_dir, copy_media):
    classes = "message from-me" if row["ZISFROMME"] else "message from-them"
    sender = "You" if row["ZISFROMME"] else (row["ZPUSHNAME"] or row["ZFROMJID"] or "Them")
    text = html.escape(row["ZTEXT"] or "").replace("\n", "<br>")
    media_url = relative_media_url(source_root, output_dir, base_dir, row["ZMEDIALOCALPATH"], copy_media)
    media = render_media(media_url, row["ZTITLE"])

    meta = {
        "date": ios_datetime(row["ZMESSAGEDATE"]),
        "type": row["ZMESSAGETYPE"],
        "status": row["ZMESSAGESTATUS"],
    }
    if row["ZFILESIZE"]:
        meta["size"] = row["ZFILESIZE"]
    if row["ZLATITUDE"] or row["ZLONGITUDE"]:
        meta["location"] = f"{row['ZLATITUDE']}, {row['ZLONGITUDE']}"

    data_meta = html.escape(json.dumps(meta, ensure_ascii=False))
    body = text or ""
    if media:
        body += media
    if not body:
        body = '<span class="empty">Unsupported or empty message</span>'

    return f"""
      <article class="{classes}" data-meta="{data_meta}">
        <div class="sender">{html.escape(str(sender))}</div>
        <div class="bubble">{body}</div>
        <time>{html.escape(meta["date"])}</time>
      </article>
"""


def write_chat_page(conn, source_root, output_dir, chat, filename, copy_media):
    title = chat_title(chat)
    base_dir = output_dir / "chats"
    messages = []
    for row in query_messages(conn, chat["Z_PK"]):
        messages.append(render_message(row, source_root, output_dir, base_dir, copy_media))

    body = f"""
<main class="chat-page">
  <header class="chat-header">
    <a href="../index.html">All chats</a>
    <h1>{html.escape(title)}</h1>
    <p>{len(messages):,} messages</p>
  </header>
  <section class="messages">
    {''.join(messages)}
  </section>
</main>
"""
    write_text(
        output_dir / "chats" / filename,
        html_page(title, body)
        .replace('href="assets/style.css"', 'href="../assets/style.css"')
        .replace('href="manifest.webmanifest"', 'href="../manifest.webmanifest"'),
    )


def write_index(output_dir, title, chats, filenames):
    rows = []
    for chat, filename in zip(chats, filenames):
        name = html.escape(chat_title(chat))
        jid = html.escape(chat["ZCONTACTJID"] or "")
        count = int(chat["exported_message_count"] or 0)
        last = ios_datetime(chat["exported_last_message_date"] or chat["ZLASTMESSAGEDATE"])
        rows.append(
            f"""
      <a class="chat-row" href="chats/{html.escape(filename)}">
        <span class="chat-name">{name}</span>
        <span class="chat-jid">{jid}</span>
        <span class="chat-count">{count:,} messages</span>
        <time>{html.escape(last)}</time>
      </a>
"""
        )

    body = f"""
<main class="index-page">
  <header class="index-header">
    <h1>{html.escape(title)}</h1>
    <p>{len(chats):,} chats exported</p>
  </header>
  <section class="chat-list">
    {''.join(rows)}
  </section>
</main>
"""
    write_text(output_dir / "index.html", html_page(title, body))


def write_css(output_dir):
    write_text(
        output_dir / "assets" / "style.css",
        """* {
  box-sizing: border-box;
}

body {
  margin: 0;
  color: #17221f;
  background: #f5f3ee;
  font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}

a {
  color: inherit;
}

.index-page,
.chat-page {
  max-width: 980px;
  margin: 0 auto;
  padding: 24px;
}

.index-header,
.chat-header {
  position: sticky;
  top: 0;
  z-index: 2;
  padding: 16px 0;
  background: #f5f3ee;
  border-bottom: 1px solid #ddd8cd;
}

h1 {
  margin: 0 0 6px;
  font-size: 28px;
  font-weight: 650;
}

p {
  margin: 0;
  color: #66706b;
}

.chat-list {
  display: grid;
  gap: 1px;
  margin-top: 16px;
  overflow: hidden;
  border: 1px solid #ddd8cd;
  border-radius: 8px;
  background: #ddd8cd;
}

.chat-row {
  display: grid;
  grid-template-columns: minmax(180px, 1fr) auto;
  gap: 4px 16px;
  padding: 13px 16px;
  text-decoration: none;
  background: #fffefa;
}

.chat-row:hover {
  background: #edf7f1;
}

.chat-name {
  font-weight: 650;
}

.chat-jid,
.chat-count,
.chat-row time {
  color: #66706b;
  font-size: 13px;
}

.chat-jid {
  overflow-wrap: anywhere;
}

.chat-count,
.chat-row time {
  text-align: right;
}

.messages {
  display: grid;
  gap: 10px;
  padding: 18px 0 32px;
}

.message {
  max-width: 78%;
}

.from-me {
  justify-self: end;
}

.from-them {
  justify-self: start;
}

.sender {
  margin: 0 10px 3px;
  color: #66706b;
  font-size: 12px;
}

.bubble {
  padding: 9px 11px;
  border-radius: 8px;
  background: #ffffff;
  border: 1px solid #e1ddd4;
  overflow-wrap: anywhere;
}

.from-me .bubble {
  background: #dff3dc;
  border-color: #c9e7c5;
}

.message time {
  display: block;
  margin: 3px 10px 0;
  color: #7b837f;
  font-size: 11px;
}

img,
video {
  display: block;
  max-width: min(460px, 100%);
  max-height: 520px;
  margin-top: 8px;
  border-radius: 6px;
}

audio {
  display: block;
  width: min(380px, 100%);
  margin-top: 8px;
}

.attachment {
  display: inline-block;
  margin-top: 8px;
  color: #0f6b55;
  font-weight: 600;
}

.empty {
  color: #7b837f;
  font-style: italic;
}

@media (max-width: 700px) {
  .index-page,
  .chat-page {
    padding: 14px;
  }

  .chat-row {
    grid-template-columns: 1fr;
  }

  .chat-count,
  .chat-row time {
    text-align: left;
  }

  .message {
    max-width: 92%;
  }
}
""",
    )


def write_manifest(output_dir, title):
    manifest = {
        "name": title,
        "short_name": "WhatsApp Archive",
        "start_url": "index.html",
        "display": "standalone",
        "background_color": "#f5f3ee",
        "theme_color": "#f5f3ee",
    }
    write_text(
        output_dir / "manifest.webmanifest",
        json.dumps(manifest, indent=2),
    )


def main():
    args = parse_args()
    source_root = args.input.resolve()
    output_dir = args.output.resolve()
    db_path = source_root / "ChatStorage.sqlite"

    if not db_path.exists():
        raise SystemExit(f"Missing database: {db_path}")

    output_dir.mkdir(parents=True, exist_ok=True)
    write_css(output_dir)
    write_manifest(output_dir, args.title)

    with connect_database(db_path) as conn:
        chats = query_chats(conn, args.limit_chats)
        filenames = [
            f"{index:04d}-{safe_name(chat_title(chat))}-{chat['Z_PK']}.html"
            for index, chat in enumerate(chats, start=1)
        ]
        write_index(output_dir, args.title, chats, filenames)
        for chat, filename in zip(chats, filenames):
            write_chat_page(conn, source_root, output_dir, chat, filename, args.copy_media)

    print(f"Exported {len(chats)} chats to {output_dir / 'index.html'}")


if __name__ == "__main__":
    raise SystemExit(main())
