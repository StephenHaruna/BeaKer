#!/usr/bin/env bash
#Performs installation of BeaKer software
#version = 1.0.0

#### Environment Set Up

# Set the working directory to the script directory
pushd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null

# Set exit on error
set -o errexit
set -o errtrace
set -o pipefail

# ERROR HANDLING
__err() {
    echo2 ""
    echo2 "Installation failed on line $1:$2."
    echo2 ""
	exit 1
}

__int() {
    echo2 ""
	echo2 "Installation cancelled."
    echo2 ""
	exit 1
}

trap '__err ${BASH_SOURCE##*/} $LINENO' ERR
trap '__int' INT

# Load the function library
. ./shell-lib/acmlib.sh
normalize_environment

BEAKER_CONFIG_DIR="${BEAKER_CONFIG_DIR:-/etc/BeaKer/}"

test_system () {
    status "Checking minimum requirements"
    require_supported_os
    require_free_space "$HOME" "/var/lib" "/etc" "/usr" 5120
}

install_docker () {
    status "Installing Docker"
    $SUDO shell-lib/docker/install_docker.sh
    echo2 ''
    if $SUDO docker ps &>/dev/null ; then
		echo2 'Docker appears to be working, continuing.'
	else
        fail 'Docker does not appear to be working. Does the current user have sudo or docker privileges?'
	fi
}

ensure_env_file_exists () {
    $SUDO mkdir -p "$BEAKER_CONFIG_DIR"

    if [ ! -f "$BEAKER_CONFIG_DIR/env" ]; then
        status "Generating BeaKer configuration"
        echo2 "Please enter a password for the default Elasticsearch user account."
        echo2 "Username: elastic"
        local elastic_password=""
        local pw_confirmation="foobar"
        while [ "$elastic_password" != "$pw_confirmation" ]; do
            read -es -p "Password: " elastic_password
            echo ""
            read -es -p "Password (Confirmation): " pw_confirmation
            echo ""
        done

        cat << EOF | $SUDO tee "$BEAKER_CONFIG_DIR/env" > /dev/null
###############################################################################
# This file is automatically generated. You may modify it but your changes
# will be overwritten next time the file is generated.
#
# By putting variables in this file, they will be made available to use in
# your Docker Compose files, including to pass to containers. This file must
# be named ".env" in order for Docker Compose to automatically load these
# variables into its working environment.
#
# https://docs.docker.com/compose/environment-variables/#the-env-file
###############################################################################

###############################################################################
# Elastic Search Settings
#
ELASTIC_PASSWORD=${elastic_password}
###############################################################################
EOF
    fi

    $SUDO chown root:docker "$BEAKER_CONFIG_DIR/env"
    $SUDO chmod 640 "$BEAKER_CONFIG_DIR/env"

    if ! can_write_or_create ".env"; then
        sudo ln -sf "$BEAKER_CONFIG_DIR/env" .env
    else
        ln -sf "$BEAKER_CONFIG_DIR/env" .env
    fi
}

require_aih_web_server_listening () {
	if nc -z -w 15 127.0.0.1 5601 >/dev/null 2>&1 ; then
		echo2 "Able to reach Kibana web server, good."
	else
		fail "Unable to reach Kibana web server"
	fi
}


install_elk () {
    status "Installing Elasticsearch and Kibana"

    # Determine if the current user has permission to run docker
    local docker_sudo=""
    if [ ! -w "/var/run/docker.sock" ]; then
        docker_sudo="sudo"
    fi

    # Load the docker images
    gzip -d -c images-latest.tar.gz | $docker_sudo docker load >&2

    # Start Elasticsearch and Kibana with the new images
    ./beaker up -d --force-recreate >&2

    status "Waiting for initialization"
    sleep 15

    status "Loading Kibana dashboards"

    # Load password for kibana_import.sh.
    # Use docker_sudo since the env file ownership is root:docker.
    local es_pass=`$docker_sudo grep ELASTIC_PASSWORD "$BEAKER_CONFIG_DIR/env" | cut -d= -f2`

    local connection_attempts=0
    local data_uploaded="false"
    while [ $connection_attempts -lt 8 -a "$data_uploaded" != "true" ]; do
        if echo "$es_pass" | kibana/import_dashboards.sh "kibana/kibana_dashboards.ndjson" >&2 ; then
            data_uploaded="true"
            break
        fi
        sleep 15
        connection_attempts=$((connection_attempts + 1))
    done
    if [ "$data_uploaded" != "true" ]; then
        fail "The installer failed to load the Kibana dashboards"
    fi

    status "Congratulations, BeaKer is installed"
}

main () {
    status "Checking for administrator priviledges"
    require_sudo

    test_system

    status "Installing supporting software"
    ensure_common_tools_installed

    install_docker

    ensure_env_file_exists
    install_elk
}

main "$@"
#### Clean Up
# Change back to the initial working directory
popd > /dev/null