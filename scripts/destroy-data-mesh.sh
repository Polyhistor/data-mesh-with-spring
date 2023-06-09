#!/bin/bash


DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

# ccloud_library contains function for creating
# Confluent Cloud resources
# For now a copy of ccloud_library is copied locally until examples
#		CLI-1399 is tested and merged
# curl -sS -o ${DIR}/ccloud_library.sh https://raw.githubusercontent.com/brianstrauch/examples/CLI-1399/utils/ccloud_library.sh
source ${DIR}/ccloud_library.sh
source ${DIR}/helper.sh

# Setting default QUIET=false to surface potential errors
QUIET="${QUIET:-false}"
[[ $QUIET == "true" ]] &&
  REDIRECT_TO="/dev/null" ||
  REDIRECT_TO="/dev/stdout"

# Verifications
ccloud::validate_version_cli $CCLOUD_MIN_VERSION \
  && print_pass "ccloud version ok" \
  || exit 1
ccloud::validate_logged_in_cli \
  && print_pass "logged into ccloud CLI" \
  || exit 1
check_jq \
  && print_pass "jq installed" \
  || exit 1

if [ -z "$1" ]; then
  echo "ERROR: Must supply argument that is the client configuration file created from './create-data-mesh.sh'. (Is it in stack-configs/ folder?) "
  exit 1
else
  CONFIG_FILE=$1
fi

echo
PRESERVE_ENVIRONMENT="${PRESERVE_ENVIRONMENT:-false}"
if [[ $PRESERVE_ENVIRONMENT == "false" ]]; then
  read -p "This script will destroy all the resources (including the Confluent Cloud environment) in $CONFIG_FILE.  Do you want to proceed? [y/n] " -n 1 -r
else
  read -p "This script will destroy all the resources (except the Confluent Cloud environment) in $CONFIG_FILE.  Do you want to proceed? [y/n] " -n 1 -r
fi
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
  exit 1
fi

ccloud::validate_ccloud_config $CONFIG_FILE || exit 1
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
ccloud::generate_configs $CONFIG_FILE > /dev/null
source delta_configs/env.delta
SERVICE_ACCOUNT_ID=$(ccloud::get_service_account $CLOUD_KEY)

if [ -z "${SERVICE_ACCOUNT_ID+x}" ]; then
  echo "SERVICE_ACCOUNT_ID is blank"
  exit 1
else
  echo "Service account id = $SERVICE_ACCOUNT_ID"
fi

echo
REST_API_KEY=$( grep "^confluent.cloud.auth.key" $CONFIG_FILE | awk -F'=' '{print $2;}' )
if [[ ! -z "$REST_API_KEY" ]]; then confluent api-key delete $REST_API_KEY; fi
ccloud::destroy_ccloud_stack $SERVICE_ACCOUNT_ID

echo
echo "Tip: 'confluent' CLI currently has no environment set"
