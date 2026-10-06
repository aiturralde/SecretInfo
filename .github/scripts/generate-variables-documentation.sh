#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must identify the target repository.}"
: "${GH_TOKEN:?CONFIG_READER_TOKEN must be configured as a repository Actions secret.}"
unset GH_DEBUG
export GH_PROMPT_DISABLED=1

for tool in gh jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Error: required command not found: %s\n' "$tool" >&2
    exit 1
  fi
done

temporary_dir=$(mktemp -d .variables-documentation.XXXXXX)
trap 'rm -rf -- "$temporary_dir"' EXIT

api_get() {
  local endpoint=$1 output=$2
  shift 2
  if ! gh api --method GET \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "$endpoint" "$@" >"$output" 2>"$temporary_dir/api-error.txt"; then
    # Do not print response bodies or CLI debug output, which may contain data.
    printf 'Error: GitHub API request failed: %s\n' "$endpoint" >&2
    printf '%s\n' 'Check token permissions/expiration, API rate limits and resource availability. Variables.md was not replaced.' >&2
    return 1
  fi
}

collect_pages() {
  local endpoint=$1 field=$2 output=$3 page_size=${4:-100}
  api_get "$endpoint?per_page=$page_size" "$temporary_dir/pages.json" --paginate --slurp
  jq -e --arg field "$field" '
    if type == "array" and length > 0 and
       all(.[]; (.[$field] | type) == "array") then
      [.[] | .[$field][]] |
      if all(.[]; (.name | type) == "string") then sort_by(.name)
      else error("Invalid name in GitHub API response") end
    else
      error("Invalid paginated GitHub API response")
    end
  ' "$temporary_dir/pages.json" >"$output"
}

repository_endpoint="repos/$GITHUB_REPOSITORY"
collect_pages "$repository_endpoint/environments" environments "$temporary_dir/environments.json"
jq -r '.[] | .name | @uri' "$temporary_dir/environments.json" >"$temporary_dir/environment-names.txt"
: >"$temporary_dir/documentation.jsonl"

while IFS= read -r encoded_name; do
  environment_endpoint="$repository_endpoint/environments/$encoded_name"
  api_get "$environment_endpoint" "$temporary_dir/environment.json"
  collect_pages "$environment_endpoint/variables" variables "$temporary_dir/variables.json" 30
  collect_pages "$environment_endpoint/secrets" secrets "$temporary_dir/secrets.json"

  jq -ce --slurpfile variables "$temporary_dir/variables.json" \
    --slurpfile secrets "$temporary_dir/secrets.json" '
    if (.name | type) != "string" or
       ((.protection_rules // []) | type) != "array" or
       (all($variables[0][]; (.value | type) == "string") | not) then
      error("Invalid environment response")
    else
      {
        name,
        required_reviewers: [
          (.protection_rules // [])[] | select(.type == "required_reviewers")
        ],
        variables: [$variables[0][] | {name, value, updated_at}],
        secrets: [$secrets[0][] | {name, created_at, updated_at}]
      }
    end
  ' "$temporary_dir/environment.json" >>"$temporary_dir/documentation.jsonl"
done <"$temporary_dir/environment-names.txt"

generated_at=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
jq -rs --arg repository "$GITHUB_REPOSITORY" --arg generated_at "$generated_at" '
  def text:
    tostring
    | gsub("&"; "&amp;")
    | gsub("<"; "&lt;")
    | gsub(">"; "&gt;")
    | gsub("\\|"; "&#124;")
    | gsub("`"; "&#96;")
    | gsub("\\*"; "&#42;")
    | gsub("_"; "&#95;")
    | gsub("\\["; "&#91;")
    | gsub("\\]"; "&#93;")
    | gsub("\\\\"; "&#92;")
    | gsub("~"; "&#126;")
    | gsub("\r"; "&#13;")
    | gsub("\n"; "<br>")
    | gsub("\t"; "&#9;");
  def code: "<code>" + text + "</code>";
  def metadata: if . == null then "No disponible" else code end;
  def row: "| " + join(" | ") + " |";
  def reviewer:
    if .type == "User" then
      "- Usuario: " + (.reviewer.login | metadata)
    elif .type == "Team" then
      "- Equipo: " + ((.reviewer.slug // .reviewer.name) | metadata)
    else
      error("Unsupported required reviewer type")
    end;

  "# Variables and Secrets",
  "",
  "> Archivo generado automaticamente. No modificar manualmente.",
  "> IMPORTANTE: almacenar informacion sensible como Secret, nunca como Environment Variable. Los valores de las variables se publican en este archivo y en el historial Git.",
  "",
  ("- Repositorio: " + ($repository | code)),
  ("- Ultima generacion: " + ($generated_at | code)),
  "",
  (if length == 0 then "No existen GitHub Environments en este repositorio.", "" else empty end),
  (.[] |
    ("## Environment: " + (.name | code)),
    "",
    "### Aprobadores requeridos",
    "",
    ([.required_reviewers[] | (.reviewers // [])[]] | sort_by(.type, (.reviewer.login // .reviewer.slug // .reviewer.name)) |
      if length == 0 then "No hay aprobadores requeridos."
      else .[] | reviewer end),
    "",
    ("Prevent self-review: " +
      (if (.required_reviewers | length) == 0 then "No disponible"
       else [.required_reviewers[] |
         if has("prevent_self_review") and .prevent_self_review != null then
           .prevent_self_review | code
         else "No disponible" end] | join(", ")
       end)),
    "",
    "### Variables",
    "",
    (if (.variables | length) == 0 then "No hay variables configuradas en este Environment."
     else
       "| Nombre | Valor | Actualizada |",
       "|---|---|---|",
       (.variables | sort_by(.name)[] |
         [(.name | code), (.value | code), (.updated_at | metadata)] | row)
     end),
    "",
    "### Secrets",
    "",
    (if (.secrets | length) == 0 then "No hay secrets configurados en este Environment."
     else
       "| Nombre | Creado | Actualizado |",
       "|---|---|---|",
       (.secrets | sort_by(.name)[] |
         [(.name | code), (.created_at | metadata), (.updated_at | metadata)] | row)
     end),
    "",
    "---",
    ""
  )
' "$temporary_dir/documentation.jsonl" >"$temporary_dir/Variables.md"

mv -- "$temporary_dir/Variables.md" Variables.md
printf '%s\n' 'Variables.md generado correctamente.'
