Ejecuta un healthcheck completo del entorno Gemini CLI.

## Qué verifica

1. **MCPs configurados** — tanto en `settings.json` como en `mcp_config.json` (Antigravity)
2. **Knowledge Items** — lista todos los KIs indexados
3. **Skills activas** — con tamaño de cada una
4. **Extensiones** — verifica `gemini-extension.json`
5. **Dependencias del sistema** — node, python3, git, cargo, docker, etc.
6. **Configuración del repo actual** — GEMINI.md, settings.json, .geminiignore, commands/, pre-commit hook

## Ejecución

```bash
~/.gemini/repo-template/healthcheck.sh
# o desde PATH:
healthcheck
```

## Referencia

Consultar KI `gemini-global-config` para la arquitectura de configuración completa.
