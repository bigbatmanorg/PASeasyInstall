# Checks every relative link and image of README.md and the site pages: the file must exist, and an anchor must
# be a heading (or an explicit { #id }) of the target page. Also lists commands named in the docs that do not exist.
# Usage: check_links.py <repository root>
import os, re, sys, glob
root = sys.argv[1]

def slug(text):
    text = re.sub(r'`', '', text).strip().lower()
    text = re.sub(r'[^\w\- ]', '', text)
    return re.sub(r'[ ]+', '-', text).strip('-')

def anchors(path):
    found = set()
    for line in open(path, encoding='utf-8'):
        m = re.match(r'^#{1,6}\s+(.*?)\s*$', line)
        if m:
            title = m.group(1)
            explicit = re.search(r'\{\s*#([\w-]+)\s*\}\s*$', title)
            if explicit:
                found.add(explicit.group(1))
                title = title[:explicit.start()]
            found.add(slug(title))
    return found

pages = [os.path.join(root, 'README.md')] + glob.glob(os.path.join(root, 'site-src', '**', '*.md'), recursive=True)
problems = 0
for page in pages:
    text = open(page, encoding='utf-8').read()
    text_nocode = re.sub(r'```.*?```', '', text, flags=re.S)
    for m in re.finditer(r'!?\[[^\]]*\]\(([^)\s]+)\)', text_nocode):
        target = m.group(1)
        if re.match(r'^(https?:|mailto:)', target):
            continue
        path, _, anchor = target.partition('#')
        dest = page if not path else os.path.normpath(os.path.join(os.path.dirname(page), path))
        if not os.path.exists(dest):
            print('MISSING FILE  %s -> %s' % (os.path.relpath(page, root), target))
            problems += 1
            continue
        if anchor and dest.endswith('.md') and anchor not in anchors(dest):
            print('MISSING ANCHOR %s -> %s' % (os.path.relpath(page, root), target))
            problems += 1

commands = {os.path.basename(f)[:-4] for f in glob.glob(os.path.join(root, 'PASeasyInstall', 'Public', '*.ps1'))}
verbs = 'Install|Get|New|Test|Export|Import|Resume|Stop|Wait|Start'
for page in pages:
    text = open(page, encoding='utf-8').read()
    for name in sorted(set(re.findall(r'\b((?:%s)-PAS\w+)' % verbs, text))):
        if name not in commands:
            print('UNKNOWN COMMAND %s in %s' % (name, os.path.relpath(page, root)))
            problems += 1

used = set()
for page in pages:
    for m in re.finditer(r'\(([^)\s]+\.png)\)', open(page, encoding='utf-8').read()):
        used.add(os.path.normpath(os.path.join(os.path.dirname(page), m.group(1))))
for folder in ('site-src/assets',):
    for f in glob.glob(os.path.join(root, folder, '**', '*.png'), recursive=True):
        if os.path.normpath(f) not in used:
            print('UNUSED IMAGE  %s' % os.path.relpath(f, root))
print('problems: %d' % problems)
