#!/usr/bin/env python3
"""Generate README.html and INSTALL.html (and the GitHub Pages index.html redirect) from
README.md and INSTALL.md.

The fleet's page generator (LMS-Listening-History tools/make_readme_html.py), adapted for
LyrionPlay. It has the same look: a hero with title, tagline, badges and buttons, then sections
with a feature-card grid. The colours are Lyrion's green.

- **Zero dependencies.** A focused Markdown converter for the subset the two files use: headings,
  paragraphs, bold/italic/code/links, GFM tables, fenced code, blockquotes, and lists. List items
  may wrap over several lines and may hold code blocks or paragraphs; numbered steps keep their
  numbers across them.
- **Features.** The "Features" table renders as cards; every other table is a styled <table>.
- **The version badge** is read live from VERSION, the one place the version is set (build.sh
  reads it too), so a regen always shows the current release.
- **Screenshots.** An `<img src="docs/images/x.png" width="N" alt="...">` tag (exactly that shape,
  which GitHub shows at width N too) is kept as an image with its relative src, so the page shows
  the file beside it. A paragraph of only such tags is a row of screenshots. Any other HTML is
  escaped, as before. Keep images out of INSTALL.md: INSTALL.html ships in the zip without them.
- **Links.** A link to INSTALL.md or README.md becomes the .html page. Any other relative link
  (engine/UPSTREAM.md, LICENSE) goes to the file on GitHub, so the pages work from GitHub Pages,
  and from the copy of INSTALL.html in the release zip.

Run from anywhere:  python3 tools/make_readme_html.py
scripts/build.sh --release runs it, and ships INSTALL.html in the zip.
"""

import os
import re

GITHUB_URL = "https://github.com/SimonArnold002/LyrionPlay"
RELEASES_URL = GITHUB_URL + "/releases/latest"
STATIC_BADGES = ["Apple Silicon", "macOS 14+", "Bit-perfect", "DSD over DoP"]

# per page: source, output, and the hero's buttons (absolute where the page also ships offline)
PAGES = [
    ("README.md", "README.html", [("Download latest", RELEASES_URL, "primary"),
                                  ("Installation", "INSTALL.html", "ghost")]),
    ("INSTALL.md", "INSTALL.html", [("Download latest", RELEASES_URL, "primary"),
                                    ("LyrionPlay on GitHub", GITHUB_URL, "ghost")]),
]


def read_version(root):
    """The current version, from VERSION (the single source of truth)."""
    try:
        with open(os.path.join(root, "VERSION"), encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return None


CSS = """
  :root {
    --brand: #589e81;
    --brand-dark: #2c5444;
    --accent: #e3fdc4;
    --accent-ink: #1f3b30;
    --ink: #1c1c28;
    --muted: #5b5b6b;
    --line: #e4e4ec;
    --bg: #f7f7fa;
    --card: #ffffff;
    --code-bg: #eef3f0;
  }
  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    color: var(--ink);
    background: var(--bg);
    line-height: 1.6;
    -webkit-font-smoothing: antialiased;
  }
  a { color: #3b7d62; text-decoration: none; }
  a:hover { text-decoration: underline; }

  header.hero {
    background: linear-gradient(135deg, var(--brand) 0%, var(--brand-dark) 100%);
    color: #fff;
    padding: 56px 24px 48px;
    text-align: center;
  }
  header.hero h1 { margin: 0 0 10px; font-size: 2.1rem; letter-spacing: -0.01em; }
  header.hero .logo { width: 96px; height: auto; display: block; margin: 0 auto 14px; }
  header.hero p.tagline { margin: 0 auto; max-width: 660px; color: #e6f3ec; font-size: 1.08rem; }
  header.hero p.tagline a { color: var(--accent); }
  .badges { margin-top: 22px; display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; }
  .badge {
    display: inline-block; padding: 5px 13px; border-radius: 999px;
    font-size: 0.82rem; font-weight: 600;
    background: rgba(255,255,255,0.14); color: #fff; border: 1px solid rgba(255,255,255,0.26);
  }
  .badge.accent { background: var(--accent); border-color: var(--accent); color: var(--accent-ink); }
  .hero-actions { margin-top: 26px; display: flex; gap: 12px; justify-content: center; flex-wrap: wrap; }
  .btn { display: inline-block; padding: 11px 22px; border-radius: 8px; font-weight: 600; font-size: 0.95rem; }
  .btn-primary { background: var(--accent); color: var(--accent-ink); }
  .btn-primary:hover { text-decoration: none; filter: brightness(1.04); }
  .btn-ghost { background: rgba(255,255,255,0.12); color: #fff; border: 1px solid rgba(255,255,255,0.32); }
  .btn-ghost:hover { text-decoration: none; background: rgba(255,255,255,0.20); }

  main { max-width: 880px; margin: 0 auto; padding: 8px 24px 64px; }
  section { margin-top: 44px; }
  h2 {
    font-size: 1.45rem; margin: 0 0 6px; padding-bottom: 8px;
    border-bottom: 3px solid var(--brand); display: inline-block;
  }
  h3 { font-size: 1.12rem; margin: 26px 0 6px; color: var(--brand-dark); }
  p { margin: 10px 0; }
  ul, ol { padding-left: 24px; }
  li { margin: 5px 0; }
  li > ul, li > ol { margin-top: 5px; }
  li > p { margin: 8px 0; }

  table {
    width: 100%; border-collapse: collapse; margin: 14px 0;
    background: var(--card); border-radius: 10px; overflow: hidden;
    box-shadow: 0 1px 3px rgba(0,0,0,0.06); font-size: 0.95rem;
  }
  th, td { text-align: left; padding: 11px 14px; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { background: var(--brand-dark); color: #fff; font-weight: 600; }
  tr:last-child td { border-bottom: none; }
  tr:nth-child(even) td { background: #fafcfb; }
  td strong { color: var(--brand-dark); }

  code {
    background: var(--code-bg); padding: 2px 6px; border-radius: 5px;
    font-family: "SF Mono", SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.88em;
  }
  .shots { display: flex; flex-wrap: wrap; gap: 16px; align-items: flex-start; }
  .shots img { max-width: 100%; height: auto; }
  pre {
    background: var(--brand-dark); color: #f1fbf5; padding: 16px 18px;
    border-radius: 10px; overflow-x: auto; font-size: 0.9rem;
  }
  pre code { background: none; padding: 0; color: inherit; }

  blockquote {
    margin: 14px 0; padding: 12px 18px; background: #f1f9f4;
    border-left: 4px solid var(--brand); border-radius: 0 8px 8px 0; color: var(--muted);
  }
  blockquote p { margin: 0; }

  .feature-cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 14px; margin-top: 16px; }
  .card {
    background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 16px 18px;
    box-shadow: 0 1px 3px rgba(0,0,0,0.05);
  }
  .card h4 { margin: 0 0 6px; font-size: 1rem; color: var(--brand-dark); }
  .card p { margin: 0; font-size: 0.9rem; color: var(--muted); }

  footer {
    text-align: center; color: var(--muted); font-size: 0.88rem;
    padding: 32px 24px 48px; border-top: 1px solid var(--line); margin-top: 48px;
  }
  @media (max-width: 600px) {
    header.hero h1 { font-size: 1.6rem; }
    main { padding: 8px 16px 48px; }
  }
"""


def slug(text):
    s = re.sub(r"<[^>]+>", "", text).lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s


def link_target(url):
    """Sibling guides become their pages; other relative links go to the file on GitHub."""
    if re.match(r"^[a-z]+:|^#", url):
        return url
    if url in ("INSTALL.md", "README.md"):
        return url[:-3] + ".html"
    return "%s/blob/main/%s" % (GITHUB_URL, url)


IMG = re.compile(r'<img src="([\w./-]+\.(?:png|jpg|gif))" width="(\d+)" alt="([^"<>&]*)">')


def only_images(text):
    """True when a paragraph is nothing but screenshot tags."""
    return bool(text.strip()) and not IMG.sub("", text).strip()


def inline(text):
    """Convert inline Markdown to HTML (code spans and screenshot tags protected from other rules)."""
    codes = []
    imgs = []

    def stash(m):
        codes.append(m.group(1))
        return "\x00%d\x00" % (len(codes) - 1)

    def stash_img(m):
        imgs.append('<img src="%s" width="%s" alt="%s" loading="lazy">' % m.groups())
        return "\x01%d\x01" % (len(imgs) - 1)

    text = IMG.sub(stash_img, text)
    text = re.sub(r"`([^`]+)`", stash, text)
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", lambda m: '<a href="%s">%s</a>' % (link_target(m.group(2)), m.group(1)), text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)", r"<em>\1</em>", text)

    def unstash(m):
        c = codes[int(m.group(1))]
        c = c.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        return "<code>%s</code>" % c

    text = re.sub(r"\x00(\d+)\x00", unstash, text)
    return re.sub(r"\x01(\d+)\x01", lambda m: imgs[int(m.group(1))], text)


def parse_table(lines, i):
    """Parse a GFM table starting at line i. Returns (header, rows, next_i)."""
    def cells(row):
        row = row.strip()
        if row.startswith("|"):
            row = row[1:]
        if row.endswith("|"):
            row = row[:-1]
        return [c.strip() for c in row.split("|")]

    header = cells(lines[i])
    i += 2  # skip header + separator
    rows = []
    while i < len(lines) and "|" in lines[i] and lines[i].strip():
        rows.append(cells(lines[i]))
        i += 1
    return header, rows, i


def render_table(header, rows):
    out = ["<table>", "<thead><tr>"]
    out += ["<th>%s</th>" % inline(h) for h in header]
    out.append("</tr></thead>")
    out.append("<tbody>")
    for r in rows:
        out.append("<tr>" + "".join("<td>%s</td>" % inline(c) for c in r) + "</tr>")
    out.append("</tbody></table>")
    return "\n".join(out)


def render_cards(rows):
    out = ['<div class="feature-cards">']
    for r in rows:
        feat = re.sub(r"\*\*", "", r[0]).strip()
        gives = r[1] if len(r) > 1 else ""
        out.append('<div class="card"><h4>%s</h4><p>%s</p></div>' % (inline(feat), inline(gives)))
    out.append("</div>")
    return "\n".join(out)


ITEM = re.compile(r"^(\s*)([-*]|\d+\.)\s+(.*)$")
TABLE_SEP = re.compile(r"^\s*\|?[\s:|-]+\|?\s*$")


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def render_list(lines, i):
    """One list (and its siblings): each item's lines, dedented, are converted recursively, so an
    item can wrap, or hold paragraphs and code. Returns (html, next_i)."""
    first = ITEM.match(lines[i])
    base = len(first.group(1))
    ordered = first.group(2)[0].isdigit()
    tag = "ol" if ordered else "ul"
    start = int(first.group(2)[:-1]) if ordered else 1
    html = ['<ol start="%d">' % start if ordered and start != 1 else "<%s>" % tag]

    while i < len(lines):
        if lines[i].strip() == "":
            # blank lines between two items of this list keep it one list
            j = i
            while j < len(lines) and lines[j].strip() == "":
                j += 1
            nxt = ITEM.match(lines[j]) if j < len(lines) else None
            if not nxt or len(nxt.group(1)) != base or nxt.group(2)[0].isdigit() != ordered:
                break
            i = j
        m = ITEM.match(lines[i])
        if not m or len(m.group(1)) != base or m.group(2)[0].isdigit() != ordered:
            break
        content = len(m.group(1)) + len(m.group(2)) + 1  # where the item's text starts
        item = [m.group(3)]
        i += 1
        while i < len(lines):
            line = lines[i]
            if line.strip() == "":
                # a blank line continues the item only if indented content follows
                j = i
                while j < len(lines) and lines[j].strip() == "":
                    j += 1
                if j < len(lines) and indent_of(lines[j]) >= content:
                    item.extend([""] * (j - i))
                    i = j
                    continue
                break
            if indent_of(line) >= content:
                item.append(line[content:])
            elif ITEM.match(line) or indent_of(line) <= base:
                break
            else:
                item.append(line.strip())  # a wrapped line with a shorter indent
            i += 1
        body = convert_blocks(item)
        # a single short paragraph renders tight, without <p>
        if body.startswith("<p>") and body.count("<p>") == 1 and body.endswith("</p>"):
            body = body[3:-4]
        html.append("<li>%s</li>" % body)

    html.append("</%s>" % tag)
    return "\n".join(html), i


def convert_blocks(lines, sections=False):
    """Block-level Markdown. With sections=True, each '## ' opens a <section>."""
    out = []
    para = []
    section_open = False
    cur_h2 = ""
    i = 0

    def para_flush():
        if para:
            text = " ".join(para)
            out.append(('<p class="shots">%s</p>' if only_images(text) else "<p>%s</p>") % inline(text))
            para.clear()

    while i < len(lines):
        line = lines[i]
        s = line.strip()

        if sections and s.startswith("## "):
            para_flush()
            if section_open:
                out.append("</section>")
            cur_h2 = s[3:].strip()
            out.append('<section id="%s">' % slug(cur_h2))
            out.append("<h2>%s</h2>" % inline(cur_h2))
            section_open = True
            i += 1
            continue
        if s.startswith("### "):
            para_flush()
            out.append('<h3 id="%s">%s</h3>' % (slug(s[4:]), inline(s[4:].strip())))
            i += 1
            continue
        if s == "" or s == "---":
            para_flush()
            i += 1
            continue
        if s.startswith("```"):
            para_flush()
            i += 1
            code = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1  # closing fence
            pad = min((indent_of(c) for c in code if c.strip()), default=0)
            esc = "\n".join(c[pad:] for c in code).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            out.append("<pre><code>%s</code></pre>" % esc)
            continue
        if s.startswith(">"):
            para_flush()
            quote = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                quote.append(lines[i].strip()[1:].strip())
                i += 1
            out.append("<blockquote><p>%s</p></blockquote>" % inline(" ".join(quote)))
            continue
        if "|" in line and i + 1 < len(lines) and TABLE_SEP.match(lines[i + 1]) and "-" in lines[i + 1]:
            para_flush()
            header, rows, i = parse_table(lines, i)
            out.append(render_cards(rows) if cur_h2.lower().startswith("features") else render_table(header, rows))
            continue
        if ITEM.match(line):
            para_flush()
            html, i = render_list(lines, i)
            out.append(html)
            continue
        para.append(s)
        i += 1

    para_flush()
    if section_open:
        out.append("</section>")
    return "\n".join(out)


def build(md, version, buttons, logo):
    lines = md.splitlines()
    title = next((l[2:].strip() for l in lines if l.startswith("# ")), "LyrionPlay")

    # Tagline = the first paragraph after the title, before the first '## '.
    tagline = []
    started = False
    for l in lines:
        if l.startswith("# "):
            started = True
            continue
        if not started:
            continue
        if l.startswith("## ") or (tagline and not l.strip()):
            break
        if l.strip():
            tagline.append(l.strip())

    body_start = next((idx for idx, l in enumerate(lines) if l.startswith("## ")), len(lines))
    body = convert_blocks(lines[body_start:], sections=True)
    # anything between the tagline and the first '## ' opens the page, rather than being dropped
    title_at = next((idx for idx, l in enumerate(lines) if l.startswith("# ")), -1)
    after = title_at + 1
    while after < body_start and not lines[after].strip():
        after += 1
    while after < body_start and lines[after].strip():
        after += 1  # past the tagline paragraph
    intro = convert_blocks(lines[after:body_start]).strip()
    if intro:
        body = '<section class="intro">\n%s\n</section>\n%s' % (intro, body)

    badge_labels = (["v%s" % version] if version else []) + STATIC_BADGES
    badges = "\n".join(
        '    <span class="badge%s">%s</span>' % (" accent" if n == 0 and version else "", b)
        for n, b in enumerate(badge_labels)
    )
    actions = "\n".join(
        '    <a class="btn btn-%s" href="%s">%s</a>' % (kind, href, label) for label, href, kind in buttons
    )

    return """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{plain_title}</title>
<style>{css}</style>
</head>
<body>

<header class="hero">
  {logo}
  <h1>{title}</h1>
  <p class="tagline">{tagline}</p>
  <div class="badges">
{badges}
  </div>
  <div class="hero-actions">
{actions}
  </div>
</header>

<main>
{body}
</main>

<footer>
  <p>LyrionPlay — a player for Lyrion Music Server, built on squeezelite ·
  <a href="{gh}">View on GitHub</a></p>
</footer>

</body>
</html>
""".format(
        plain_title=re.sub(r"<[^>]+>", "", inline(title)),
        title=inline(title),
        css=CSS,
        logo=logo,
        tagline=inline(" ".join(tagline)),
        badges=badges,
        actions=actions,
        body=body,
        gh=GITHUB_URL,
    )


def hero_logo(root):
    """The app's glyph, inline and white, so the page needs no image file."""
    try:
        with open(os.path.join(root, "app", "Resources", "LyrionPlay.svg"), encoding="utf-8") as f:
            svg = f.read()
    except OSError:
        return ""
    svg = re.sub(r"<\?xml[^>]*\?>|<!--.*?-->", "", svg, flags=re.S).strip()
    return svg.replace("<svg ", '<svg class="logo" fill="#fff" aria-hidden="true" ', 1)


INDEX_REDIRECT = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0; url=README.html">
<link rel="canonical" href="README.html">
<title>LyrionPlay</title>
</head>
<body>
<p>Redirecting to <a href="README.html">the LyrionPlay page</a>…</p>
</body>
</html>
"""


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    version = read_version(root)
    logo = hero_logo(root)
    for src, dst, buttons in PAGES:
        with open(os.path.join(root, src), encoding="utf-8") as f:
            html = build(f.read(), version, buttons, logo)
        with open(os.path.join(root, dst), "w", encoding="utf-8") as f:
            f.write(html)
        print("Wrote %s (%d bytes)" % (dst, len(html)))
    with open(os.path.join(root, "index.html"), "w", encoding="utf-8") as f:
        f.write(INDEX_REDIRECT)
    print("Wrote index.html (redirect to README.html)")


if __name__ == "__main__":
    main()
