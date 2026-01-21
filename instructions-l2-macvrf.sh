#!/bin/bash

export KUBECONFIG=/home/surya/ovn.conf

# External FRR IP (on KIND network)
FRR_IP=$(docker inspect frr --format '{{range .NetworkSettings.Networks}}{{if eq .NetworkID "'$(docker network inspect kind -f '{{.Id}}')'"}}{{.IPAddress}}{{end}}{{end}}')
echo "External FRR IP: $FRR_IP"

# MAC-VRF parameters
VNI=10100
VID=100  # VID = VNI - 10000
CUDN_SUBNET="10.100.0.0/16"
AGNHOST_IP="10.100.0.250"

function run_cmd() {
    echo "# $@"
    "$@"
    read
}

function header() {
    echo ""
    echo "========================================================================================="
    echo "    $@"
    echo "========================================================================================="
    read
}

# MAC-VRF Manual EVPN Setup for Layer2 CUDN

header "Step 1: Setup EVPN Bridge on External FRR"

run_cmd docker exec frr ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
run_cmd docker exec frr ip link set br0 addrgenmode none

run_cmd docker exec frr ip link add vxlan0 type vxlan dstport 4789 local $FRR_IP nolearning external vnifilter
run_cmd docker exec frr ip link set vxlan0 addrgenmode none

run_cmd docker exec frr ip link set vxlan0 master br0

run_cmd docker exec frr ip link set br0 up
run_cmd docker exec frr ip link set vxlan0 up

run_cmd docker exec frr bridge link set dev vxlan0 vlan_tunnel on neigh_suppress on learning off

header "Step 2: Configure MAC-VRF VLAN/VNI mapping on External FRR"

run_cmd docker exec frr bridge vlan add dev br0 vid $VID self
run_cmd docker exec frr bridge vlan add dev vxlan0 vid $VID
run_cmd docker exec frr bridge vni add dev vxlan0 vni $VNI
run_cmd docker exec frr bridge vlan add dev vxlan0 vid $VID tunnel_info id $VNI

header "Step 3: Add EVPN BGP Config on External FRR"

# Get node IPs dynamically
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
echo "Node IPs: $NODE_IPS"

# Build neighbor activate commands
NEIGHBOR_CMDS=""
for ip in $NODE_IPS; do
  NEIGHBOR_CMDS="$NEIGHBOR_CMDS -c \"neighbor $ip activate\""
done

# Run vtysh with dynamic neighbors - MAC-VRF only needs l2vpn evpn in default VRF
eval "docker exec frr vtysh \
  -c 'configure terminal' \
  -c 'router bgp 64512' \
  -c 'address-family l2vpn evpn' \
  -c 'advertise-all-vni' \
  $NEIGHBOR_CMDS \
  -c 'exit-address-family' \
  -c 'end'"
read

header "Step 4: Create Agnhost Connected to MAC-VRF (same L2 subnet)"

# Create agnhost container with no network initially
run_cmd docker run -d --name agnhost-macvrf --network none --cap-add=NET_ADMIN \
  registry.k8s.io/e2e-test-images/agnhost:2.45 netexec --http-port=8080

# Create veth pair to connect agnhost to FRR's bridge
AGNHOST_PID=$(docker inspect --format '{{.State.Pid}}' agnhost-macvrf)
FRR_PID=$(docker inspect --format '{{.State.Pid}}' frr)
echo "Agnhost PID: $AGNHOST_PID, FRR PID: $FRR_PID"
read

# Create veth pair using netshoot helper
run_cmd docker run --rm --privileged --pid=host --network=host nicolaka/netshoot ip link add agnhosttemp type veth peer name frrtemp
run_cmd docker run --rm --privileged --pid=host --network=host nicolaka/netshoot ip link set agnhosttemp netns $AGNHOST_PID
run_cmd docker run --rm --privileged --pid=host --network=host nicolaka/netshoot ip link set frrtemp netns $FRR_PID

# Rename interfaces inside containers
run_cmd docker exec agnhost-macvrf ip link set agnhosttemp name eth0
run_cmd docker exec frr ip link set frrtemp name macvrf0

# Bring up interfaces
run_cmd docker exec agnhost-macvrf ip link set eth0 up
run_cmd docker exec frr ip link set macvrf0 up

# Add FRR's interface to bridge as access port for the MAC-VRF VLAN
run_cmd docker exec frr ip link set macvrf0 master br0
run_cmd docker exec frr bridge vlan add dev macvrf0 vid $VID pvid untagged

# Configure agnhost IP (on same subnet as CUDN)
# Note: Linux automatically adds route for 10.100.0.0/16 when we assign the /16 IP
run_cmd docker exec agnhost-macvrf ip addr add ${AGNHOST_IP}/16 dev eth0

header "Verify bridge config on External FRR"

run_cmd docker exec frr bridge vlan show
run_cmd docker exec frr bridge vni show

header "Step 5: Setup EVPN Bridge on Cluster Nodes"

kubectl get pods -l app=ovnkube-node -n ovn-kubernetes -o custom-columns=POD:.metadata.name,NODEIP:.status.podIP --no-headers | while read POD NODEIP; do
  echo "=== Configuring $POD (IP: $NODEIP) ==="
  kubectl exec -n ovn-kubernetes $POD -c ovnkube-controller -- /bin/sh -c "
    ip link del br0 2>/dev/null || true
    ip link del vxlan0 2>/dev/null || true
    
    ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
    ip link set br0 addrgenmode none
    
    ip link add vxlan0 type vxlan dstport 4789 local $NODEIP nolearning external vnifilter
    ip link set vxlan0 addrgenmode none master br0
    
    ip link set br0 up
    ip link set vxlan0 up
    
    bridge link set dev vxlan0 vlan_tunnel on neigh_suppress on learning off
    
    echo 'EVPN bridge setup complete'
  "
done
read

header "Step 6: Create VTEP CR"

cat <<EOF | kubectl apply -f -
apiVersion: k8s.ovn.org/v1
kind: VTEP
metadata:
  name: evpn-vtep
spec:
  cidrs:
  - 100.64.0.0/24
  mode: Managed
EOF
read

echo "Waiting for VTEP IPs to be assigned..."
sleep 5
run_cmd kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations.k8s\.ovn\.org/evpn-vtep}{"\n"}{end}'

header "Step 7: Create Namespace with UDN Label"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: evpn-l2-test
  labels:
    k8s.ovn.org/primary-user-defined-network: ""
EOF
read

header "Step 8: Create Layer2 CUDN with EVPN Transport (MAC-VRF)"

cat <<EOF | kubectl apply -f -
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: evpn-l2-test
  labels:
    network: evpn-l2-test
    macvrf: "true"
spec:
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: evpn-l2-test
  network:
    topology: Layer2
    layer2:
      role: Primary
      subnets:
      - ${CUDN_SUBNET}
    transport: EVPN
    evpn:
      vtep: evpn-vtep
      macVRF:
        vni: ${VNI}
EOF
read

run_cmd kubectl get clusteruserdefinednetwork evpn-l2-test -o yaml

header "Step 9: Create FRRConfiguration"

cat <<EOF | kubectl apply -f -
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: evpn-l2-test
  namespace: frr-k8s-system
  labels:
    network: evpn-l2-test
spec:
  bgp:
    routers:
    - asn: 64512
      neighbors:
      - address: $FRR_IP
        asn: 64512
        disableMP: true
        toReceive:
          allowed:
            mode: filtered
            prefixes:
            - prefix: 10.100.0.0/16
              le: 32
  # NOTE: rawConfig removed - Step 12 handles the EVPN config via vtysh
  # In a fully automated setup, OVN-K should generate this from CUDN spec
EOF
read

header "Step 10: Create RouteAdvertisements"

cat <<EOF | kubectl apply -f -
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: evpn-l2-test
spec:
  nodeSelector: {}
  networkSelectors:
  - networkSelectionType: ClusterUserDefinedNetworks
    clusterUserDefinedNetworkSelector:
      networkSelector:
        matchLabels:
          network: evpn-l2-test
  frrConfigurationSelector:
    matchLabels:
      network: evpn-l2-test
  advertisements:
  - PodNetwork
EOF
read

header "Step 11: Configure Cluster MAC-VRF (Connect OVS to Linux Bridge)"

# Get network name with dots (OVN-K8s replaces dashes with dots)
NETWORK_NAME="evpn-l2-test"
NETWORK_DOTTED=${NETWORK_NAME//-/.}
OVN_SWITCH="cluster_udn_${NETWORK_DOTTED}_ovn_layer2_switch"
OVN_PORT="cluster_udn_${NETWORK_DOTTED}_evpn_port"

echo "OVN Switch: $OVN_SWITCH"
echo "OVN Port: $OVN_PORT"
read

kubectl get pods -l app=ovnkube-node -n ovn-kubernetes -o custom-columns=POD:.metadata.name --no-headers | while read POD; do
  echo "=== Configuring MAC-VRF on $POD ==="
  
  kubectl exec -n ovn-kubernetes $POD -c ovnkube-controller -- /bin/sh -c "
    # Setup VLAN/VNI mapping
    bridge vlan add dev br0 vid $VID self
    bridge vlan add dev vxlan0 vid $VID
    bridge vni add dev vxlan0 vni $VNI
    bridge vlan add dev vxlan0 vid $VID tunnel_info id $VNI
    
    # Create OVS internal port and connect to Linux bridge
    ovs-vsctl --if-exists del-port br-int evpn${VNI}
    ovs-vsctl add-port br-int evpn${VNI} -- set interface evpn${VNI} type=internal external-ids:iface-id=${OVN_PORT}
    ip link set evpn${VNI} master br0
    bridge vlan add dev evpn${VNI} vid $VID pvid untagged
    ip link set evpn${VNI} up
    
    # Add port to OVN logical switch
    ovn-nbctl --if-exists lsp-del ${OVN_PORT}
    ovn-nbctl lsp-add $OVN_SWITCH ${OVN_PORT}
    ovn-nbctl lsp-set-addresses ${OVN_PORT} unknown
    
    echo 'MAC-VRF OVS integration configured'
  "
done
read

header "Step 12: Configure frr-k8s for EVPN MAC-VRF"

kubectl get pods -n frr-k8s-system -l app=frr-k8s -o custom-columns=POD:.metadata.name --no-headers | while read FRR_POD; do
  echo "=== Configuring frr-k8s $FRR_POD ==="
  
  kubectl exec -n frr-k8s-system $FRR_POD -c frr -- vtysh \
    -c "configure terminal" \
    -c "router bgp 64512" \
    -c "address-family l2vpn evpn" \
    -c "neighbor $FRR_IP activate" \
    -c "advertise-all-vni" \
    -c "exit-address-family" \
    -c "end"
done
read

header "Step 13: Create Test Pod"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: evpn-l2-test
spec:
  containers:
  - name: agnhost
    image: registry.k8s.io/e2e-test-images/agnhost:2.45
    command: ["sleep", "infinity"]
EOF
read

echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/test-pod -n evpn-l2-test --timeout=120s

# Get UDN pod IP from annotation (not status.podIP which is default network)
POD_IP=$(kubectl get pod test-pod -n evpn-l2-test -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | jq -r '.["evpn-l2-test/evpn-l2-test"].ip_addresses[0]' | cut -d'/' -f1)
echo "Test pod UDN IP: $POD_IP"
read

header "Step 14: Verify Connectivity (L2 - same subnet)"

echo "=== Testing pod -> agnhost (${AGNHOST_IP}) via L2 ==="
run_cmd kubectl exec -n evpn-l2-test test-pod -- ping -c 3 ${AGNHOST_IP}

echo "=== Testing pod -> agnhost HTTP ==="
run_cmd kubectl exec -n evpn-l2-test test-pod -- curl -s --max-time 5 http://${AGNHOST_IP}:8080/hostname

POD_IP=$(kubectl get pod test-pod -n evpn-l2-test -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | jq -r '.["evpn-l2-test/evpn-l2-test"].ip_addresses[0]' | cut -d'/' -f1)
echo "=== Testing agnhost -> pod ($POD_IP) via L2 ==="
run_cmd docker exec agnhost-macvrf ping -c 3 $POD_IP

header "EVPN MAC-VRF (Layer2) Test Complete!"

echo "Debugging Commands:"
echo "  docker exec frr vtysh -c 'show bgp l2vpn evpn'"
echo "  docker exec frr vtysh -c 'show bgp l2vpn evpn route type 2'"
echo "  docker exec frr vtysh -c 'show bgp l2vpn evpn route type 3'"
echo "  docker exec frr bridge fdb show"
echo "  docker exec frr bridge vlan show"
echo "  kubectl exec -n frr-k8s-system \$(kubectl get pods -n frr-k8s-system -l app=frr-k8s -o jsonpath='{.items[0].metadata.name}') -c frr -- vtysh -c 'show bgp summary'"

