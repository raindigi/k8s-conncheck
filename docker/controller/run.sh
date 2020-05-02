#!/bin/sh

set -e

# Helper function for printing a line consisting of a timestamp and message
log() {
  color_ts="\e[94;1m"
  color_msg="\e[;1m"
  echo -e "$color_ts$(date -Isec) $color_msg$1\e[0m"
}

# Invoked after the start of a prober Pod before the first test result is read.
# Receives the following args:
#   $1: name of the prober Pod
#   $2: IP address of the prober Pod
#   $3: name of the node on which the prober Pod is running
#   $4: IP address of the node on which the prober Pod is running
init() {
  :
}

# Invoked for each test result of a prober Pod (a test consists of pinging
# a target; a target may be a Pod or a node; a prober Pod performs a sequence
# of tests with different targets). Receives the following args:
#   $1: test result
# The test result is a JSON object (formatted as a single line) with the
# following fields:
#   - test_id (string):     identifier of the type of test being performed
#   - target_ip (string):   IP address of the target 
#   - target_name (string): friendly name of the target
#   - success (boolean):    whether the target could be reached or not
process_test_result() {
  test_id=$(echo "$1" | jq -r '.test_id')
  target_ip=$(echo "$1" | jq -r '.target_ip')
  target_name=$(echo "$1" | jq -r '.target_name')
  success=$(echo "$1" | jq -r '.success')

  case "$test_id" in
    pod-self) msg="To itself" ;;
    pod-pod-local) msg="To pod on same node" ;;
    pod-pod-remote) msg="To pod on different node" ;;
    pod-node-local) msg="To own node" ;;
    pod-node-remote) msg="To different node" ;;
  esac

  case "$success" in
    true)
      icon="\xE2\x9C\x85" 
      color="\e[92;1m"
      ;;
    false)
      icon="\xe2\x9b\x94"
      color="\e[91;1m"
      ;;
  esac

  echo -e "$color  $icon $msg (\"$target_name\" $target_ip)\e[0m"
}

# Invoked after all tests of a prober Pod have been completed before the prober
# Pod is deleted. Receives no arguments.
finalize() {
  :
}

log "Initialising..."

API_SERVER=$(yq read /etc/kubernetes/kubelet.conf 'clusters[0].cluster.server')

# kubectl wrapper function with default connection flags
mykubectl() {
  kubectl \
    --server "$API_SERVER" \
    --certificate-authority /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    --token "$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    "$@"
}

# Wait until all target Pods are running
while ! daemonset=$(mykubectl get daemonset conncheck-target -o json) ||
  [[ "$(echo "$daemonset" | jq '.status.numberReady')" -ne "$(echo "$daemonset" | jq '.status.desiredNumberScheduled')" ]]; do
  sleep 1
done

PODS=$(\
  mykubectl \
    --selector app=conncheck-target \
    --output json \
    get pods |
    jq -c '[.items[] | {name: .metadata.name, ip: .status.podIP, node: .spec.nodeName}]' \
)

# TODO: restrict nodes to worker nodes
NODES=$(\
  mykubectl \
    --output json \
    get nodes |
    jq -c '[.items[] | {name: .metadata.name, ip: .status.addresses[] | select(.type == "InternalIP") | .address}]' \
)

PROBER_MANIFEST=$(mktemp)
cat <<EOF >$PROBER_MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: placeholder
spec:
  restartPolicy: OnFailure
  containers:
  - image: weibeld/k8s-conncheck-prober
    name: k8s-conncheck-prober
    imagePullPolicy: Always
    #command: ["sleep", "infinity"]
    env:
      - name: PODS
        value: '$PODS'
      - name: NODES
        value: '$NODES'
      - name: SELF_IP
        valueFrom:
          fieldRef:
           fieldPath: status.podIP
      - name: SELF_POD
        valueFrom:
          fieldRef:
            fieldPath: metadata.name
      - name: SELF_NODE
        valueFrom:
          fieldRef:
           fieldPath: spec.nodeName
EOF

for run in pod_network host_network; do

  case "$run" in
    pod_network)
      pod_name=conncheck-prober
      is_host_network=false
      msg="Pod network"
      ;;
    host_network)
      pod_name=conncheck-prober-host
      is_host_network=true
      msg="host network"
      ;;
  esac

  # Adapt prober Pod manifest
  yq write -i "$PROBER_MANIFEST" metadata.name "$pod_name"
  yq write -i "$PROBER_MANIFEST" spec.hostNetwork "$is_host_network"

  # Create prober Pod
  log "Creating Pod \"$pod_name\" in $msg..."
  mykubectl create -f "$PROBER_MANIFEST" >/dev/null

  # Wait until prober Pod is running
  while [[ $(mykubectl get pod "$pod_name" -o jsonpath='{.status.phase}') != Running ]]; do sleep 1; done

  # Query details of prober Pod
  tmp=$(mykubectl get pod "$pod_name" -o json | jq -r '[.status.podIP,.spec.nodeName,.status.hostIP] | join(",")')
  pod_ip=$(echo "$tmp" | cut -d , -f 1)
  node_name=$(echo "$tmp" | cut -d , -f 2)
  node_ip=$(echo "$tmp" | cut -d , -f 3)
  log "Running checks on Pod \"$pod_name\" $pod_ip (running on node \"$node_name\" $node_ip)"

  # Invoke 'init' callback
  init "$pod_name" "$pod_ip" "$node_name" "$node_ip"

  # Read test results from prober Pod and invoke 'process_test_result' callbacks
  mykubectl logs -f "$pod_name" | while read -r line; do 
    [[ "$line" = EOF ]] && break
    process_test_result "$line"
  done

  # Invoke 'finalize' callback
  finalize

  # Delete prober Pod
  log "Deleting Pod \"$pod_name\""
  mykubectl delete pod "$pod_name" --wait=false >/dev/null

done
