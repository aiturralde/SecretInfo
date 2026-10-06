# Documentacion de GitHub Environments

El workflow `.github/workflows/generate-variables-documentation.yml` regenera
`Variables.md` en la raiz del repositorio. Usa Bash, `gh`, REST API y `jq` en
`ubuntu-latest`. La logica esta en
`.github/scripts/generate-variables-documentation.sh`.

**La informacion sensible debe almacenarse como Secret y nunca como Environment
Variable. Los valores de Environment Variables se publican intencionalmente en
`Variables.md` y permanecen en el historial Git, accesible a quienes puedan leer
el repositorio.** Los secrets solo se documentan por nombre y fechas disponibles:
no se solicita ni se publica su contenido.

## Configuracion y permisos

Crear `CONFIG_READER_TOKEN` en **Settings > Secrets and variables > Actions >
New repository secret**, no como variable ni como secret de un Environment.
Usar preferentemente un personal access token fine-grained limitado exclusivamente
a este repositorio, con los permisos de lectura indicados abajo. Metadata: read
se incluye automaticamente. No conceder permisos de escritura ni usar este token
para operaciones Git.

- Actions: read, para consultar Environments y protection rules.
- Environments: read, para listar variables y metadatos de secrets de Environments.

El titular debe tener acceso al repositorio; si la organizacion requiere
aprobacion del token o autorizacion SSO, completar ese proceso. Mantener el token
vigente. Un PAT classic con `repo` es mas amplio y no permite el aislamiento
granular de solo lectura solicitado; por eso no es la opcion recomendada.
No hace falta consultar miembros de la organizacion: usuarios y equipos se
obtienen directamente de las protection rules.

El token de consulta solo se inyecta como `GH_TOKEN` en el paso de generacion.
El checkout recibe explicitamente `GITHUB_TOKEN`; sus credenciales se utilizan
para el push. El unico permiso del job para ese token es `contents: write`.
Las politicas de Actions del repositorio/organizacion deben permitirlo.

## Ejecucion

Publicar estos archivos en la default branch (la configuracion inicial del
proyecto indica `master`; este checkout todavia no tiene remoto ni commits).
El workflow resuelve la default branch mediante
`github.event.repository.default_branch`, sin asumir un nombre fijo.

- Manual: **Actions > Generate environments documentation > Run workflow**.
  Seleccionar la default branch. No requiere parametros.
- Diaria: cron `17 3 * * *`, a las **03:17 UTC**. GitHub puede retrasar ejecuciones
  programadas; los workflows programados deben existir en la default branch.
  En repositorios publicos inactivos, GitHub puede deshabilitar el schedule.

La primera ejecucion exitosa crea `Variables.md`; no se incluye un inventario
inicial ficticio porque la configuracion real debe consultarse en GitHub.
Cada ejecucion consulta toda la configuracion, construye un documento nuevo en
un directorio temporal privado y reemplaza el archivo solamente al completar
todas las consultas y el renderizado. Los elementos eliminados desaparecen del
documento. No se agregan datos al archivo anterior.

Se usa `gh api --paginate --slurp` en todos los listados, con `per_page=100`
para Environments/secrets y `per_page=30` para variables (su maximo documentado).
Los nombres de Environments se codifican mediante `jq @uri`, incluidos espacios,
barras y caracteres Unicode. Se consulta el detalle de cada Environment para
obtener usuarios/equipos aprobadores y `prevent_self_review`, conservando tanto
`true` como `false`. La ausencia de aprobadores, variables, secrets o Environments
se indica expresamente. Fechas o configuraciones no disponibles se identifican
como `No disponible`. Los Environments, variables y secrets se ordenan por nombre.
Los valores se escapan para evitar romper tablas Markdown o insertar HTML;
los saltos de linea se representan con `<br>`.

La fecha de ultima generacion usa UTC y corresponde a la ejecucion actual.
Por ello, ejecuciones en segundos distintos normalmente producen un commit
aunque la configuracion no haya cambiado. La regeneracion es idempotente respecto
al inventario: no duplica entradas ni conserva elementos eliminados; la fecha es
el unico dato deliberadamente dependiente del momento de ejecucion.

## Actualizacion y errores

Despues de generar el documento se ejecuta `git diff --quiet -- Variables.md`
y se comprueba si el archivo esta versionado, para detectar tambien la primera
generacion. Si no hay diferencias, se informa que no hubo cambios y se termina
sin commit. Si las hay, se configura `github-actions[bot]`, se agrega
**exclusivamente** `Variables.md`, se crea el commit
`docs: update environments variables and secrets` y se hace push a la default
branch. No se usa `git add .`, force-push ni `CONFIG_READER_TOKEN` para escribir.
La concurrencia evita ejecuciones simultaneas de este workflow.

Un fallo HTTP, de autenticacion, de permisos, de rate limit o de parseo hace
fallar el job: no se publica un inventario parcial ni se interpreta el fallo
como una lista vacia. El script identifica el endpoint fallido sin imprimir
tokens, respuestas API, valores de variables o el documento en los logs.
Los temporales se eliminan al salir. Revisar permisos, expiracion y disponibilidad
del recurso, corregir el problema y volver a ejecutar.

Branch protection/rulesets que exijan pull requests, revisiones, firmas o checks,
o restrinjan los actores autorizados, pueden rechazar el push de `GITHUB_TOKEN`.
`contents: write` no evita esas restricciones. En ese caso el job falla sin
saltarse las reglas; acordar una politica que permita al bot este cambio o
adaptar la publicacion a pull requests. Si otro actor modifica la rama entre el
checkout y el push, este se rechaza sin forzar: volver a ejecutar sobre la rama
actualizada. Los pushes hechos con `GITHUB_TOKEN` normalmente no disparan otros
workflows basados en `push`.

## Endpoints REST utilizados

Todos los endpoints se consultan con GET y la version `2022-11-28`:

| Endpoint | Informacion |
|---|---|
| `/repos/{owner}/{repo}/environments` | Listado paginado de Environments |
| `/repos/{owner}/{repo}/environments/{environment_name}` | Protection rules, reviewers y prevent_self_review |
| `/repos/{owner}/{repo}/environments/{environment_name}/variables` | Variables propias del Environment, valores y fechas |
| `/repos/{owner}/{repo}/environments/{environment_name}/secrets` | Nombres y fechas de secrets propios del Environment |

No se consultan variables ni secrets de repositorio/organizacion heredados.
GitHub REST no permite recuperar el valor almacenado de un secret.
Las funciones disponibles dependen del plan de GitHub y la visibilidad del
repositorio.

Referencias oficiales:

- [Environments](https://docs.github.com/en/rest/deployments/environments)
- [Environment Variables](https://docs.github.com/en/rest/actions/variables#list-environment-variables)
- [Environment Secrets](https://docs.github.com/en/rest/actions/secrets#list-environment-secrets)
- [Permisos fine-grained](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)
