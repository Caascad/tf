#!/usr/bin/env bash
set -e
set -o pipefail

TF_TMPDIR="./.tmp"
TF_CONFIG_DIR=""
TF_DEBUG="${TF_DEBUG:-0}"

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
  cat <<-EOF
		NAME
		      Thin wrapper around terraform to work with Caascad configurations

		SYNOPSIS
		      tf bootstrap [ -c CONFIGURATION ] [ -r GIT_REVISION ] [ -e ENVIRONMENT ]
		      tf init [-c CONFIGURATION] [-r GIT_REVISION] [-l LIB_URL] [-e ENVIRONMENT]
		      tf plan [-c CONFIGURATION] [-r GIT_REVISION] [-- TERRAFORM_OPTIONS ]
		      tf apply [-c CONFIGURATION] [-r GIT_REVISION] [-- TERRAFORM_OPTIONS ]
		      tf show [-c CONFIGURATION] [-- TERRAFORM_OPTIONS ]
		      tf destroy [-c CONFIGURATION] [-- TERRAFORM_OPTIONS ]
		      tf clean

		DESCRIPTION
		      bootstrap
		           helper provided to create a configuration directory within an environment directory.
		           It will create the directory with, tffile, terraform.tfvars, and .envrc in it.
		           This helper should be executed in an empty directory.

		      init
		           init the specified configuration in .tmp and setup the backend
		           according to the current ENVIRONMENT

		      plan
		           generates a terraform plan for the specified configuration

		      apply
		           creates resources planified with plan command

		      show
		           issue the terraform show command for the specified configuration

		      destroy
		           issue the terraform destroy command for the specified configuration

		      clean
		           clean .terraform and .tmp folder

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
    terraform_bin=$(nix-shell --run "type -p terraform" || log_error "No terraform binary is defined in the shell. Aborting.")
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

			# creds for FLEXIBLE ENGINE provider
			# Those creds are often available in the caascad keystore
			# export TF_VAR_fe_access_key=$(gopass caascad/fe/OCB1111111/FE_ACCESS_KEY)
			# export TF_VAR_fe_secret_key=$(gopass caascad/fe/OCB1111111/FE_SECRET_KEY)

			# provide FLEXIBLE ENGINE project and domain
			# export TF_VAR_fe_domain=XXXX
			# export TF_VAR_fe_tenant=YYYY
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
  log "Environment: ${ENVIRONMENT}"
  ACTION=$1;
  log "Action: ${ACTION}"
  LIB_URL="${LIB_URL:-git@git.corp.cloudwatt.com:pocwatt/terraform/lib.git}"
  log "Lib: ${LIB_URL}"
  GIT_REVISION="${GIT_REVISION:-refs/heads/master}"
  log "Revision: ${GIT_REVISION}"

  case "${ACTION}" in
    apply | plan | init | clean | show | destroy | bootstrap)
      ;;
    *)
      _tf_help
      exit 1
      ;;
  esac

  shift
  # parameters parsing
  while [[ $# -gt 1 ]]; do
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
      --)
        shift
        TERRAFORM_OPTIONS="$*"
        break
        ;;
      *)
        _tf_help
        exit 1
        ;;
    esac
    shift
  done

  # mandatory parameters check
  case "${ACTION}" in
    init | plan | apply | destroy | bootstrap)
      if [[ -z "${CONFIGURATION}" ]]; then
        log_warning "Missing configuration option"
        _tf_help
        exit 1
      fi
      ;;& # execution flow continues, next pattern is checked
    init | plan | apply | bootstrap)
      if [[ -z "${ENVIRONMENT}" ]]; then
        log_warning "Missing environment option"
        _tf_help
        exit 1
      fi
      ;;& # execution flow continues, next pattern is checked
    bootstrap)
      if [[ -z "${GIT_REVISION}" ]]; then
        log_warning "Missing git revision option"
        _tf_help
        exit 1
      fi
      ;;
  esac

  TF_CONFIG_DIR="${TF_TMPDIR}/configurations/${CONFIGURATION}"
  log "Config: ${CONFIGURATION}"
  log_debug "Config dir: ${TF_CONFIG_DIR}"
}

_tf_parsing "$@"

case "${ACTION}" in
  clean | init | bootstrap)
    "_tf_${ACTION}"
    ;;
  apply | plan)
    _tf_init
    ;& # bash 4 - the execution flow continues, the next pattern is not checked and the block is executed
  show | destroy)
    # shellcheck disable=2086
    _tf_generic "${ACTION}" ${TERRAFORM_OPTIONS}
    ;;
  *)
    _tf_help
    exit 1
    ;;
esac
