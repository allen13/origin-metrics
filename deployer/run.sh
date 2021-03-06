#!/bin/bash
#
# Copyright 2014-2015 Red Hat, Inc. and/or its affiliates
# and other contributors as indicated by the @author tags.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
 
for script in scripts/*.sh; do source $script; done

set -eux

#
# determine a bunch of variables from env or defaults
#

# what purpose this invocation should perform:
# preflight, deploy, validate, upgrade, remove, debug
deployer_mode=${MODE:-deploy}

# The version of everything to deploy
image_prefix=${IMAGE_PREFIX:-openshift/origin-}
image_version=${IMAGE_VERSION:-latest}

master_url=${MASTER_URL:-https://kubernetes.default.svc:8443}

# Set to true to undeploy everything before deploying
redeploy=${REDEPLOY:-false}
if [ "$redeploy" == true ]; then
  mode=redeploy
else
  mode=${MODE:-deploy}
  [ "$mode" = redeploy ] && redeploy=true
fi

# The number of initial Cassandra Nodes to Deploy
cassandra_nodes=${CASSANDRA_NODES:-1}
# If we should use persistent storage or not
use_persistent_storage=${USE_PERSISTENT_STORAGE:-true}
# The size of each Cassandra Node
cassandra_pv_size=${CASSANDRA_PV_SIZE:-10Gi}

# How long metrics should be stored in days
metric_duration=${METRIC_DURATION:-7}

#
heapster_node_id=${HEAPSTER_NODE_ID:-nodename}

#
metric_resolution=${METRIC_RESOLUTION:-10s}

# The project we are deployed in
project=${PROJECT:-openshift-infra}

# the master certificate and service account tokens
master_ca=${MASTER_CA:-/var/run/secrets/kubernetes.io/serviceaccount/ca.crt}
token_file=${TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}

# directory to perform all the processing
dir=${PROCESSING_DIR:-_output} #directory used to write files which generating certificates
# location of deployer secret mount
secret_dir=${SECRET_DIR:-_secret}
# ensure directories exist in local use case
rm -rf $dir && mkdir -p $dir && chmod 700 $dir || :
mkdir -p $secret_dir && chmod 700 $secret_dir || :

hawkular_metrics_hostname=${HAWKULAR_METRICS_HOSTNAME:-hawkular-metrics.example.com}
hawkular_metrics_alias=${HAWKULAR_METRICS_ALIAS:-hawkular-metrics}
hawkular_cassandra_alias=${HAWKULAR_CASSANDRA_ALIAS:-hawkular-cassandra}

openshift admin ca create-signer-cert  \
  --key="${dir}/ca.key" \
  --cert="${dir}/ca.crt" \
  --serial="${dir}/ca.serial.txt" \
  --name="metrics-signer@$(date +%s)"

# set up configuration for client
if [ -n "${WRITE_KUBECONFIG:-}" ]; then
    # craft a kubeconfig, usually at $KUBECONFIG location
    oc config set-cluster master \
      --api-version='v1' \
      --certificate-authority="${master_ca}" \
      --server="${master_url}"
    oc config set-credentials account \
      --token="$(cat ${token_file})"
    oc config set-context current \
      --cluster=master \
      --user=account \
      --namespace="${PROJECT}"
    oc config use-context current
fi

# set up client config file; user can opt to use their own instead
old_kc="$KUBECONFIG"
KUBECONFIG="$dir/kube.conf"
[ -z "${WRITE_KUBECONFIG:-}" ] && cp "$old_kc" $dir/kube.conf
oc config set-cluster deployer-master \
  --api-version='v1' \
  --certificate-authority="${master_ca}" \
  --server="${master_url}"
oc config set-credentials deployer-account \
  --token="$(cat ${token_file})"
oc config set-context deployer-context \
  --cluster=deployer-master \
  --user=deployer-account \
  --namespace="${project}"
[ -n "${WRITE_KUBECONFIG:-}" ] && oc config use-context deployer-context

case $deployer_mode in
preflight)
    validate_preflight
    ;;
deploy|redeploy|refresh)
    validate_preflight || [ "${IGNORE_PREFLIGHT:-}" = true ]
    handle_previous_deployment
    create_signer_cert "${dir}"
    [ -z "${HEAPSTER_STANDALONE:-}" ] && deploy_hawkular
    deploy_heapster
    validate_deployment
    ;;
validate)
    validate_deployment
    ;;
upgrade)
    ;;
remove)
    handle_previous_deployment
    ;;
debug)
    echo "sleeping forever; shell in and debug at will."
    while true; do sleep 10; done
    ;;
*)
    echo "Invalid mode: ${deployer_mode}"
    exit 255
    ;;
esac

echo 'Success!'
