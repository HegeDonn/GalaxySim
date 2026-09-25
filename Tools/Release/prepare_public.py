"""Create an audited, history-free source repository. Never pushes anything.

Run from any directory: python3 Tools/Release/prepare_public.py
Optional destination argument must not already exist.
Private case-insensitive search terms come from the ignored .privacy-terms file.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
DEST = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'public-release/GalaxySim'
FILES = ['AGENTS.md', '.gitignore', 'Package.swift', 'README.md', 'rebuild-app.sh',
         'PUBLICATION.md', 'TECHNICAL_GUIDE.md', 'PERFORMANCE_HANDOFF.md', 'STAR_EXPLORER_HANDOFF.md',
         'PLANET_PHOTOGRAPHY_DESIGN.md', 'LANDING_GAME_PLAN.md']
TREES = ['Sources', 'Tools', 'Packaging']
SUFFIXES = {'.swift', '.metal', '.mesh', '.json', '.py', '.plist'}
terms_file = ROOT / '.privacy-terms'
terms = [s.strip().lower() for s in terms_file.read_text().splitlines() if s.strip()] if terms_file.exists() else []
patterns = [rb'/' + rb'Users/' + rb'[^/\s]+/', rb'/' + rb'home/' + rb'[^/\s]+/', rb'/var/' + rb'folders/',
            rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
            rb'gh[pousr]_[A-Za-z0-9]{20,}', rb'github_pat_[A-Za-z0-9_]{20,}',
            rb'AKIA[0-9A-Z]{16}']
# Keep the generic scanner's literal path patterns from matching its own source.
checks = [re.compile(p, re.I) for p in patterns]
paths = [ROOT / f for f in FILES]
for tree in TREES:
    paths += [p for p in (ROOT / tree).rglob('*') if p.is_file() and p.suffix in SUFFIXES and '__pycache__' not in p.parts]
for name in ['LICENSE', 'NOTICE']:
    if (ROOT / name).exists(): paths.append(ROOT / name)
# Public gallery: only these reviewed, metadata-stripped screenshots.
paths += [ROOT / 'Docs/images' / (name + '.png') for name in
          ['create-galaxies', 'fly-through-galaxies', 'meet-a-star', 'photograph-the-sky']]
errors = []
for path in paths:
    if path.is_symlink():
        errors.append(f'{path.relative_to(ROOT)}: symbolic link requires review')
        continue
    data = path.read_bytes()
    searchable = data.lower() + str(path.relative_to(ROOT)).lower().encode()
    if any(t.encode() in searchable or t.encode('utf-16-le') in data.lower() for t in terms):
        errors.append(f'{path.relative_to(ROOT)}: private term detected')
    if any(p.search(data) for p in checks):
        errors.append(f'{path.relative_to(ROOT)}: local path or credential pattern detected')
if errors:
    sys.exit('\n'.join(errors))
if DEST.exists(): sys.exit('Destination already exists; choose a new directory. Nothing overwritten.')
DEST.mkdir(parents=True)
for path in paths:
    target = DEST / path.relative_to(ROOT)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(path, target)
    target.chmod(0o755 if path.name == 'rebuild-app.sh' else 0o644)
# Do not inherit identity, signing, hooks, templates, or alternate Git directories.
env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
           GIT_AUTHOR_NAME='GalaxySim Contributors', GIT_COMMITTER_NAME='GalaxySim Contributors',
           GIT_AUTHOR_EMAIL='contributors@example.invalid', GIT_COMMITTER_EMAIL='contributors@example.invalid')
def git(*args):
    subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgSign=false', *args], cwd=DEST, env=env, check=True)
git('init', '--template=', '--initial-branch=main')
git('config', 'user.name', 'GalaxySim Contributors')
git('config', 'user.email', 'contributors@example.invalid')
git('add', '.')
git('commit', '-m', 'Initial public source snapshot')
print(f'Prepared {len(paths)} files in {DEST}. No remote configured; nothing published.')
if not terms: print('NOTE: no private search terms supplied; only generic checks ran.')
if not (DEST / 'LICENSE').exists(): print('PENDING: choose a license before public release.')
