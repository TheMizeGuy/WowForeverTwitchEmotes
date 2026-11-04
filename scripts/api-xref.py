"""Cross-reference every global the runtime modules touch against each client's shipped Blizzard UI source.

Usage: python3 -I scripts/api-xref.py TwitchEmotes <wowui-root> <out.json>
<wowui-root> holds one shallow clone of github.com/Gethe/wow-ui-source per branch, named after the branch
(live, classic, classic_anniversary, classic_era, forever); each clone's version.txt names the build it mirrors.
Prints one row per symbol with where each client defines it, flagging MISSING, and writes the full map to out.json."""
import json, re, subprocess, sys
from pathlib import Path

addon = Path(sys.argv[1]); wowui = Path(sys.argv[2]); out = Path(sys.argv[3])
FLAVORS = ['live', 'classic', 'classic_anniversary', 'classic_era', 'forever']
MODULES = ['Core.lua', 'Runtime.lua', 'Text.lua', 'Animation.lua', 'Completion.lua', 'UI.lua']
LUA_BUILTINS = set('assert error ipairs pairs next select setmetatable getmetatable tostring tonumber type unpack rawget rawset rawequal pcall xpcall print math string table coroutine os io loadstring load dofile require _G'.split())

# 1. Globals the addon reads/writes (bytecode is authoritative; regex adds namespace members and _G[...] lookups).
globals_used, members, templates, events, callbacks = {}, {}, set(), set(), set()
for mod in MODULES:
    src = (addon / mod).read_text()
    bl = subprocess.run(['luajit', '-bl', str(addon / mod)], capture_output=True, text=True, check=True).stdout
    for line in bl.splitlines():
        m = re.search(r'\b(GGET|GSET)\s+\d+\s+\d+\s*;\s*"([^"]+)"', line)
        if m and m.group(2) not in LUA_BUILTINS:
            globals_used.setdefault(m.group(2), set()).add(mod)
    for m in re.finditer(r'_G\.([A-Za-z_][A-Za-z0-9_]*)', src):
        globals_used.setdefault(m.group(1), set()).add(mod)
    for m in re.finditer(r'_G\[\s*"([^"]+)"\s*\]', src):
        globals_used.setdefault(m.group(1), set()).add(mod)
    for m in re.finditer(r'\b(C_[A-Za-z]+|ChatFrameUtil|Enum|Settings|EventRegistry|GameTooltip|UIParent|Minimap|SlashCmdList|SOUNDKIT|CreateSettingsListSectionHeaderInitializer|MinimapCluster)\.([A-Za-z_][A-Za-z0-9_]*)', src):
        members.setdefault(m.group(1), set()).add(m.group(2))
    for m in re.finditer(r'CreateFrame\(\s*"[A-Za-z]+"\s*,\s*[^,]*,\s*[^,]*,\s*"([^"]+)"', src):
        for t in m.group(1).split(','): templates.add(t.strip())
    for m in re.finditer(r'RegisterEvent\(\s*"([A-Z_0-9]+)"', src): events.add(m.group(1))
    for m in re.finditer(r'(?:AddMessageEventFilter|addFilter)\(\s*"?([A-Z_0-9]+)', src): events.add(m.group(1))
    for m in re.finditer(r'RegisterCallback\(\s*"([^"]+)"', src): callbacks.add(m.group(1))
for ev in re.findall(r'CHAT_MSG_[A-Z_]+', (addon / 'Core.lua').read_text()): events.add(ev)

# 2. Per-flavor definition index.
def index(flavor):
    root = wowui / flavor / 'Interface' / 'AddOns'
    defs = {}          # global name -> first file
    api_funcs = {}     # "Namespace.Func" -> file
    api_events = set()
    enums = {}
    xml_names = {}
    triggers = set()
    for path in root.rglob('*.lua'):
        rel = str(path.relative_to(root))
        try: text = path.read_text(errors='replace')
        except Exception: continue
        if 'Blizzard_APIDocumentationGenerated' in rel:
            ns = re.search(r'Namespace\s*=\s*"([^"]+)"', text)
            nsname = ns.group(1) if ns else None
            for m in re.finditer(r'Name\s*=\s*"([^"]+)"\s*,\s*Type\s*=\s*"(Function|Event|Enumeration|Structure|Constants)"', text):
                name, kind = m.group(1), m.group(2)
                if kind == 'Function':
                    api_funcs[(nsname + '.' + name) if nsname else name] = rel
                elif kind == 'Enumeration': enums[name] = rel
            for m in re.finditer(r'LiteralName\s*=\s*"([^"]+)"', text): api_events.add(m.group(1))
            continue
        for m in re.finditer(r'^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\s*[\(:.]', text, re.M):
            defs.setdefault(m.group(1), rel)
        for m in re.finditer(r'^([A-Z][A-Za-z0-9_]*)\s*=', text, re.M):
            defs.setdefault(m.group(1), rel)
        for m in re.finditer(r'EventRegistry:TriggerEvent\(\s*"([^"]+)"', text): triggers.add(m.group(1))
        for m in re.finditer(r'RegisterCallback\(\s*"([^"]+)"', text): triggers.add(m.group(1))
    for path in root.rglob('*.xml'):
        rel = str(path.relative_to(root))
        try: text = path.read_text(errors='replace')
        except Exception: continue
        for m in re.finditer(r'\bname="([A-Za-z_][A-Za-z0-9_]*)"', text):
            xml_names.setdefault(m.group(1), rel)
    return dict(defs=defs, api_funcs=api_funcs, api_events=api_events, enums=enums, xml=xml_names, triggers=triggers)

idx = {f: index(f) for f in FLAVORS}

# Core C API functions never listed in the generated docs: probe the branch's own Lua for a call site as a proxy.
def c_api_used_in_branch(flavor, name):
    root = wowui / flavor / 'Interface' / 'AddOns'
    r = subprocess.run(['grep', '-rl', '--include=*.lua', '-E', r'\b' + re.escape(name) + r'\s*\(', str(root)], capture_output=True, text=True)
    files = [l for l in r.stdout.splitlines() if 'APIDocumentation' not in l]
    return files[0].replace(str(root) + '/', '') if files else None

def where(flavor, name):
    i = idx[flavor]
    if name in i['defs']: return 'lua:' + i['defs'][name]
    if name in i['xml']: return 'xml:' + i['xml'][name]
    if name in i['api_funcs']: return 'api:' + i['api_funcs'][name]
    if name in i['enums']: return 'enum:' + i['enums'][name]
    if name.startswith('C_') and any(k.startswith(name + '.') for k in i['api_funcs']): return 'api-namespace'
    c = c_api_used_in_branch(flavor, name)
    return ('c-api-used:' + c) if c else 'MISSING'

report = {'globals': {}, 'members': {}, 'templates': {}, 'events': {}, 'callbacks': {}}
for name in sorted(globals_used):
    report['globals'][name] = {'modules': sorted(globals_used[name]), **{f: where(f, name) for f in FLAVORS}}
for ns in sorted(members):
    for mem in sorted(members[ns]):
        key = ns + '.' + mem
        row = {}
        for f in FLAVORS:
            i = idx[f]
            if key in i['api_funcs']: row[f] = 'api:' + i['api_funcs'][key]
            elif ns == 'Enum' and mem in i['enums']: row[f] = 'enum:' + i['enums'][mem]
            else:
                r = subprocess.run(['grep', '-rl', '--include=*.lua', '-F', key, str(wowui / f / 'Interface' / 'AddOns')], capture_output=True, text=True)
                files = [l for l in r.stdout.splitlines()]
                row[f] = ('used:' + files[0].split('/Interface/AddOns/')[1]) if files else 'MISSING'
        report['members'][key] = row
for t in sorted(templates):
    report['templates'][t] = {f: ('xml:' + idx[f]['xml'][t]) if t in idx[f]['xml'] else ('lua:' + idx[f]['defs'][t]) if t in idx[f]['defs'] else 'MISSING' for f in FLAVORS}
for ev in sorted(events):
    report['events'][ev] = {f: ('api-event' if ev in idx[f]['api_events'] else ('used:' + c) if (c := c_api_used_in_branch(f, ev) or (subprocess.run(['grep', '-rl', '--include=*.lua', '-F', '"' + ev + '"', str(wowui / f / 'Interface' / 'AddOns')], capture_output=True, text=True).stdout.splitlines() or [None])[0]) else 'MISSING') for f in FLAVORS}
for cb in sorted(callbacks):
    report['callbacks'][cb] = {f: ('triggered' if cb in idx[f]['triggers'] else 'MISSING') for f in FLAVORS}

out.write_text(json.dumps(report, indent=1))
def short(v):
    if v == 'MISSING': return 'MISSING'
    return v.split(':', 1)[0] if ':' in v else v
for section in ['globals', 'members', 'templates', 'events', 'callbacks']:
    print(f'=== {section}')
    for name, row in report[section].items():
        cells = [short(row[f]) for f in FLAVORS]
        flag = ' <-- ' if any(c == 'MISSING' for c in cells) else '     '
        print(f'{flag}{name:48s} ' + ' '.join(f'{c:14s}' for c in cells))
print('flavor order:', FLAVORS)
