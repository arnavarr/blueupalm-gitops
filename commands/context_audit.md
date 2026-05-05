Ejecuta una auditoría completa del contexto del entorno Gemini CLI.

## Qué verifica

1. **Freshness de KIs** — Ejecuta `~/.gemini/repo-template/ki-refresh.sh --ttl 7` para detectar Knowledge Items stale
2. **Completitud de GEMINI.md** — Para cada repo en `projects.json`, verifica que GEMINI.md existe y tiene >20 líneas (no template)
3. **Coherencia de configuración** — Verifica que cada repo tiene `.gemini/settings.json`, `.geminiignore` y `commands/`
4. **Salud de extensiones** — Ejecuta el healthcheck de extensiones
5. **Estado del brain** — Reporta tamaño y número de conversaciones en `~/.gemini/antigravity/brain/`
6. **Cross-repo map** — Verifica que el KI `cross-repo-map` está actualizado

## Ejecución

```bash
# 1. KI Freshness
echo "━━━ KI Freshness ━━━"
bash ~/.gemini/repo-template/ki-refresh.sh --ttl 7

# 2. GEMINI.md coverage
echo "━━━ GEMINI.md Coverage ━━━"
python3 -c "
import json, os
with open(os.path.expanduser('~/.gemini/projects.json')) as f:
    projects = json.load(f)['projects']
for path, name in sorted(projects.items()):
    if not os.path.isdir(path) or path in ['/', os.path.expanduser('~')]:
        continue
    gmd = os.path.join(path, 'GEMINI.md')
    if os.path.isfile(gmd):
        lines = len(open(gmd).readlines())
        status = '✅' if lines > 20 else '⚠️ template'
        print(f'  {status}  {name:25s} ({lines}L)')
    else:
        print(f'  ❌  {name:25s} (missing)')
"

# 3. Config coverage
echo "━━━ Config Coverage ━━━"
python3 -c "
import json, os
with open(os.path.expanduser('~/.gemini/projects.json')) as f:
    projects = json.load(f)['projects']
for path, name in sorted(projects.items()):
    if not os.path.isdir(path) or path in ['/', os.path.expanduser('~')]:
        continue
    checks = {
        'settings': os.path.isfile(os.path.join(path, '.gemini/settings.json')),
        'ignore': os.path.isfile(os.path.join(path, '.gemini/.geminiignore')),
        'commands': os.path.isdir(os.path.join(path, 'commands')),
    }
    score = sum(checks.values())
    status = '✅' if score == 3 else '⚠️' if score > 0 else '❌'
    missing = [k for k, v in checks.items() if not v]
    extra = f' (missing: {\", \".join(missing)})' if missing else ''
    print(f'  {status}  {name:25s} {score}/3{extra}')
"

# 4. Brain status
echo "━━━ Brain Status ━━━"
echo "  Size: $(du -sh ~/.gemini/antigravity/brain/ | cut -f1)"
echo "  Conversations: $(ls -1d ~/.gemini/antigravity/brain/*/ 2>/dev/null | grep -v tempmediaStorage | wc -l | tr -d ' ')"
```

## Referencia

Consultar KI `gemini-global-config` para la arquitectura completa y `cross-repo-map` para dependencias entre repos.
