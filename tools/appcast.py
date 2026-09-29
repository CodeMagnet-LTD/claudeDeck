"""Writes or updates the Sparkle appcast (used by tools/update-appcast.sh).

Environment: VERSION, BUILD, TAG, REPO, SIGNATURE (sign_update output: sparkle:edSignature="…"
length="…"), NOTES (Markdown release notes). The newest item goes first; an item for the same
build is replaced.
"""
import html
import os
import re
import sys
from email.utils import formatdate

EMPTY = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ClaudeDeck</title>
    <link>https://github.com/{repo}</link>
    <description>ClaudeDeck updates</description>
    <language>en</language>
  </channel>
</rss>
"""


def inline(text: str) -> str:
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"(?<!\w)\*([^*]+)\*(?!\w)", r"<i>\1</i>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2">\1</a>', text)
    return text


def markdown(md: str) -> str:
    """Just enough Markdown for release notes: headings, bullets, paragraphs, inline marks."""
    out, para, in_list = [], [], False

    def flush():
        nonlocal para
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para = []

    for raw in md.splitlines():
        line = raw.rstrip()
        if re.match(r"^\s*!\[", line):  # images don't belong in the update window
            continue
        if m := re.match(r"^(#{1,6})\s+(.*)", line):
            flush()
            if in_list:
                out.append("</ul>"); in_list = False
            level = min(len(m.group(1)) + 1, 4)
            out.append(f"<h{level}>{inline(m.group(2))}</h{level}>")
        elif m := re.match(r"^\s*[-*]\s+(.*)", line):
            flush()
            if not in_list:
                out.append("<ul>"); in_list = True
            out.append("<li>" + inline(m.group(1)) + "</li>")
        elif not line.strip():
            flush()
            if in_list:
                out.append("</ul>"); in_list = False
        else:
            para.append(line.strip())
    flush()
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main(path: str) -> None:
    env = os.environ
    version, build, tag, repo = env["VERSION"], env["BUILD"], env["TAG"], env["REPO"]
    signature = env["SIGNATURE"].strip()
    if not re.fullmatch(r'sparkle:edSignature="[^"]+" length="\d+"', signature):
        sys.exit(f"Unexpected sign_update output: {signature!r}")
    notes = markdown(env.get("NOTES", ""))
    url = f"https://github.com/{repo}/releases/download/{tag}/ClaudeDeck-{version}.dmg"

    item = f"""    <item>
      <title>ClaudeDeck {html.escape(version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/{repo}/releases/tag/{tag}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{notes.replace("]]>", "]]&gt;")}]]></description>
      <enclosure url="{url}" {signature} type="application/octet-stream"/>
    </item>
"""
    xml = open(path, encoding="utf-8").read() if os.path.exists(path) else EMPTY.format(repo=repo)
    # Drop an existing item for this build, then insert the new one first.
    xml = re.sub(r"    <item>\n(?:(?!</item>).)*?<sparkle:version>" + re.escape(build)
                 + r"</sparkle:version>.*?</item>\n", "", xml, flags=re.S)
    anchor = "    <language>en</language>\n"
    if anchor not in xml:
        sys.exit("appcast.xml has an unexpected layout")
    xml = xml.replace(anchor, anchor + item, 1)
    open(path, "w", encoding="utf-8").write(xml)


if __name__ == "__main__":
    main(sys.argv[1])
