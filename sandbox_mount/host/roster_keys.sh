#!/usr/bin/env bash
# roster_keys.sh — fail unless every provider named in a roster has a key.
#
# There is no models.json registry in a sandbox any more: every provider the
# rosters name is a pi BUILT-IN, keyed by an environment variable. This script
# reads a roster, derives the distinct providers from its `model: provider/id`
# lines, maps each to its env var, and exits non-zero (naming the missing vars)
# if any is unset in the current environment.
#
# The provider -> env-var map is copied verbatim from pi's own
# `getApiKeyEnvVars` (pi-ai/dist/env-api-keys.js). setup.just gate E carries a
# SECOND copy because it runs INSIDE the sandbox, where this host script is not
# usable; if a future pi adds or renames a provider, both copies must be updated.
#
# Callers:
#   just/sandbox/lifecycle/fill.just   fail fast before shipping app/.env
#   just/sandbox/manage/mod.just       `doctor` preflight (dotenv-load supplies env)
#
# Usage: roster_keys.sh [roster-path]   (default: $SSSF_CONFIG — REQUIRED, no fallback)
set -euo pipefail

key_var_for() {
    case "$1" in
        deepseek)      echo DEEPSEEK_API_KEY ;;
        zai)           echo ZAI_API_KEY ;;
        zai-coding-cn) echo ZAI_CODING_CN_API_KEY ;;
        kimi-coding)   echo KIMI_API_KEY ;;
        minimax)       echo MINIMAX_API_KEY ;;
        minimax-cn)    echo MINIMAX_CN_API_KEY ;;
        openrouter)    echo OPENROUTER_API_KEY ;;
        openai)        echo OPENAI_API_KEY ;;
        anthropic)     echo ANTHROPIC_API_KEY ;;
        google)        echo GEMINI_API_KEY ;;
        mistral)       echo MISTRAL_API_KEY ;;
        xai)           echo XAI_API_KEY ;;
        moonshotai)    echo MOONSHOT_API_KEY ;;
        groq)          echo GROQ_API_KEY ;;
        cerebras)      echo CEREBRAS_API_KEY ;;
        fireworks)     echo FIREWORKS_API_KEY ;;
        together)      echo TOGETHER_API_KEY ;;
        baseten)       echo BASETEN_API_KEY ;;
        *) return 1 ;;
    esac
}

ROSTER="${1:-}"
# No fallback roster: with no explicit argument, $SSSF_CONFIG is REQUIRED and the
# shared guard prints THE named error. Explicit-arg callers (FILL passes "$ROSTER")
# are unchanged.
if [ -z "$ROSTER" ]; then
    ROSTER=$("$(dirname "$0")/require_sssf_config.sh")
fi
[ -f "$ROSTER" ] || { echo "roster_keys: roster $ROSTER not found" >&2; exit 1; }

PROVIDERS=$(awk '/^[[:space:]]*model:[[:space:]]/ {print $2}' "$ROSTER" \
            | sed 's|/.*||' | sort -u)
[ -n "$PROVIDERS" ] || { echo "roster_keys: parsed zero providers out of $ROSTER" >&2; exit 1; }

MISSING=()
for p in $PROVIDERS; do
    if ! var=$(key_var_for "$p"); then
        echo "roster_keys: provider '$p' is not a known pi built-in — add its" >&2
        echo "             env-var mapping here (and to setup.just gate E), or" >&2
        echo "             register it out of band" >&2
        exit 1
    fi
    [ -n "${!var:-}" ] || MISSING+=("$var (provider $p)")
done

if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "roster_keys: roster providers need keys that are not set in the environment:" >&2
    printf '             %s\n' "${MISSING[@]}" >&2
    echo "             add them to .env (see .env.sample) and re-run" >&2
    exit 1
fi
