#!/bin/bash

################################################################
# Source Confluent Platform versions
################################################################
DIR_HELPER="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

function check_jq() {
  if [[ $(type jq 2>&1) =~ "not found" ]]; then
    echo "'jq' is not found. Install 'jq' and try again"
    exit 1
  fi

  return 0
}

function preflight_checks() {
  # Verifications
  ccloud::validate_version_ccloud_cli $CCLOUD_MIN_VERSION \
    && print_pass "ccloud version ok" \
    || exit 1
  ccloud::validate_logged_in_ccloud_cli \
    && print_pass "logged into ccloud CLI" \
    || exit 1
  check_jq \
    && print_pass "jq installed" \
    || exit 1
}

function create_data_product () {
  dp=$1
  owner=$2

  printf "\n";print_process_start "====== Create Data Product: $dp."

  CMD="ccloud kafka topic create $dp"
  $CMD &>"$REDIRECT_TO" \
    && print_pass "$CMD" \
    || exit_with_error -c $? -n "$NAME" -m "$CMD" -l $(($LINENO -3))

  CONNECTOR_CONFIG="${DIR_HELPER}/connectors/ccloud-datagen-${dp}.json"
  ccloud::create_connector $CONNECTOR_CONFIG || exit 1
  ccloud::wait_for_connector_up $CONNECTOR_CONFIG 600 || exit 1
  printf "\nSleeping 60 seconds until the datagen source connector starts producing records for ${dp}\n"
  sleep 60

  # Get the qualified name
  QN=$(curl -s -u ${SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO} "${SCHEMA_REGISTRY_URL}/catalog/v1/search/basic?types=sr_subject_version" | jq -r --arg dp "${dp}-value" '.entities[].attributes | select(.name==$dp) | .qualifiedName ')
  echo "Qualified name for Kafka subject $dp: $QN"

  echo -e "\nAdd tag to ${dp}"
  curl -X POST -u ${SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO} "${SCHEMA_REGISTRY_URL}/catalog/v1/entity/tags" \
    --header 'Content-Type: application/json' \
    --data '[ { "entityType" : "sr_subject_version", "entityName" : "'"${QN}"'", "typeName" : "DataProduct", "attributes" : { "owner":"'"${owner}"'", "description":"website '"${dp}"'"} }]'
  echo -e "\nVerify tag is attached to ${dp}"
  curl -s -u ${SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO} "${SCHEMA_REGISTRY_URL}/catalog/v1/search/basic?types=sr_subject_version" | jq -r --arg dp "${dp}-value" '.entities[] | select(.attributes.name==$dp) | .classificationNames[] '
  echo -e "\nView tag details"
  curl -s -u ${SCHEMA_REGISTRY_BASIC_AUTH_USER_INFO} "${SCHEMA_REGISTRY_URL}/catalog/v1/entity/type/sr_subject_version/name/${QN}/tags" | jq .

  return 0
}

function create_ksqldb_app() {
  MAX_WAIT=720
  echo "Waiting up to $MAX_WAIT seconds for Confluent Cloud ksqlDB cluster to be UP"
  ccloud::retry $MAX_WAIT ccloud::validate_ccloud_ksqldb_endpoint_ready $KSQLDB_ENDPOINT
  CMD="ccloud ksql app list -o json | jq -r '.[].id'"
  ksqlDBAppId=$(eval $CMD) \
    && print_pass "Retrieved ksqlDB application ID: $ksqlDBAppId" \
    || exit_with_error -c $? -n "$NAME" -m "$CMD" -l $(($LINENO -3))
  CMD="ccloud ksql app configure-acls $ksqlDBAppId pageviews users"
  $CMD \
    && print_pass "$CMD" \
    || exit_with_error -c $? -n "$NAME" -m "$CMD" -l $(($LINENO -3))
  while read ksqlCmd; do
          response=$(curl -w "\n%{http_code}" -X POST $KSQLDB_ENDPOINT/ksql \
                 -H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
                 -u $KSQLDB_BASIC_AUTH_USER_INFO \
                 --silent \
                 -d @<(cat <<EOF
          {
            "ksql": "$ksqlCmd",
            "streamsProperties": {
                          "ksql.streams.auto.offset.reset":"earliest",
                          "ksql.streams.cache.max.bytes.buffering":"0"
                  }
          }
EOF
          ))
          echo "$response"
          echo "$response" | {
            read body
            read code
            if [[ "$code" -gt 299 ]];
              then print_code_error -c "$ksqlCmd" -m "$(echo "$body" | jq .message)"
              else print_pass  -c "$ksqlCmd" -m "$(echo "$body" | jq -r .[].commandStatus.message)"
            fi
          }
          sleep 3;
  done < ${DIR_HELPER}/statements-cloud.sql
}

PRETTY_PASS="\e[32m✔ \e[0m"
function print_pass() {
  printf "${PRETTY_PASS}%s\n" "${1}"
}
PRETTY_ERROR="\e[31m✘ \e[0m"
function print_error() {
  printf "${PRETTY_ERROR}%s\n" "${1}"
}
PRETTY_CODE="\e[1;100;37m"
function print_code() {
	printf "${PRETTY_CODE}%s\e[0m\n" "${1}"
}
function print_process_start() {
	printf "⌛ %s\n" "${1}"
}
function print_code_pass() {
  local MESSAGE=""
	local CODE=""
  OPTIND=1
  while getopts ":c:m:" opt; do
    case ${opt} in
			c ) CODE=${OPTARG};;
      m ) MESSAGE=${OPTARG};;
		esac
	done
  shift $((OPTIND-1))
	printf "${PRETTY_PASS}${PRETTY_CODE}%s\e[0m\n" "${CODE}"
	[[ -z "$MESSAGE" ]] || printf "\t$MESSAGE\n"			
}
function print_code_error() {
  local MESSAGE=""
	local CODE=""
  OPTIND=1
  while getopts ":c:m:" opt; do
    case ${opt} in
			c ) CODE=${OPTARG};;
      m ) MESSAGE=${OPTARG};;
		esac
	done
  shift $((OPTIND-1))
	printf "${PRETTY_ERROR}${PRETTY_CODE}%s\e[0m\n" "${CODE}"
	[[ -z "$MESSAGE" ]] || printf "\t$MESSAGE\n"			
}
