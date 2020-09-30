#!/usr/bin/env bash
set -e
set -o pipefail

TF_TMPDIR="./.tmp"
TF_CONFIG_DIR=""
TF_DEBUG="${TF_DEBUG:-0}"
TF_ARGS=()
LIB_URL_DEFAULT="git@git.corp.cloudwatt.com:caascad/terraform/lib.git"
LIB_URL="${LIB_URL:-${LIB_URL_DEFAULT}}"
ENVIRONMENT=""
TF_USE_VAULT_AWS_STS_DEFAULT="1" # use vault for terraform backend configuration
AWS_STS_PATH="aws/sts/terraform_backend_usage"
TF_GENERATE_BACKEND_DEFAULT="1"
TF_BACKEND_BUCKET_DEFAULT_REGION_NAME="eu-west-3"
TF_BACKEND_BUCKET_DEFAULT_SUFFIX="tf-states"
CAASCAD_ZONES_URL_DEFAULT="https://git.corp.cloudwatt.com/caascad/caascad-zones/raw/master/zones.json"
TF_CAASCAD_ZONES_FILE="${TF_TMPDIR}/caascad-zones.json"
CAASCAD_ZONES_URL="${CAASCAD_ZONES_URL:-${CAASCAD_ZONES_URL_DEFAULT}}"
TF_USE_VAULT_AWS_STS="${TF_USE_VAULT_AWS_STS:-${TF_USE_VAULT_AWS_STS_DEFAULT}}"
TF_GENERATE_BACKEND="${TF_GENERATE_BACKEND:-${TF_GENERATE_BACKEND_DEFAULT}}"
TF_BACKEND_BUCKET_REGION_NAME="${TF_BACKEND_BUCKET_REGION_NAME:-${TF_BACKEND_BUCKET_DEFAULT_REGION_NAME}}"
TF_BACKEND_BUCKET_SUFFIX="${TF_BACKEND_BUCKET_SUFFIX:-${TF_BACKEND_BUCKET_DEFAULT_SUFFIX}}"

  [[ $# -eq 0 ]] && _tf_help && exit 0

log() {
    local args="$*"
    local prefix="\e[32m[tf]:\e[0m"
    echo -e "$prefix $args" >&2
}

log_debug() {
    [[ ${TF_DEBUG} -eq 0 ]] && return
    local args="$*"
    local prefix="\e[36m[tf]:\e[0m"
    echo -e "$prefix $args" >&2
}

log_warning() {
    local args="$*"
    local prefix="\e[33m[tf]:\e[0m"
    echo -e "$prefix $args" >&2
}

log_error() {
    local args="$*"
    local prefix="\e[31m[tf]:\e[0m"
    echo -e "$prefix $args" >&2
    exit 1
}

# help function
function _tf_help () {
  cat <<EOF
NAME
      Thin wrapper around Terraform to work with Caascad configurations

SYNOPSIS
      tf bootstrap [ -c CONFIGURATION ] [ -r GIT_REVISION ] [ -e ENVIRONMENT ]
      tf clean
      tf <terraform-action> [ARGS...]

DESCRIPTION
      bootstrap
            Helper provided to create a configuration directory within an environment directory.
            It will create the directory with, tffile, terraform.tfvars, and .envrc in it.
            This helper should be executed in an empty directory.

      clean
            Clean temporary config directory

      <terraform-action>
            Standard terraform actions, init apply, destroy, etc...

      -c | --configuration CONFIGURATION
            The name of the configuration to apply. It must be within the
            configuration directory in lib.git
            Can be set with CONFIGURATION environment variable

      -r | --revision GIT_REVISION
            The git revision to extract from lib.git
            Can be set with GIT_REVISION environment variable

            default: refs/heads/master

      -l | --lib-url LIB_URL
            Git repository url
            Can be set with LIB_URL environment variable
            Can be set to a local PATH for development purpose.
            e.g. ~/git/caascad/terraform/lib

            default: git@git.corp.cloudwatt.com:caascad/terraform/lib.git

      -e | --environment ENVIRONMENT
            The environment (i.e DNS domain) we are targetting
            Can be set with ENVIRONMENT environment variable

            default: current git repo name

EXAMPLES

      $ tf apply -c base -r refs/head/master \\
          -m git@git.corp.cloudwatt.com:caascad/terraform/mylib.git -e client1

      $ CONFIGURATION=base tf init
EOF
}

function _tf_generic () {
  (
    cd "${TF_CONFIG_DIR}"
    [ ! -f shell.nix ] && log_error "No shell.nix is present in '${TF_CONFIG_DIR}'. Aborting."
    terraform_bin=$(nix-shell --pure --run "type -p terraform" || log_error "No terraform binary is defined in the shell. Aborting.")
    log_debug "Running ${terraform_bin} $*"
    "$terraform_bin" "$@"
  )
}

function _tf_bootstrap () {
  # env directory
  mkdir -p "${CONFIGURATION}"
  (
    cd "${CONFIGURATION}"

    # get the git repository
    _tf_fetch

    # get *.tfvars if any
    templates="$(find "${TF_CONFIG_DIR}" -name '*.tfvars*')"
    for f in ${templates}; do
      if [[ ! -f $(basename "${f}") ]]; then
        cp "${f}" .
        _tf_replace_env "$(basename "$f")"
      fi
    done

    if [[ -f "envrc.EXAMPLE" ]] && [[ ! -f ".envrc" ]]; then
      cp envrc.EXAMPLE .envrc
    fi

    # generate tffile
    cat <<EOF > "./tffile"
CONFIGURATION=${CONFIGURATION}
GIT_REVISION=${GIT_REVISION}
# TF_DEBUG=${TF_DEBUG}
LIB_URL=${LIB_URL}
# LIB_URL=~/git/caascad/terraform/lib
ENVIRONMENT=${ENVIRONMENT}
TF_USE_VAULT_AWS_STS=${TF_USE_VAULT_AWS_STS}
AWS_STS_PATH=${AWS_STS_PATH}
TF_GENERATE_BACKEND=${TF_GENERATE_BACKEND}
CAASCAD_ZONES_URL=${CAASCAD_ZONES_URL}
TF_CAASCAD_ZONES_FILE=${TF_CAASCAD_ZONES_FILE}
TF_BACKEND_BUCKET_REGION_NAME=${TF_BACKEND_BUCKET_REGION_NAME}
TF_BACKEND_BUCKET_SUFFIX=${TF_BACKEND_BUCKET_SUFFIX}
EOF
  )
}

function _tf_fetch () {
  _tf_clean
  mkdir -p ${TF_TMPDIR}
  if ! _is_local "${LIB_URL}"; then
    log_debug "Fetching configuration from ${LIB_URL} at revision ${GIT_REVISION}"
    # fetch lib.git repository
    (
      cd ${TF_TMPDIR}
      git init >&2
      git remote add origin "${LIB_URL}"
      git fetch origin "${GIT_REVISION}"
      git reset --hard FETCH_HEAD >&2
    )
  else
    log_debug "Copying configuration from ${LIB_URL}"
    cp -R "${LIB_URL}"/* "${TF_TMPDIR}"
  fi
  _tf_update_doc
}

function _tf_update_doc() {
  # update *.EXAMPLE, *.md from configuration in the current directory
  docs="$(find "${TF_CONFIG_DIR}" -name '*EXAMPLE' -o -name '*.md')"
  for f in ${docs}; do
    cp "${f}" .
    _tf_replace_env "$(basename "$f")"
  done
}

function _tf_replace_env() {
  file="$1"
  sed -i "s/#ENVIRONMENT#/${ENVIRONMENT}/g" "$file"
}

function _tf_init () {
  # fetch the lib repository
  _tf_fetch

  # obtain caascad-zones
  _get_caascad_zones

  # populate some variables
  INFRA_ZONE_NAME=$(_get_from_caascad_zones "${ENVIRONMENT}" "infra_zone_name")
  log_debug "infra zone name is: ${INFRA_ZONE_NAME}"
  INFRA_DOMAIN_NAME=$(_get_from_caascad_zones "${INFRA_ZONE_NAME}" "domain_name")
  log_debug "infra domain name is: ${INFRA_ZONE_NAME}"
  ACCOUNT_ID=$(_get_from_caascad_zones "${INFRA_ZONE_NAME}" "providers.aws.account_id")
  log_debug "account_id is: ${ACCOUNT_ID}"
  TF_BACKEND_BUCKET_NAME="${INFRA_ZONE_NAME}-${ACCOUNT_ID}-${TF_BACKEND_BUCKET_DEFAULT_SUFFIX}"
  log_debug "backend bucket name is: ${TF_BACKEND_BUCKET_NAME}"
  TF_BACKEND_DYNAMODB_TABLE_NAME="${INFRA_ZONE_NAME}-${ACCOUNT_ID}-tf-locks"
  log_debug "dynamodb table name is: ${TF_BACKEND_DYNAMODB_TABLE_NAME}"

  # set vault url, we must be able to override the vault url provided by caascad zones
  if [[ -z "${VAULT_ADDR}" ]]; then
    VAULT_ADDR="https://vault.${INFRA_ZONE_NAME}.${INFRA_DOMAIN_NAME}"
    log_debug "vault addr is: ${VAULT_ADDR}"
  fi

  # generate backend file
  if [[ ${TF_GENERATE_BACKEND} -ne 0 ]]; then
    _tf_generate_backend
  fi

  # add any tf and tfvars files present here to override the downloaded configuration
  cp ./*.{tfvars,tfvars.json} "${TF_CONFIG_DIR}" &>/dev/null || true

  # environment replacement in every *tf* files
  sed -i "s/#ENVIRONMENT#/${ENVIRONMENT}/g" "${TF_CONFIG_DIR}"/*.tf*

  # detect args that should be passed to init as well
  declare -a init_args
  for arg in "$@"; do
    case "$arg" in
        -no-color|-input*)
            init_args+=("$arg")
            ;;
    esac
  done
  
  # terraform init
  BACKEND_CONFIG="$(_tf_backend_config)"
  # we want word splitting here
  # shellcheck disable=2086
  _tf_generic init -upgrade=true "${init_args[@]}" ${BACKEND_CONFIG} >&2
}

function _tf_backend_config () {
  if [[ ${TF_USE_VAULT_AWS_STS} -ne 0 ]]; then
    token=$(VAULT_ADDR=${VAULT_ADDR} vault read "${AWS_STS_PATH}" -format=json)
    log_debug "vault token: ${token}"
    TF_BACKEND_ACCESS_KEY=$(echo "$token" | jq -r '.data.access_key')
    TF_BACKEND_SECRET_KEY=$(echo "$token" | jq -r '.data.secret_key')
    TF_BACKEND_SESSION_TOKEN=$(echo "$token" | jq -r '.data.security_token')
    # set backend config options
    BACKEND_CONFIG="-backend-config=access_key=${TF_BACKEND_ACCESS_KEY} -backend-config=secret_key=${TF_BACKEND_SECRET_KEY} -backend-config=token=${TF_BACKEND_SESSION_TOKEN}"
    echo "${BACKEND_CONFIG}"
  fi
}

function _tf_clean () {
  rm -rf "${TF_TMPDIR}" &>/dev/null || true
}

function _is_local () {
  [[ -d "$1" || -f "$1" ]]
}

function _tf_generate_backend () {
    cat <<EOF > "${TF_CONFIG_DIR}/backend.tf"
# generated by tf
terraform {
  backend "s3" {
    bucket = "${TF_BACKEND_BUCKET_NAME}"
    key    = "${ENVIRONMENT}/${CONFIGURATION}/terraform.tfstate"
    region = "${TF_BACKEND_BUCKET_REGION_NAME}"
    dynamodb_table = "${TF_BACKEND_DYNAMODB_TABLE_NAME}"
  }
}
EOF
}

function _get_caascad_zones () {
  log_debug "caascad zones url is: ${CAASCAD_ZONES_URL}"
  if _is_local "${CAASCAD_ZONES_URL}"; then
    log_debug "caascad zones files is local"
    cp "${CAASCAD_ZONES_URL}" "${TF_CAASCAD_ZONES_FILE}"
  else
    log_debug "retrieve caascad zones file from ${CAASCAD_ZONES_URL}"
    curl --connect-timeout 5 -s -o "${TF_CAASCAD_ZONES_FILE}" "${CAASCAD_ZONES_URL}" || log_error "Could not retrieve ${CAASCAD_ZONES_URL}"
  fi
  log_debug "using caascad zones file in ${TF_CAASCAD_ZONES_FILE}"

  if ! jq -r -e --arg zone  "${ENVIRONMENT}" '.[$zone].name' < "${TF_CAASCAD_ZONES_FILE}" > /dev/null
  then
    log_error "cannot find zone ${ENVIRONMENT} in caascad-zones.json file.";
  fi
}

function _get_from_caascad_zones() {
  ZONE=$1
  KEY=$2
  jq -r ".\"$ZONE\".$KEY" < "${TF_CAASCAD_ZONES_FILE}"
}

function _tf_parsing () {
  # being sure we do not use the VAULT_ADDR of the user environment
  unset VAULT_ADDR
  # trying to source our environments variables
  # shellcheck disable=1091
  source "tffile" &>/dev/null || true
  if _is_local "${LIB_URL}"; then
    GIT_REVISION="local"
  else
    GIT_REVISION="${GIT_REVISION:-refs/heads/master}"
  fi

  # parameters parsing
  while [[ $# -gt 0 ]]; do
    case "$1" in
      help | -h | --help)
        _tf_help
        exit 0
        ;;
      -c | --configuration)
        shift
        CONFIGURATION=$1
        ;;
      -r | --revision)
        shift
        GIT_REVISION=$1
        ;;
      -l | --lib-url)
        shift
        LIB_URL=$1
        ;;
      -e | --environment)
        shift
        ENVIRONMENT=$1
        ;;
      *)
        TF_ARGS+=("$1")
        shift
        ;;
    esac
  done

  if [[ -z "${CONFIGURATION}" ]]; then
    log_warning "Missing configuration option"
    _tf_help
    exit 1
  fi

  if [[ -z "${ENVIRONMENT}" ]]; then
    log_warning "Missing environment option"
    _tf_help
    exit 1
  fi

  ACTION=${TF_ARGS[0]}
  TF_ARGS=("${TF_ARGS[@]:1}")
  TF_CONFIG_DIR="${TF_TMPDIR}/configurations/${CONFIGURATION}"

  log "Environment: ${ENVIRONMENT}"
  log "Lib: ${LIB_URL}"
  log "Revision: ${GIT_REVISION}"
  log "Config: ${CONFIGURATION}"
  log_debug "Config dir: ${TF_CONFIG_DIR}"
  log "Action: ${ACTION}"
  log "Args: ${TF_ARGS[*]}"

}

_tf_parsing "$@"

case "${ACTION}" in
  clean | bootstrap)
    "_tf_${ACTION}"
    ;;
  init)
    _tf_init "${TF_ARGS[@]}"
    ;;
  import|state|output|show)
    [ ! -d "${TF_CONFIG_DIR}" ] && _tf_init "${TF_ARGS[@]}"
    _tf_generic "${ACTION}" "${TF_ARGS[@]}"
    ;;
  *)
    _tf_init "${TF_ARGS[@]}"
    _tf_generic "${ACTION}" "${TF_ARGS[@]}"
    ;;
esac
