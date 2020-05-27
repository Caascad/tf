#!/usr/bin/env bash
set -e
set -o pipefail

TF_TMPDIR="./.tmp"
TF_CONFIG_DIR=""
TF_DEBUG="${TF_DEBUG:-0}"
TERRAFORM_ARGS=""

log() {
    local args="$*"
    local prefix="\e[32m[tf]:\e[0m"
    echo -e "$prefix $args"
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
      tf <terraform-action> [TERRAFORM_ARGS...]

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

            default: git@git.corp.cloudwatt.com:pocwatt/terraform/lib.git

      -e | --environment ENVIRONMENT
            The environment (i.e DNS domain) we are targetting
            Can be set with ENVIRONMENT environment variable

            default: current git repo name

EXAMPLES

      $ tf apply -c base -r refs/head/master \\
          -m git@git.corp.cloudwatt.com:pocwatt/terraform/mylib.git -e client1

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
  # global .envrc for s3 backend
  if ! [[ -f "./.envrc" ]]; then
    cat <<-'EOF' >"./.envrc"
			# creds for AMAZON S3 backend
			# Those creds are individuals and should be stored in you personal keystore
			# you can use gopass to retrieve them. For example:
			export AWS_ACCESS_KEY_ID=$(gopass keystore/caascad/aws/181151069204/AWS_ACCESS_KEY_ID)
			export AWS_SECRET_ACCESS_KEY=$(gopass keystore/caascad/aws/181151069204/AWS_SECRET_ACCESS_KEY)
		EOF
  fi

  # .gitignore
  if ! [[ -f "./.gitignore" ]]; then
    cat <<-'EOF' >"./.gitignore"
			.terraform/
			.envrc
			.tmp/
			.direnv.d/
		EOF
  fi

  # env directory
  mkdir -p "${CONFIGURATION}"
  (
    cd "${CONFIGURATION}"

    # get the git repository
    _tf_fetch

    # get envrc.EXAMPLE, tfvars file and documentation
    LIST_FILE="$(find "${TF_CONFIG_DIR}" -name '*EXAMPLE' -o -name '*.tfvars*' -o -iname 'readme*' -o -name '*.md')"
    for f in ${LIST_FILE}; do
      if [[ ! -f $(basename "${f}") ]]; then
        cp "${f}" .
      fi
    done

    if [[ -f "${TF_CONFIG_DIR}/envrc.EXAMPLE" ]] && [[ ! -f ".envrc" ]]; then
      cp "${TF_CONFIG_DIR}/envrc.EXAMPLE" .envrc || true
    fi

    # substitute #ENVIRONMENT in terraform.tfvars and .envrc
    sed -i "s/#ENVIRONMENT#/${ENVIRONMENT}/g" ./terraform.tfvars* "./.envrc" &>/dev/null || true

    # generate tffile
    cat <<-EOF >"./tffile"
			CONFIGURATION=${CONFIGURATION}
			GIT_REVISION=${GIT_REVISION}
			# TF_DEBUG=${TF_DEBUG}
			# LIB_URL=${LIB_URL}
			# LIB_URL=~/git/caascad/terraform
			ENVIRONMENT=${ENVIRONMENT}
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
      git init
      git remote add origin "${LIB_URL}"
      git fetch origin "${GIT_REVISION}"
      git reset --hard FETCH_HEAD
    )
  else
    log_debug "Copying configuration from ${LIB_URL}"
    cp -R "${LIB_URL}"/* "${TF_TMPDIR}"
  fi
}

function _tf_init () {
  # fetch the lib repository
  _tf_fetch

  # add any tf and tfvars files present here to override the downloaded configuration
  cp ./*.{tf,tfvars,tfvars.json} "${TF_CONFIG_DIR}" &>/dev/null || true

  # environment replacement in every *tf* files
  sed -i "s/#ENVIRONMENT#/${ENVIRONMENT}/g" "${TF_CONFIG_DIR}"/*.tf*

  # terraform init
  _tf_generic init -upgrade=true
}

function _tf_clean () {
  rm -rf "${TF_TMPDIR}" &>/dev/null || true
}

function _is_local () {
  [[ -d "$1" ]]
}

function _tf_parsing () {
  # trying to source our environments variables
  # shellcheck disable=1091
  source "tffile" &>/dev/null || true
  # some default variables
  ENV=$(basename "$(git remote get-url origin 2>/dev/null)")
  ENVIRONMENT="${ENVIRONMENT:-${ENV%.*}}"
  LIB_URL="${LIB_URL:-git@git.corp.cloudwatt.com:pocwatt/terraform/lib.git}"
  log "Lib: ${LIB_URL}"
  if _is_git_url "${LIB_URL}"; then
    GIT_REVISION="${GIT_REVISION:-refs/heads/master}"
    log "Revision: ${GIT_REVISION}"
  fi
  ACTION=$1;
  shift
  log "Action: ${ACTION}"

  # parameters parsing
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
        TERRAFORM_ARGS="$TERRAFORM_ARGS $1"
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

  log_debug "Args:$TERRAFORM_ARGS"
  log "Environment: ${ENVIRONMENT}"
  log "Config: ${CONFIGURATION}"

  TF_CONFIG_DIR=$(realpath "${TF_TMPDIR}/configurations/${CONFIGURATION}")
  log_debug "Config dir: ${TF_CONFIG_DIR}"

}

_tf_parsing "$@"

case "${ACTION}" in
  clean | bootstrap)
    "_tf_${ACTION}"
    ;;
  init)
    _tf_init
    ;;
  apply | plan)
    _tf_init
    # bash 4 - the execution flow continues
    # the next pattern is not checked and the block is executed
    ;&
  *)
    # shellcheck disable=2086
    _tf_generic "${ACTION}" ${TERRAFORM_ARGS}
    ;;
esac
