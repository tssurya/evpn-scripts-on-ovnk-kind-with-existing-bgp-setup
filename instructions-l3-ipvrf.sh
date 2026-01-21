#!/bin/bash

# =============================================================================
# EVPN Layer3 IP-VRF Manual Test Script
# =============================================================================
#
# This script sets up a realistic EVPN IP-VRF scenario between a KIND cluster
# and an external FRR router.
#
# REAL-WORLD CONTEXT:
# -------------------
# The external FRR setup here is very realistic - it mirrors what you'd see on
# production leaf switches in a data center fabric:
#
# | Our Setup              | Production Equivalent                          |
# |------------------------|------------------------------------------------|
# | FRR container          | Cumulus/NVIDIA switch (literally runs FRR!)   |
# | br0 + vxlan0           | ToR/Leaf switch EVPN bridge                   |
# | vrf202                 | Tenant VRF on leaf                            |
# | BGP EVPN config        | Standard DC fabric config                     |
#
# Cumulus Linux switches use this exact same FRR config syntax - our vtysh
# commands would work verbatim on a Cumulus leaf switch. SONiC also uses FRR.
#
# SIMPLIFICATIONS IN THIS LAB:
# ----------------------------
# 1. Single FRR as both route-reflector AND VTEP
#    - In production: spines are RRs, leaves are VTEPs
# 2. No underlay routing
#    - In production: OSPF/ISIS for loopback reachability between VTEPs
# 3. No redundancy
#    - In production: MLAG, EVPN multihoming, multiple spines
#
# REAL DC FABRIC TOPOLOGY:
#
#         [Spine RRs]          <- BGP EVPN route reflectors only
#          /       \
#     [Leaf1]    [Leaf2]       <- VTEPs with VXLAN bridges, VRFs
#        |          |
#    [Servers]  [Servers]
#
# =============================================================================

export KUBECONFIG=/home/surya/ovn.conf

# External FRR IP (on KIND network)
FRR_IP=$(docker inspect frr --format '{{range .NetworkSettings.Networks}}{{if eq .NetworkID "'$(docker network inspect kind -f '{{.Id}}')'"}}{{.IPAddress}}{{end}}{{end}}')
echo "External FRR IP: $FRR_IP"

# IP-VRF parameters
VNI=20102
VID=202  # VID = VNI - 20000 + 100
VRF_NAME="vrf${VID}"

# Agnhost network (external to cluster, connected via IP-VRF)
AGNHOST_NETWORK="agnhost-ipvrf-net"
AGNHOST_SUBNET="172.27.102.0/24"
# IPs will be assigned by Docker and discovered dynamically
echo "IP-VRF: VNI=$VNI, VID=$VID"
echo "Agnhost Network: $AGNHOST_NETWORK, Subnet: $AGNHOST_SUBNET"

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

# IP-VRF Manual EVPN Setup

header "Step 1: Setup EVPN Bridge on External FRR"

run_cmd docker exec frr ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
run_cmd docker exec frr ip link set br0 addrgenmode none

run_cmd docker exec frr ip link add vxlan0 type vxlan dstport 4789 local $FRR_IP nolearning external vnifilter
run_cmd docker exec frr ip link set vxlan0 addrgenmode none

run_cmd docker exec frr ip link set vxlan0 master br0

run_cmd docker exec frr ip link set br0 up
run_cmd docker exec frr ip link set vxlan0 up

run_cmd docker exec frr bridge link set dev vxlan0 vlan_tunnel on neigh_suppress on learning off

header "Step 2: Configure IP-VRF on External FRR"

run_cmd docker exec frr ip link add $VRF_NAME type vrf table $VNI
run_cmd docker exec frr ip link set $VRF_NAME up

run_cmd docker exec frr bridge vlan add dev br0 vid $VID self
run_cmd docker exec frr bridge vlan add dev vxlan0 vid $VID
run_cmd docker exec frr bridge vni add dev vxlan0 vni $VNI
run_cmd docker exec frr bridge vlan add dev vxlan0 vid $VID tunnel_info id $VNI

run_cmd docker exec frr ip link add br0.$VID link br0 type vlan id $VID
run_cmd docker exec frr ip link set br0.$VID master $VRF_NAME
run_cmd docker exec frr ip link set br0.$VID up

header "Step 3: Add EVPN BGP Config on External FRR"

# Get node IPs dynamically
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
echo "Node IPs: $NODE_IPS"

# Build neighbor activate commands
NEIGHBOR_CMDS=""
for ip in $NODE_IPS; do
  NEIGHBOR_CMDS="$NEIGHBOR_CMDS -c \"neighbor $ip activate\""
done

# Run vtysh with dynamic neighbors
eval "docker exec frr vtysh \
  -c 'configure terminal' \
  -c 'router bgp 64512' \
  -c 'address-family l2vpn evpn' \
  -c 'advertise-all-vni' \
  $NEIGHBOR_CMDS \
  -c 'exit-address-family' \
  -c 'exit' \
  -c \"vrf $VRF_NAME\" \
  -c \"vni $VNI\" \
  -c 'exit-vrf' \
  -c \"router bgp 64512 vrf $VRF_NAME\" \
  -c 'address-family ipv4 unicast' \
  -c 'redistribute connected' \
  -c 'exit-address-family' \
  -c 'address-family l2vpn evpn' \
  -c \"rd 64512:$VNI\" \
  -c \"no route-target import 64512:$VNI\" \
  -c \"route-target import 64512:$VNI\" \
  -c \"no route-target export 64512:$VNI\" \
  -c \"route-target export 64512:$VNI\" \
  -c 'advertise ipv4 unicast' \
  -c 'exit-address-family' \
  -c 'end'"
read

header "Step 4: Create Agnhost Connected to VRF"

# Create network with specific subnet
run_cmd docker network create --subnet=${AGNHOST_SUBNET} ${AGNHOST_NETWORK}

# Create agnhost (Docker assigns IP from subnet, NET_ADMIN for route config)
run_cmd docker run -d --name agnhost-ipvrf --network ${AGNHOST_NETWORK} --cap-add=NET_ADMIN \
  registry.k8s.io/e2e-test-images/agnhost:2.45 netexec --http-port=8080

# Connect FRR to the network (Docker assigns IP from subnet)
run_cmd docker network connect ${AGNHOST_NETWORK} frr

# Discover assigned IPs
AGNHOST_IP=$(docker inspect agnhost-ipvrf --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
FRR_GW_IP=$(docker inspect frr --format '{{index .NetworkSettings.Networks "'${AGNHOST_NETWORK}'" "IPAddress"}}')
echo "Agnhost IP: $AGNHOST_IP"
echo "FRR Gateway IP: $FRR_GW_IP"
read

# Find FRR's interface for this network and put it in the VRF
FRR_IFACE=$(docker exec frr ip -j addr show | jq -r '.[] | select(.addr_info[]?.local == "'${FRR_GW_IP}'") | .ifname')
echo "FRR interface for agnhost: $FRR_IFACE"
read

run_cmd docker exec frr ip link set $FRR_IFACE master $VRF_NAME
run_cmd docker exec frr ip link set $FRR_IFACE up

# Set agnhost default route via FRR (Docker's default gateway isn't our FRR)
run_cmd docker exec agnhost-ipvrf ip route del default 2>/dev/null || true
run_cmd docker exec agnhost-ipvrf ip route add default via ${FRR_GW_IP} dev eth0

header "Verify agnhost is reachable from FRR's VRF"

run_cmd docker exec frr ip route show vrf $VRF_NAME
run_cmd docker exec frr ping -c 2 -I $VRF_NAME ${AGNHOST_IP}

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

header "Step 8: Create Namespace with UDN Label"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: evpn-l3-test
  labels:
    k8s.ovn.org/primary-user-defined-network: ""
EOF
read

header "Step 9: Create CUDN with EVPN Transport"

cat <<EOF | kubectl apply -f -
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: evpn-l3-test
  labels:
    network: evpn-l3-test
    ipvrf: "true"
spec:
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: evpn-l3-test
  network:
    topology: Layer3
    layer3:
      role: Primary
      subnets:
      - cidr: 10.102.0.0/16
    transport: EVPN
    evpn:
      vtep: evpn-vtep
      ipVRF:
        vni: ${VNI}
EOF
read

run_cmd kubectl get clusteruserdefinednetwork evpn-l3-test -o yaml

header "Step 10: Create FRRConfiguration"

cat <<EOF | kubectl apply -f -
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: evpn-l3-test
  namespace: frr-k8s-system
  labels:
    network: evpn-l3-test
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
            - prefix: ${AGNHOST_SUBNET}
  # NOTE: rawConfig removed - Step 13 handles the EVPN VRF config via vtysh
  # In a fully automated setup, OVN-K should generate this from CUDN spec
EOF
read

header "Step 11: Create RouteAdvertisements"

cat <<EOF | kubectl apply -f -
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: evpn-l3-test
spec:
  nodeSelector: {}
  networkSelectors:
  - networkSelectionType: ClusterUserDefinedNetworks
    clusterUserDefinedNetworkSelector:
      networkSelector:
        matchLabels:
          network: evpn-l3-test
  frrConfigurationSelector:
    matchLabels:
      network: evpn-l3-test
  advertisements:
  - PodNetwork
EOF
read

header "Step 12: Configure Cluster IP-VRF (Connect SVI to OVN-K8s VRF)"

NETWORK_ID=$(kubectl get net-attach-def -n evpn-l3-test evpn-l3-test -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/network-id}' 2>/dev/null)
echo "Network ID: $NETWORK_ID"
read

kubectl get pods -l app=ovnkube-node -n ovn-kubernetes -o custom-columns=POD:.metadata.name --no-headers | while read POD; do
  echo "=== Configuring IP-VRF on $POD ==="
  
  VRFNAME=$(kubectl exec -n ovn-kubernetes $POD -c ovnkube-controller -- ip -o link show ovn-k8s-mp${NETWORK_ID} 2>/dev/null | grep -oP 'master \K[^ ]+' || echo "mp${NETWORK_ID}-udn-vrf")
  echo "  VRF: $VRFNAME"
  
  kubectl exec -n ovn-kubernetes $POD -c ovnkube-controller -- /bin/sh -c "
    bridge vlan add dev br0 vid $VID self
    bridge vlan add dev vxlan0 vid $VID
    bridge vni add dev vxlan0 vni $VNI
    bridge vlan add dev vxlan0 vid $VID tunnel_info id $VNI
    
    ip link del br0.$VID 2>/dev/null || true
    ip link add br0.$VID link br0 type vlan id $VID
    ip link set br0.$VID addrgenmode none
    ip link set br0.$VID master $VRFNAME
    ip link set br0.$VID up
    
    echo 'IP-VRF SVI configured'
  "
done
read

header "Step 13: Configure frr-k8s VRF for EVPN Type-5"

# =============================================================================
# IMPORTANT: Understanding the route-target timing issue
# =============================================================================
#
# WHY WE USE "no route-target import" BEFORE "route-target import":
#
# 1. WHAT ALREADY EXISTS:
#    When Step 11 (RouteAdvertisements) is applied, frr-k8s automatically creates:
#      router bgp 64512 vrf evpn-l3-test
#        address-family ipv4 unicast
#          redistribute connected
#        exit-address-family
#      exit
#    This is needed for frr-k8s to advertise pod routes from the VRF.
#
# 2. THE TIMING PROBLEM:
#    - BGP session with external FRR establishes (from Step 10 FRRConfiguration)
#    - External FRR sends Type-5 route for 172.27.102.0/24 with RT 64512:20102
#    - Route arrives in frr-k8s global BGP l2vpn evpn table
#    - FRR checks: "Does any VRF want to import RT 64512:20102?" → NO
#      (because this step hasn't run yet - no route-target import configured)
#    - Route sits in global table, NOT imported into VRF
#
# 3. THE PROBLEM WITH JUST ADDING route-target:
#    - This step runs and adds "route-target import 64512:20102"
#    - BUT FRR does NOT retroactively re-check already-received routes
#    - The 172.27.102.0/24 route remains stuck in global table
#    - VRF routing table stays empty → connectivity fails
#
# 4. THE FIX:
#    - First apply the base config (works on fresh install)
#    - Then do "no route-target" / "route-target" to force re-evaluation
#    - The re-evaluation step is in a separate call so it can fail silently on fresh installs
#
# This is a FRR behavior quirk, not a cleanup issue. Even with perfect cleanup,
# this timing issue can occur because routes arrive before RT config is applied.
# =============================================================================

kubectl get pods -n frr-k8s-system -l app=frr-k8s -o custom-columns=POD:.metadata.name --no-headers | while read FRR_POD; do
  echo "=== Configuring frr-k8s $FRR_POD ==="
  
  # Step 1: Apply base EVPN config (works on fresh install)
  kubectl exec -n frr-k8s-system $FRR_POD -c frr -- vtysh \
    -c "configure terminal" \
    -c "vrf evpn-l3-test" \
    -c "vni $VNI" \
    -c "exit-vrf" \
    -c "router bgp 64512" \
    -c "address-family l2vpn evpn" \
    -c "neighbor $FRR_IP activate" \
    -c "advertise-all-vni" \
    -c "exit-address-family" \
    -c "exit" \
    -c "router bgp 64512 vrf evpn-l3-test" \
    -c "address-family ipv4 unicast" \
    -c "redistribute connected" \
    -c "exit-address-family" \
    -c "address-family l2vpn evpn" \
    -c "rd 64512:$VNI" \
    -c "route-target import 64512:$VNI" \
    -c "route-target export 64512:$VNI" \
    -c "advertise ipv4 unicast" \
    -c "exit-address-family" \
    -c "end"
  
  # Small delay to let BGP routes arrive and FRR process the config
  # seeing some pretty nasty races
  sleep 10
  
  # Step 2: Force route re-evaluation by toggling route-targets
  # This handles the timing issue where routes arrived before RT was configured
  # May fail on fresh install (no RT to remove) - that's OK, ignore errors
  kubectl exec -n frr-k8s-system $FRR_POD -c frr -- vtysh \
    -c "configure terminal" \
    -c "router bgp 64512 vrf evpn-l3-test" \
    -c "address-family l2vpn evpn" \
    -c "no route-target import 64512:$VNI" \
    -c "route-target import 64512:$VNI" \
    -c "no route-target export 64512:$VNI" \
    -c "route-target export 64512:$VNI" \
    -c "end" 2>/dev/null || echo "  (Route re-evaluation skipped - fresh install)"
done
read

header "Step 14: Create Test Pod"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: evpn-l3-test
spec:
  containers:
  - name: agnhost
    image: registry.k8s.io/e2e-test-images/agnhost:2.45
    command: ["sleep", "infinity"]
EOF
read

echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/test-pod -n evpn-l3-test --timeout=120s

# Get UDN pod IP from annotation (not status.podIP which is default network)
POD_IP=$(kubectl get pod test-pod -n evpn-l3-test -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | jq -r '.["evpn-l3-test/evpn-l3-test"].ip_addresses[0]' | cut -d'/' -f1)
echo "Test pod UDN IP: $POD_IP"
read

header "Step 15: Verify Connectivity"

echo "=== Testing pod -> agnhost (${AGNHOST_IP}) ==="
run_cmd kubectl exec -n evpn-l3-test test-pod -- curl -s --max-time 5 http://${AGNHOST_IP}:8080/hostname

echo "=== Testing agnhost -> pod ($POD_IP) ==="
run_cmd docker exec agnhost-ipvrf ping -c 3 $POD_IP

header "EVPN IP-VRF Test Complete!"

echo "Debugging Commands:"
echo "  docker exec frr vtysh -c 'show bgp l2vpn evpn'"
echo "  docker exec frr vtysh -c 'show bgp l2vpn evpn route type 5'"
echo "  docker exec frr ip route show vrf $VRF_NAME"
echo "  kubectl exec -n frr-k8s-system \$(kubectl get pods -n frr-k8s-system -l app=frr-k8s -o jsonpath='{.items[0].metadata.name}') -c frr -- vtysh -c 'show bgp summary'"
