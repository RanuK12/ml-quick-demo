#!/usr/bin/env bash
# team_invoke.sh — Llamada de "delegación" del CEO (Ranukita) a un rol del equipo.
#
# Uso:
#   team_invoke.sh <rol> "<task description>" [flags]
#
# Roles disponibles:
#   frontend_dev, backend_dev, db_arch, tester_qa, devops,
#   senior_review, researcher, executor
#
# Flags:
#   --escalate       Forzar Claude Opus
#   --thinking <lvl> off|low|medium|high
#   --json           Output JSON crudo
#   --model <m>      Override de modelo
#
# Ejemplos:
#   team_invoke.sh db_arch "Schema users + tasks + RLS multi-tenant"
#   team_invoke.sh backend_dev "Endpoints REST CRUD /api/tasks con cursor"
#   team_invoke.sh senior_review "Review PR #18: src/auth.ts" --escalate

set -eo pipefail

PROMPTS_DIR="$HOME/.openclaw/workspace/team/prompts"
LOGS_DIR="$HOME/Empleados_Devs/logs/llm"
LEARNINGS_DIR="$HOME/Empleados_Devs/learnings"
DELEGATIONS_LOG="$HOME/Empleados_Devs/logs/delegations.jsonl"
CACHE_DIR="$HOME/Empleados_Devs/cache"
mkdir -p "$LOGS_DIR" "$LEARNINGS_DIR" "$(dirname "$DELEGATIONS_LOG")" "$CACHE_DIR"

# Devuelve "modelo_primario|modelo_fallback" para un rol, separado por |
route_for() {
  case "$1" in
    frontend_dev|backend_dev|tester_qa)
      echo "ollama/qwen2.5-coder:7b|ollama/qwen3:8b" ;;
    db_arch)
      echo "ollama/deepseek-r1:7b|ollama/qwen3:8b" ;;
    devops|researcher)
      echo "ollama/qwen2.5:7b|ollama/qwen3:8b" ;;
    executor)
      echo "ollama/qwen2.5:3b|ollama/llama3.2:3b" ;;
    senior_review)
      echo "anthropic/claude-sonnet-4-20250514|anthropic/claude-sonnet-4-20250514" ;;
    audit|automation|bounty|frontend|llm|outreach|research|scraping|backend)
      # Agentes especializados de Ranukita (~/.ranukita/agents/) → free cloud (Groq 70B) vía call_mimo
      echo "mimo/mimo-v2.5|mimo/mimo-v2.5" ;;
    *)
      echo "" ;;
  esac
}

# Detector de tareas creativas/educativas → auto-escalar (modelos locales fallan en esto)
is_creative_task() {
  local task_lower
  task_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  if echo "$task_lower" | grep -qiE 'examen|quiz|resumen didáctico|artículo|material educativo|generar preguntas|multiple choice|ensayo|redactar|escribir texto|contenido creativo|curso|tutorial escrito|guía didáctica'; then
    return 0
  fi
  return 1
}

# Funciones de deduplicación para researcher
generate_task_hash() {
  local role="$1"
  local task="$2"
  echo -n "${role}:${task}" | sha256sum | cut -d' ' -f1
}

check_researcher_cache() {
  local role="$1"
  local task="$2"
  local cache_file="$CACHE_DIR/researcher_$(generate_task_hash "$role" "$task").cache"
  
  # Si no es researcher, no usamos cache
  if [[ "$role" != "researcher" ]]; then
    return 1
  fi
  
  # Si existe el archivo y tiene menos de 24 horas, lo usamos
  if [[ -f "$cache_file" ]]; then
    local file_age=$(( $(date +%s) - $(stat -f %m "$cache_file") ))
    if [[ $file_age -lt 86400 ]]; then  # 24 horas en segundos
      echo "🔄 [researcher] Cache hit para tarea similar (generado hace $((file_age/3600))h)" >&2
      cat "$cache_file"
      return 0
    else
      rm -f "$cache_file"
    fi
  fi
  return 1
}

save_to_researcher_cache() {
  local role="$1"
  local task="$2"
  local output="$3"
  local cache_file="$CACHE_DIR/researcher_$(generate_task_hash "$role" "$task").cache"
  
  if [[ "$role" == "researcher" ]]; then
    echo "$output" > "$cache_file"
    chmod 600 "$cache_file"
  fi
}

# Auto-reviewer: para tareas SIMPLE/MEDIUM, revisa el output con qwen3:8b
# y devuelve APPROVED/CHANGES_REQUIRED/REJECTED + feedback corto
auto_review_output() {
  local task="$1"
  local output="$2"
  local role="$3"
  local trunc_output="${output:0:3000}"
  local prompt="Eres un code reviewer senior. Revisa este output de un agente $role para la tarea dada.
Responde SOLO con una línea: APPROVED | CHANGES_REQUIRED:<feedback corto> | REJECTED:<razón>

Criterios:
- APPROVED: el output resuelve la tarea correctamente, código válido, sin errores obvios
- CHANGES_REQUIRED: resuelve parcialmente, faltan detalles menores, mejoras sugeridas
- REJECTED: no resuelve la tarea, código inválido, refusa hacerla, vacío

Tarea: $task
--- Output ---
$trunc_output
--- Veredicto ---"
  local result
  result=$(echo "$prompt" | ollama run qwen3:8b --nowordwrap 2>/dev/null | head -3 | tr -d '\n')
  echo "${result:-APPROVED}"
}

# Filtro de entrada: detecta tareas que no deberían pasar al equipo
# (tests, saludos, tareas no-code) y las rechaza temprano
is_valid_dev_task() {
  local task_lower
  task_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  # Rechazar tareas triviales o no-code
  if echo "$task_lower" | grep -qiE '^(decí hola|decime hola|saludá|saludame|decí algo|hola$|^hi$|^hello$|decime algo|contame un chiste)'; then
    return 1
  fi
  return 0
}

# Clasificador de complejidad: usa qwen3:8b para decidir tier (SIMPLE/MEDIUM/COMPLEX)
classify_complexity() {
  local task="$1"
  local prompt="Classify this dev task as exactly one word: SIMPLE, MEDIUM, or COMPLEX. SIMPLE = single function, format conversion, rename, one-liner fix. MEDIUM = multi-file change, API integration, schema design, moderate logic. COMPLEX = architecture decision, security review, creative content, multi-system coordination. Task: $task. Answer (one word only):"
  local result
  result=$(echo "$prompt" | ollama run qwen3:8b --nowordwrap 2>/dev/null | tr -d '[:space:]')
  result=$(echo "$result" | grep -oiE 'SIMPLE|MEDIUM|COMPLEX' | head -1 | tr '[:lower:]' '[:upper:]')
  echo "${result:-MEDIUM}"
}

# Verificador post-output: qwen3:8b valida si el output es coherente
verify_output() {
  local task="$1"
  local output="$2"
  
  # Confidence scoring: output muy corto o con frases de incertidumbre → FAIL
  local output_len=${#output}
  if [[ $output_len -lt 50 ]]; then
    echo "FAIL:output too short ($output_len chars)"
    return
  fi
  if echo "$output" | grep -qiE "I('m| am) not sure|I cannot|I can't help|as an AI|I don't have|unable to|I apologize|no puedo|no me es posible"; then
    echo "FAIL:model refused or expressed uncertainty"
    return
  fi
  
  local trunc_output="${output:0:2000}"
  local prompt="You are a code reviewer. Given a task and its output, respond ONLY with PASS if the output correctly addresses the task, or FAIL:<brief reason> if it does not. Signs of FAIL: empty/minimal output, refusal to complete task, obvious errors, output unrelated to task, copyright refusal. Task: $task --- Output: $trunc_output --- Verdict:"
  local result
  result=$(echo "$prompt" | ollama run qwen3:8b --nowordwrap 2>/dev/null | head -1)
  echo "$result"
}

# NIM API tier (free cloud quality via NVIDIA NIM)
NIM_API_URL="https://integrate.api.nvidia.com/v1/chat/completions"
NIM_API_KEY="${NVIDIA_API_KEY:-$(grep -o 'nvapi-[A-Za-z0-9_-]*' ~/.ranukita/.env 2>/dev/null | head -1 || true)}"

call_nim() {
  local task="$1"
  local system_prompt="$2"
  local full_prompt="$system_prompt

TAREA:
$task"
  local response
  local payload
  payload=$(python3 -c '
import json, sys
content = sys.stdin.read()
print(json.dumps({"model":"deepseek/deepseek-r1","messages":[{"role":"user","content":content}],"max_tokens":4096}))
' <<< "$full_prompt")
  response=$(curl -s --max-time 120 "$NIM_API_URL" \
    -H "Authorization: Bearer $NIM_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null)
  echo "$response" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("choices",[{}])[0].get("message",{}).get("content",""))
except:
    pass
' 2>/dev/null
}

# Un intento contra un endpoint OpenAI-compat. Echo del content (vacío si error/rate-limit).
_one_completion() {
  local base="$1" key="$2" model="$3" content="$4" ua
  ua="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
  local payload
  payload=$(MODEL="$model" python3 -c '
import json, sys, os
print(json.dumps({"model":os.environ["MODEL"],"messages":[{"role":"user","content":sys.stdin.read()}],"max_tokens":4096}))
' <<< "$content")
  curl -s --max-time 180 "$base/chat/completions" \
    -H "Authorization: Bearer $key" -H "Content-Type: application/json" -H "User-Agent: $ua" -d "$payload" 2>/dev/null \
  | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if "error" not in d:
        print(d.get("choices",[{}])[0].get("message",{}).get("content",""))
except: pass
' 2>/dev/null
}

call_mimo() {
  # Escalación: GROQ (gratis, rápido) primero; si vuelve vacío (rate-limit diario / error) cae a MiMo.
  local task="$1"; local system_prompt="$2"
  local aicfg="$HOME/.ranukita/integrations/config/ai_apis.env"
  local mcfg="$HOME/.ranukita/integrations/config/mimo.env"
  local full out gkey
  full="$system_prompt

TAREA:
$task"
  gkey=$(grep '^GROQ_API_KEY=' "$aicfg" 2>/dev/null | cut -d= -f2)
  if [[ -n "$gkey" ]]; then
    out=$(_one_completion "https://api.groq.com/openai/v1" "$gkey" "llama-3.3-70b-versatile" "$full")
  fi
  # Fallback a MiMo si Groq no respondió (vacío = rate-limit/error)
  if [[ -z "$out" ]]; then
    local mkey mbase mmodel
    mkey=$(grep '^MIMO_API_KEY=' "$mcfg" 2>/dev/null | cut -d= -f2)
    mbase=$(grep '^MIMO_BASE_URL=' "$mcfg" 2>/dev/null | cut -d= -f2)
    mmodel=$(grep '^MIMO_MODEL_PRO=' "$mcfg" 2>/dev/null | cut -d= -f2); mmodel="${mmodel:-mimo-v2.5-pro}"
    if [[ -n "$mkey" && -n "$mbase" ]]; then
      out=$(_one_completion "$mbase" "$mkey" "$mmodel" "$full")
    fi
  fi
  [[ -z "$out" ]] && out="[escalación sin respuesta: Groq rate-limited y MiMo no configurado/sin respuesta]"
  echo "$out"
}

usage() {
  cat <<EOF
Uso: $(basename "$0") <rol> "<task>" [flags]

Roles: frontend_dev, backend_dev, db_arch, tester_qa, devops,
       senior_review, researcher, executor

Flags:
  --escalate       Forzar Claude Opus
  --thinking <lvl> off|low|medium|high
  --json           Output JSON crudo
  --model <m>      Override de modelo

Ejemplo:
  $(basename "$0") db_arch "Schema users + tasks + RLS"
EOF
  exit 1
}

[[ $# -lt 2 ]] && usage

# Parser flexible: aceptar flags y posicionales en cualquier orden.
ESCALATE=false
THINKING=""
JSON_OUT=false
MODEL_OVERRIDE=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --escalate) ESCALATE=true; shift ;;
    --thinking)
      [[ -z "${2:-}" ]] && { echo "--thinking requiere valor (off|low|medium|high)" >&2; exit 2; }
      THINKING="$2"; shift 2 ;;
    --json) JSON_OUT=true; shift ;;
    --model)
      [[ -z "${2:-}" ]] && { echo "--model requiere valor (provider/name)" >&2; exit 2; }
      MODEL_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage ;;
    --) shift; POSITIONAL+=("$@"); break ;;
    -*) echo "Flag desconocida: $1" >&2; usage ;;
    *)  POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ "${#POSITIONAL[@]}" -lt 2 ]]; then
  echo "❌ Faltan argumentos: <rol> y <task> son obligatorios." >&2
  usage
fi

ROLE="${POSITIONAL[0]}"
# El task es todo lo demás concatenado por espacio (por si viene sin comillas, lo unimos)
TASK="${POSITIONAL[*]:1}"

PROMPT_FILE="$PROMPTS_DIR/$ROLE.md"
# Fallback: agentes especializados de Ranukita (audit/bounty/outreach/scraping/llm/automation/...)
if [[ ! -f "$PROMPT_FILE" ]] && [[ -f "$HOME/.ranukita/agents/$ROLE.md" ]]; then
  PROMPT_FILE="$HOME/.ranukita/agents/$ROLE.md"
fi
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "❌ Rol desconocido: $ROLE" >&2
  echo "   Ver $(basename $0) sin args para la lista" >&2
  exit 2
fi

ROUTE=$(route_for "$ROLE")
if [[ -z "$ROUTE" ]]; then
  echo "❌ Rol sin routing: $ROLE" >&2
  exit 2
fi
PRIMARY="${ROUTE%%|*}"
FALLBACK="${ROUTE##*|}"

# Guardrail anti-loop: si esta (rol, hash_task) ya intentó 2+ veces sin terminar bien
# en los logs de hoy, auto-escalate a Opus.
TASK_HASH=$(echo "$ROLE:$TASK" | shasum -a 256 | cut -c1-12)
LOG_TODAY="$LOGS_DIR/$(date +%Y-%m-%d).jsonl"
ATTEMPTS_PRIOR=0
if [[ -f "$LOG_TODAY" ]]; then
  # Contar líneas 'start' anteriores con el mismo hash (forzar valor numérico único)
  ATTEMPTS_PRIOR=$(grep "\"hash\":\"$TASK_HASH\"" "$LOG_TODAY" 2>/dev/null | grep -c '"event":"start"' || true)
  ATTEMPTS_PRIOR=${ATTEMPTS_PRIOR:-0}
  # Sanitizar: asegurar que sea un entero
  if ! [[ "$ATTEMPTS_PRIOR" =~ ^[0-9]+$ ]]; then
    ATTEMPTS_PRIOR=0
  fi
fi

AUTO_ESCALATED=false
if [[ "$ATTEMPTS_PRIOR" -ge 2 ]] && ! $ESCALATE && [[ -z "$MODEL_OVERRIDE" ]]; then
  echo "🚨 Guardrail: $ATTEMPTS_PRIOR intentos previos de la misma tarea → auto-escalate a Opus" >&2
  ESCALATE=true
  AUTO_ESCALATED=true
fi

# ─── FILTRO DE ENTRADA: rechazar tareas no-code / triviales ───
if ! is_valid_dev_task "$TASK"; then
  echo "❌ Tarea rechazada por filtro de entrada (trivial/no-code). Usá researcher o executor para esto." >&2
  exit 2
fi

# ─── SMART ROUTING: clasificar complejidad y decidir tier ───
COMPLEXITY=""
TIER=""
CREATIVE_ESCALATE=false
if ! $ESCALATE && [[ -z "$MODEL_OVERRIDE" ]] && [[ "$ROLE" != "executor" ]] && [[ "$ROLE" != "senior_review" ]]; then
  # Auto-routing de tareas creativas/educativas directo a Opus (modelos locales fallan)
  if is_creative_task "$TASK"; then
    echo "🎨 Tarea creativa/educativa detectada → auto-escalate a Opus" >&2
    ESCALATE=true
    CREATIVE_ESCALATE=true
  else
    COMPLEXITY=$(classify_complexity "$TASK")
    case "$COMPLEXITY" in
      SIMPLE)  TIER="1" ;;  # local directo, sin verificación
      MEDIUM)  TIER="2" ;;  # local + verificador, si falla → NIM
      COMPLEX) TIER="3" ;;  # NIM directo, si falla → Opus
    esac
    echo "📊 Complejidad: $COMPLEXITY → Tier $TIER" >&2
  fi
fi

# Decidir modelo
ESCALATE_FALLBACK="mimo/mimo-v2.5"
if [[ -n "$MODEL_OVERRIDE" ]]; then
  MODEL="$MODEL_OVERRIDE"
elif $ESCALATE; then
  MODEL="mimo/mimo-v2.5-pro"
elif [[ "$TIER" == "3" ]]; then
  # Tier 3: tareas complejas van directo a NIM API (gratis, cloud quality)
  MODEL="nim/deepseek-r1"
  
  # Si es researcher, verificar si ya hicimos esta tarea antes
  if [[ "$ROLE" == "researcher" ]]; then
    echo "🔍 [researcher] Deduplicación de tareas activa" >&2
    # Limpieza de cache: mantener solo los últimos 100 archivos (evitar disco lleno)
    find "$CACHE_DIR" -name "researcher_*.cache" -type f | head -n -100 | xargs rm -f 2>/dev/null || true
  fi
else
  MODEL="$PRIMARY"
fi

# Si es ollama, verificar que el modelo está descargado
if [[ "$MODEL" == ollama/* ]]; then
  MODEL_NAME="${MODEL#ollama/}"
  if ! ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$MODEL_NAME"; then
    echo "⚠️  $MODEL_NAME no descargado todavía; usando fallback $FALLBACK" >&2
    MODEL="$FALLBACK"
    if [[ "$MODEL" == ollama/* ]]; then
      FB_NAME="${MODEL#ollama/}"
      if ! ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$FB_NAME"; then
        echo "❌ Fallback $FB_NAME tampoco disponible" >&2
        exit 3
      fi
    fi
  fi
fi

# Componer prompt completo
SYSTEM_PROMPT=$(cat "$PROMPT_FILE")

# AUTO-ENTRENAMIENTO (07-10, pedido Emilio "elevar a los agentes"): inyectar el PRIMER de conocimiento
# de élite del dominio del rol -> cada agente ejecuta con expertise real (programación/finanzas/sistemas),
# no solo su prompt base. Los primers viven en ~/.ranukita/knowledge/. (case = compatible bash 3.2 de macOS)
KN_DIR="$HOME/.ranukita/knowledge"
case "$ROLE" in
  bounty)     PRIMERS="freelance_bounties.md money_playbook.md" ;;
  outreach)   PRIMERS="sales_outreach.md marketing_distribution.md product_pricing.md" ;;
  research)   PRIMERS="economics_decisions.md money_playbook.md" ;;
  backend|frontend|scraping|automation|audit|llm) PRIMERS="software_delivery.md" ;;
  *)          PRIMERS="" ;;
esac
KNOWLEDGE=""
for pr in $PRIMERS; do
  [[ -f "$KN_DIR/$pr" ]] && KNOWLEDGE+=$'\n=== CONOCIMIENTO DE ÉLITE DE TU DOMINIO (aplicá esto SIEMPRE) ===\n'"$(cat "$KN_DIR/$pr")"
done
[[ -n "$KNOWLEDGE" ]] && SYSTEM_PROMPT="$SYSTEM_PROMPT"$'\n'"$KNOWLEDGE"

# Inyectar lecciones aprendidas (global + por rol)
LEARNINGS=""
[[ -f "$LEARNINGS_DIR/_global.md" ]] && LEARNINGS+=$'\n=== LECCIONES GLOBALES DEL EQUIPO (priorizá esto) ===\n'$(cat "$LEARNINGS_DIR/_global.md")
[[ -f "$LEARNINGS_DIR/$ROLE.md" ]] && LEARNINGS+=$'\n=== LECCIONES ESPECÍFICAS DE TU ROL (priorizá esto) ===\n'$(cat "$LEARNINGS_DIR/$ROLE.md")

# Consulta semántica a ChromaDB (si está indexado)
QUERY_SCRIPT="$HOME/Apps/ranukita-bridge/scripts/ranukita-query-learnings.sh"
if [[ -x "$QUERY_SCRIPT" ]] && [[ -d "$HOME/.ranukita/chromadb" ]]; then
  SEMANTIC_HITS=$("$QUERY_SCRIPT" "$TASK" 2>/dev/null | head -30)
  if [[ -n "$SEMANTIC_HITS" ]]; then
    LEARNINGS+=$'\n=== LECCIONES RELEVANTES (búsqueda semántica) ===\n'"$SEMANTIC_HITS"
  fi
fi

[[ -n "$LEARNINGS" ]] && LEARNINGS+=$'\n=== FIN LECCIONES ===\n'

# Inyectar hojas de contexto según el rol
EXTRA_CONTEXT=""
CONTEXT_DIR="$HOME/.openclaw/workspace/team/context"
case "$ROLE" in
  frontend_dev|backend_dev|tester_qa)
    if [[ -f "$CONTEXT_DIR/NEXT_15_CONTEXT.md" ]]; then
      EXTRA_CONTEXT=$(cat "$CONTEXT_DIR/NEXT_15_CONTEXT.md")
    fi
    ;;
esac

if [[ -n "$EXTRA_CONTEXT" ]]; then
  FULL_PROMPT="$SYSTEM_PROMPT
$LEARNINGS

=== CONTEXTO TÉCNICO ACTUALIZADO (úsalo, no lo ignores) ===
$EXTRA_CONTEXT
=== FIN CONTEXTO ===

TAREA:
$TASK"
else
  FULL_PROMPT="$SYSTEM_PROMPT
$LEARNINGS

TAREA:
$TASK"
fi

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOG_FILE="$LOG_TODAY"
ESCAPED_TASK=$(printf '%s' "$TASK" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
echo "{\"ts\":\"$TS\",\"hash\":\"$TASK_HASH\",\"role\":\"$ROLE\",\"model\":\"$MODEL\",\"event\":\"start\",\"attempt\":$((ATTEMPTS_PRIOR+1)),\"auto_escalated\":$AUTO_ESCALATED,\"task\":$ESCAPED_TASK}" >> "$LOG_FILE"

# Construir comando openclaw
if [[ "$MODEL" == "mimo/"* ]]; then
  # Escalación a MiMo (calidad alta, paga) cuando el empleado local no alcanza
  echo "🦞 [$ROLE] → MiMo ($MODEL, calidad alta) ..." >&2
  START=$(date +%s)
  set +e
  OUTPUT=$(call_mimo "$TASK" "$SYSTEM_PROMPT$LEARNINGS")
  RC=$?
  set -e
  DUR=$(( $(date +%s) - START ))
  [[ -z "$OUTPUT" ]] && RC=1
elif [[ "$MODEL" == "nim/"* ]]; then
  # NIM API: llamada directa sin openclaw
  echo "🦞 [$ROLE] → NIM API (deepseek-r1, gratis) ..." >&2
  START=$(date +%s)
  set +e
  OUTPUT=$(call_nim "$TASK" "$SYSTEM_PROMPT$LEARNINGS")
  RC=$?
  set -e
  DUR=$(( $(date +%s) - START ))
  [[ -z "$OUTPUT" ]] && RC=1
else
  # Check cache for researcher role
  if check_researcher_cache "$ROLE" "$TASK"; then
    # Output already returned from cache, just set duration
    DUR=0
  else
    CMD=( openclaw infer model run --model "$MODEL" --prompt "$FULL_PROMPT" )
    $JSON_OUT && CMD+=( --json )
    [[ -n "$THINKING" ]] && CMD+=( --thinking "$THINKING" )

    echo "🦞 [$ROLE] → $MODEL ..." >&2
    START=$(date +%s)
    set +e
    OUTPUT=$("${CMD[@]}" 2>&1)
    RC=$?
    set -e
    DUR=$(( $(date +%s) - START ))
    
    # Save to cache if it's researcher and succeeded
    if [[ $RC -eq 0 && "$ROLE" == "researcher" ]]; then
      save_to_researcher_cache "$ROLE" "$TASK" "$OUTPUT"
    fi
  fi
fi

# Fallback chain: si escaló a Opus y falló (deprecated/error), reintentar con Sonnet
if [[ $RC -ne 0 ]] && $ESCALATE && [[ "$MODEL" == "mimo/mimo-v2.5-pro" ]]; then
  echo "⚠️  MiMo pro falló (rc=$RC), cayendo a fallback: $ESCALATE_FALLBACK ..." >&2
  MODEL="$ESCALATE_FALLBACK"
  START=$(date +%s)
  set +e
  OUTPUT=$(call_mimo "$TASK" "$SYSTEM_PROMPT$LEARNINGS")
  RC=$?
  set -e
  [[ -z "$OUTPUT" ]] && RC=1
  DUR=$(( $(date +%s) - START ))
fi

# ─── SMART VERIFY: verificar output y re-rutear si falla (Tier 2+) ───
if [[ $RC -eq 0 ]] && [[ "$TIER" == "2" || "$TIER" == "3" ]] && ! $ESCALATE && ! $JSON_OUT; then
  VERDICT=$(verify_output "$TASK" "$OUTPUT")
  if echo "$VERDICT" | grep -qi "^FAIL"; then
    FAIL_REASON=$(echo "$VERDICT" | sed 's/^FAIL[: ]*//')
    echo "🔄 Verificador: FAIL ($FAIL_REASON) → re-routing al tier superior..." >&2
    if [[ "$TIER" == "2" ]]; then
      # Tier 2 falla → NIM API
      echo "🦞 [$ROLE] → NIM API (re-route desde tier 2) ..." >&2
      START2=$(date +%s)
      set +e
      OUTPUT=$(call_nim "$TASK" "$SYSTEM_PROMPT$LEARNINGS")
      RC=$?
      set -e
      DUR=$(( DUR + $(date +%s) - START2 ))
      MODEL="nim/deepseek-r1"
    elif [[ "$TIER" == "3" ]]; then
      # Tier 3 falla → Opus/Sonnet
      echo "🦞 [$ROLE] → Claude (re-route desde tier 3) ..." >&2
      MODEL="anthropic/claude-sonnet-4-20250514"
      # Check cache for researcher role in fallback
      if check_researcher_cache "$ROLE" "$TASK"; then
        # Output already returned from cache, just update duration
        DUR=$(( DUR + $(date +%s) - START2 ))
      else
        CMD=( openclaw infer model run --model "$MODEL" --prompt "$FULL_PROMPT" )
        [[ -n "$THINKING" ]] && CMD+=( --thinking "$THINKING" )
        START2=$(date +%s)
        set +e
        OUTPUT=$("${CMD[@]}" 2>&1)
        RC=$?
        set -e
        DUR=$(( DUR + $(date +%s) - START2 ))
        
        # Save to cache if it's researcher and succeeded
        if [[ $RC -eq 0 && "$ROLE" == "researcher" ]]; then
          save_to_researcher_cache "$ROLE" "$TASK" "$OUTPUT"
        fi
      fi
    fi
  else
    echo "✅ Verificador: PASS" >&2
  fi
fi

# ─── AUTO-REVIEW: para tareas SIMPLE/MEDIUM, revisión automática con qwen3:8b ───
AUTO_REVIEW_VEREDICT=""
if [[ $RC -eq 0 ]] && [[ -n "$COMPLEXITY" ]] && [[ "$COMPLEXITY" != "COMPLEX" ]] && [[ "$ROLE" != "senior_review" ]] && ! $JSON_OUT; then
  AUTO_REVIEW_VEREDICT=$(auto_review_output "$TASK" "$OUTPUT" "$ROLE")
  echo "🔍 Auto-review: $AUTO_REVIEW_VEREDICT" >&2
  # Si REJECTED, loguear como advertencia (no falla el pipeline, pero queda registro)
  if echo "$AUTO_REVIEW_VEREDICT" | grep -qi "^REJECTED"; then
    echo "⚠️  Auto-review REJECTED — revisar output manualmente" >&2
  fi
fi

echo "{\"ts\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"hash\":\"$TASK_HASH\",\"role\":\"$ROLE\",\"model\":\"$MODEL\",\"event\":\"end\",\"duration_sec\":$DUR,\"exit_code\":$RC,\"complexity\":\"${COMPLEXITY:-unknown}\",\"tier\":\"${TIER:-0}\",\"auto_review\":\"${AUTO_REVIEW_VEREDICT:-none}\"}" >> "$LOG_FILE"

# Log estructurado para Capataz (un evento completo por delegación)
ESCAPED_OUTPUT=$(printf '%s' "${OUTPUT:0:8000}" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
echo "{\"ts\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"hash\":\"$TASK_HASH\",\"role\":\"$ROLE\",\"model\":\"$MODEL\",\"duration_sec\":$DUR,\"exit_code\":$RC,\"attempt\":$((ATTEMPTS_PRIOR+1)),\"auto_escalated\":$AUTO_ESCALATED,\"task\":$ESCAPED_TASK,\"output\":$ESCAPED_OUTPUT}" >> "$DELEGATIONS_LOG"

echo "$OUTPUT"

# ─────────────────────────────────────────────────────────────────────
# POST-GENERATION HOOK: validadores automáticos según el rol/contenido
# ─────────────────────────────────────────────────────────────────────
# Solo si la invocación tuvo éxito y NO se pidió --json (que parsean otros)
if [[ $RC -eq 0 ]] && ! $JSON_OUT; then
  TMP_OUTPUT=$(mktemp -t teaminv_XXXXXX)
  echo "$OUTPUT" > "$TMP_OUTPUT"

  HOOK_RAN=false
  HOOK_REPORT=""

  # Decidir qué validadores correr según rol y contenido detectado.
  # set -e está activo, por eso || true.
  has_sql=$( (grep -cE 'CREATE TABLE|ALTER TABLE|CREATE INDEX|CREATE TRIGGER|CREATE FUNCTION' "$TMP_OUTPUT" 2>/dev/null || true) | head -1 )
  has_yaml=$( (grep -cE '^[[:space:]]*name:|^[[:space:]]*on:|^[[:space:]]*jobs:|^[[:space:]]*runs-on:' "$TMP_OUTPUT" 2>/dev/null || true) | head -1 )
  has_ts=$( (grep -cE '```typescript|```tsx|```ts$|export[[:space:]]+(async[[:space:]]+)?function|import[[:space:]]+.*[[:space:]]+from' "$TMP_OUTPUT" 2>/dev/null || true) | head -1 )
  has_sql=${has_sql:-0}
  has_yaml=${has_yaml:-0}
  has_ts=${has_ts:-0}

  # SQL: db_arch o cualquiera con DDL detectado
  if [[ "$ROLE" == "db_arch" ]] || [[ ${has_sql:-0} -ge 3 ]]; then
    if [[ -x "$HOME/Empleados_Devs/scripts/sql_lint.sh" ]]; then
      # Extraer el primer bloque SQL del output a un archivo
      TMP_SQL=$(mktemp -t sqllint_XXXXXX.sql)
      python3 -c "
import re, sys
md = open('$TMP_OUTPUT').read()
blocks = re.findall(r'\`\`\`sql\n(.*?)\`\`\`', md, re.DOTALL)
print('\n\n'.join(blocks) if blocks else '')
" > "$TMP_SQL"
      if [[ -s "$TMP_SQL" ]]; then
        HOOK_RAN=true
        SQL_REPORT=$("$HOME/Empleados_Devs/scripts/sql_lint.sh" "$TMP_SQL" 2>&1 || true)
        HOOK_REPORT+="$SQL_REPORT"$'\n'
      fi
      rm -f "$TMP_SQL"
    fi
  fi

  # YAML: devops o si parece workflow
  if [[ "$ROLE" == "devops" ]] || [[ ${has_yaml:-0} -ge 2 ]]; then
    if [[ -x "$HOME/Empleados_Devs/scripts/yaml_lint.sh" ]]; then
      TMP_YAML=$(mktemp -t yamllint_XXXXXX.yml)
      python3 -c "
import re, sys
md = open('$TMP_OUTPUT').read()
blocks = re.findall(r'\`\`\`ya?ml\n(.*?)\`\`\`', md, re.DOTALL)
print(blocks[0] if blocks else '')
" > "$TMP_YAML"
      if [[ -s "$TMP_YAML" ]]; then
        HOOK_RAN=true
        YAML_REPORT=$("$HOME/Empleados_Devs/scripts/yaml_lint.sh" "$TMP_YAML" 2>&1 || true)
        HOOK_REPORT+="$YAML_REPORT"$'\n'
      fi
      rm -f "$TMP_YAML"
    fi
  fi

  # TS/TSX: frontend_dev / backend_dev / tester_qa con bloques TS
  if [[ "$ROLE" == "frontend_dev" || "$ROLE" == "backend_dev" || "$ROLE" == "tester_qa" ]] && [[ ${has_ts:-0} -ge 1 ]]; then
    if [[ -x "$HOME/Empleados_Devs/scripts/ts_lint.sh" ]]; then
      HOOK_RAN=true
      # Solo el resumen final del ts_lint, no el ruido de stubs
      TS_REPORT=$("$HOME/Empleados_Devs/scripts/ts_lint.sh" "$TMP_OUTPUT" 2>&1 | grep -E "^(##|✅|❌|⚠️|  Total|  -|  ✓|  ✗|src/)" | tail -20 || true)
      HOOK_REPORT+="$TS_REPORT"$'\n'
    fi
  fi

  # Imprimir reporte de hook si corrió alguno
  if $HOOK_RAN; then
    echo ""
    echo "─── 🤖 Validadores automáticos ───" >&2
    echo "$HOOK_REPORT" >&2
    echo "─────────────────────────────────" >&2
  fi

  rm -f "$TMP_OUTPUT"
fi

exit $RC
