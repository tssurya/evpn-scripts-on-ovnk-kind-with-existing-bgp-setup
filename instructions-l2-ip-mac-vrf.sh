#!/bin/bash

# =============================================================================
# EVPN Layer2 CUDN with Both IP-VRF and MAC-VRF
# =============================================================================
#
# This is the most complete EVPN scenario - a Layer2 CUDN that has:
# - MAC-VRF: Extends L2 domain to external hosts (Type-2/Type-3 routes)
# - IP-VRF: Provides L3 routing to external networks (Type-5 routes)
#
# Architecture (from OKEP):
#
#   Pod(s) ──> OVN Logical Switch ──> OVS br-int
#                                         │
#                    ┌────────────────────┴────────────────────┐
#                    │ (OVS internal port for MAC-VRF)         │
#                    ▼                                         │
#   ┌─────────────────────────────────┐                        │
#   │  br0 (SVD - Single VXLAN Device)│                        │
#   │  VLAN 100 ←→ VNI 10100 (MAC-VRF)│                        │
#   │  VLAN 202 ←→ VNI 20102 (IP-VRF) │                        │
#   └─────────────────────────────────┘                        │
#        │                    │                                │
#        │                    ▼                                │
#        │         ┌──────────────────┐    ┌───────────────────┴───┐
#        │         │ br0.202 (SVI)    │───>│ UDN VRF (evpn-l2-test)│
#        │         └──────────────────┘    │ + ovn-k8s-mpX         │
#        ▼                                 └───────────────────────┘
#   ┌──────────┐
#   │ vxlan0   │ ←── VTEP (VXLAN tunnel endpoint)
#   └──────────┘
#        │
#        ▼
#   External FRR / DC Fabric
#
# Test Targets:
# - MAC-VRF agnhost: 10.100.0.250 (same L2 subnet as CUDN)
# - IP-VRF agnhost: 172.27.102.x (different L3 subnet, routed)
#
# =============================================================================

export KUBECONFIG=/home/surya/ovn.conf

# External FRR IP (on KIND network)
FRR_IP=$(docker inspect frr --format '{{range .NetworkSettings.Networks}}{{if eq .NetworkID "'$(docker network inspect kind -f '{{.Id}}')'"}}{{.IPAddress}}{{end}}{{end}}')
echo "External FRR IP: $FRR_IP"

# MAC-VRF parameters (for L2 extension)
MACVRF_VNI=10100
MACVRF_VID=100
CUDN_SUBNET="10.100.0.0/16"
MACVRF_AGNHOST_IP="10.100.0.250"

# IP-VRF parameters (for L3 routing)
IPVRF_VNI=20102
IPVRF_VID=202
IPVRF_VRF_NAME="vrf${IPVRF_VID}"
IPVRF_AGNHOST_NETWORK="agnhost-ipvrf-net"
IPVRF_AGNHOST_SUBNET="172.27.102.0/24"

echo "MAC-VRF: VNI=$MACVRF_VNI, VID=$MACVRF_VID, Subnet=$CUDN_SUBNET"
echo "IP-VRF: VNI=$IPVRF_VNI, VID=$IPVRF_VID, Subnet=$IPVRF_AGNHOST_SUBNET"

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

# =============================================================================
# EXTERNAL FRR SETUP
# =============================================================================

header "Step 1: Setup EVPN Bridge on External FRR"

run_cmd docker exec frr ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
run_cmd docker exec frr ip link set br0 addrgenmode none

run_cmd docker exec frr ip link add vxlan0 type vxlan dstport 4789 local $FRR_IP nolearning external vnifilter
run_cmd docker exec frr ip link set vxlan0 addrgenmode none

run_cmd docker exec frr ip link set vxlan0 master br0

run_cmd docker exec frr ip link set br0 up
run_cmd docker exec frr ip link set vxlan0 up

run_cmd docker exec frr bridge link set dev vxlan0 vlan_tunnel on neigh_suppress on learning off

header "Step 2: Configure MAC-VRF on External FRR"

# MAC-VRF VLAN/VNI mapping
run_cmd docker exec frr bridge vlan add dev br0 vid $MACVRF_VID self
run_cmd docker exec frr bridge vlan add dev vxlan0 vid $MACVRF_VID
run_cmd docker exec frr bridge vni add dev vxlan0 vni $MACVRF_VNI
run_cmd docker exec frr bridge vlan add dev vxlan0 vid $MACVRF_VID tunnel_info id $MACVRF_VNI

header "Step 3: Configure IP-VRF on External FRR"

# IP-VRF Linux VRF
run_cmd docker exec frr ip link add $IPVRF_VRF_NAME type vrf table $IPVRF_VNI
run_cmd docker exec frr ip link set $IPVRF_VRF_NAME up

# IP-VRF VLAN/VNI mapping
run_cmd docker exec frr bridge vlan add dev br0 vid $IPVRF_VID self
run_cmd docker exec frr bridge vlan add dev vxlan0 vid $IPVRF_VID
run_cmd docker exec frr bridge vni add dev vxlan0 vni $IPVRF_VNI
run_cmd docker exec frr bridge vlan add dev vxlan0 vid $IPVRF_VID tunnel_info id $IPVRF_VNI

# IP-VRF SVI
run_cmd docker exec frr ip link add br0.$IPVRF_VID link br0 type vlan id $IPVRF_VID
run_cmd docker exec frr ip link set br0.$IPVRF_VID master $IPVRF_VRF_NAME
run_cmd docker exec frr ip link set br0.$IPVRF_VID up

header "Step 4: Add EVPN BGP Config on External FRR"

# Get node IPs dynamically
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
echo "Node IPs: $NODE_IPS"

# Build neighbor activate commands
NEIGHBOR_CMDS=""
for ip in $NODE_IPS; do
  NEIGHBOR_CMDS="$NEIGHBOR_CMDS -c \"neighbor $ip activate\""
done

# Run vtysh with dynamic neighbors - both MAC-VRF and IP-VRF config
eval "docker exec frr vtysh \
  -c 'configure terminal' \
  -c 'router bgp 64512' \
  -c 'address-family l2vpn evpn' \
  -c 'advertise-all-vni' \
  $NEIGHBOR_CMDS \
  -c 'exit-address-family' \
  -c 'exit' \
  -c \"vrf $IPVRF_VRF_NAME\" \
  -c \"vni $IPVRF_VNI\" \
  -c 'exit-vrf' \
  -c \"router bgp 64512 vrf $IPVRF_VRF_NAME\" \
  -c 'address-family ipv4 unicast' \
  -c 'redistribute connected' \
  -c 'exit-address-family' \
  -c 'address-family l2vpn evpn' \
  -c \"rd 64512:$IPVRF_VNI\" \
  -c \"route-target import 64512:$IPVRF_VNI\" \
  -c \"route-target export 64512:$IPVRF_VNI\" \
  -c 'advertise ipv4 unicast' \
  -c 'exit-address-family' \
  -c 'end'"
read

header "Step 5: Create MAC-VRF Agnhost (L2 - same subnet)"

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
run_cmd docker exec frr bridge vlan add dev macvrf0 vid $MACVRF_VID pvid untagged

# Configure agnhost IP (on same subnet as CUDN)
run_cmd docker exec agnhost-macvrf ip addr add ${MACVRF_AGNHOST_IP}/16 dev eth0

header "Step 6: Create IP-VRF Agnhost (L3 - different subnet)"

# Create network with specific subnet
run_cmd docker network create --subnet=${IPVRF_AGNHOST_SUBNET} ${IPVRF_AGNHOST_NETWORK}

# Create agnhost (Docker assigns IP from subnet, NET_ADMIN for route config)
run_cmd docker run -d --name agnhost-ipvrf --network ${IPVRF_AGNHOST_NETWORK} --cap-add=NET_ADMIN \
  registry.k8s.io/e2e-test-images/agnhost:2.45 netexec --http-port=8080

# Connect FRR to the network (Docker assigns IP from subnet)
run_cmd docker network connect ${IPVRF_AGNHOST_NETWORK} frr

# Discover assigned IPs
IPVRF_AGNHOST_IP=$(docker inspect agnhost-ipvrf --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
FRR_GW_IP=$(docker inspect frr --format '{{index .NetworkSettings.Networks "'${IPVRF_AGNHOST_NETWORK}'" "IPAddress"}}')
echo "IP-VRF Agnhost IP: $IPVRF_AGNHOST_IP"
echo "FRR Gateway IP: $FRR_GW_IP"
read

# Find FRR's interface for this network and put it in the VRF
FRR_IFACE=$(docker exec frr ip -j addr show | jq -r '.[] | select(.addr_info[]?.local == "'${FRR_GW_IP}'") | .ifname')
echo "FRR interface for agnhost: $FRR_IFACE"
read

run_cmd docker exec frr ip link set $FRR_IFACE master $IPVRF_VRF_NAME
run_cmd docker exec frr ip link set $FRR_IFACE up

# Set agnhost default route via FRR
run_cmd docker exec agnhost-ipvrf ip route del default 2>/dev/null || true
run_cmd docker exec agnhost-ipvrf ip route add default via ${FRR_GW_IP} dev eth0

header "Verify External FRR Setup"

run_cmd docker exec frr bridge vlan show
run_cmd docker exec frr bridge vni show
run_cmd docker exec frr ip route show vrf $IPVRF_VRF_NAME

# =============================================================================
# CLUSTER SETUP
# =============================================================================

header "Step 7: Setup EVPN Bridge on Cluster Nodes"

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

header "Step 8: Create VTEP CR"

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

header "Step 9: Create Namespace with UDN Label"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: evpn-l2-combo-test
  labels:
    k8s.ovn.org/primary-user-defined-network: ""
EOF
read

header "Step 10: Create Layer2 CUDN with Both MAC-VRF and IP-VRF"

cat <<EOF | kubectl apply -f -
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: evpn-l2-combo-test
  labels:
    network: evpn-l2-combo-test
spec:
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: evpn-l2-combo-test
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
        vni: ${MACVRF_VNI}
      ipVRF:
        vni: ${IPVRF_VNI}
EOF
read

run_cmd kubectl get clusteruserdefinednetwork evpn-l2-combo-test -o yaml

header "Step 11: Create FRRConfiguration"

cat <<EOF | kubectl apply -f -
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: evpn-l2-combo-test
  namespace: frr-k8s-system
  labels:
    network: evpn-l2-combo-test
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
            - prefix: ${CUDN_SUBNET}
              le: 32
            - prefix: ${IPVRF_AGNHOST_SUBNET}
  # NOTE: rawConfig removed - Step 14 handles the EVPN config via vtysh
EOF
read

header "Step 12: Create RouteAdvertisements"

cat <<EOF | kubectl apply -f -
apiVersion: k8s.ovn.org/v1
kind: RouteAdvertisements
metadata:
  name: evpn-l2-combo-test
spec:
  nodeSelector: {}
  networkSelectors:
  - networkSelectionType: ClusterUserDefinedNetworks
    clusterUserDefinedNetworkSelector:
      networkSelector:
        matchLabels:
          network: evpn-l2-combo-test
  frrConfigurationSelector:
    matchLabels:
      network: evpn-l2-combo-test
  advertisements:
  - PodNetwork
EOF
read

header "Step 13: Configure Cluster MAC-VRF + IP-VRF"

NETWORK_ID=$(kubectl get net-attach-def -n evpn-l2-combo-test evpn-l2-combo-test -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/network-id}' 2>/dev/null)
echo "Network ID: $NETWORK_ID"

NETWORK_NAME="evpn-l2-combo-test"
NETWORK_DOTTED=${NETWORK_NAME//-/.}
OVN_SWITCH="cluster_udn_${NETWORK_DOTTED}_ovn_layer2_switch"
OVN_PORT="cluster_udn_${NETWORK_DOTTED}_evpn_port"

echo "OVN Switch: $OVN_SWITCH"
echo "OVN Port: $OVN_PORT"
read

kubectl get pods -l app=ovnkube-node -n ovn-kubernetes -o custom-columns=POD:.metadata.name --no-headers | while read POD; do
  echo "=== Configuring MAC-VRF + IP-VRF on $POD ==="
  
  VRFNAME=$(kubectl exec -n ovn-kubernetes $POD -c ovnkube-controller -- ip -o link show ovn-k8s-mp${NETWORK_ID} 2>/dev/null | grep -oP 'master \K[^ ]+' || echo "evpn-l2-combo-test")
  echo "  VRF: $VRFNAME"
  
  kubectl exec -n ovn-kubernetes $POD -c ovnkube-controller -- /bin/sh -c "
    # === MAC-VRF Setup ===
    bridge vlan add dev br0 vid $MACVRF_VID self
    bridge vlan add dev vxlan0 vid $MACVRF_VID
    bridge vni add dev vxlan0 vni $MACVRF_VNI
    bridge vlan add dev vxlan0 vid $MACVRF_VID tunnel_info id $MACVRF_VNI
    
    # Create OVS internal port and connect to Linux bridge for MAC-VRF
    ovs-vsctl --if-exists del-port br-int evpn${MACVRF_VNI}
    ovs-vsctl add-port br-int evpn${MACVRF_VNI} -- set interface evpn${MACVRF_VNI} type=internal external-ids:iface-id=${OVN_PORT}
    ip link set evpn${MACVRF_VNI} master br0
    bridge vlan add dev evpn${MACVRF_VNI} vid $MACVRF_VID pvid untagged
    ip link set evpn${MACVRF_VNI} up
    
    # Add port to OVN logical switch
    ovn-nbctl --if-exists lsp-del ${OVN_PORT}
    ovn-nbctl lsp-add $OVN_SWITCH ${OVN_PORT}
    ovn-nbctl lsp-set-addresses ${OVN_PORT} unknown
    
    # === IP-VRF Setup ===
    bridge vlan add dev br0 vid $IPVRF_VID self
    bridge vlan add dev vxlan0 vid $IPVRF_VID
    bridge vni add dev vxlan0 vni $IPVRF_VNI
    bridge vlan add dev vxlan0 vid $IPVRF_VID tunnel_info id $IPVRF_VNI
    
    # Create SVI and bind to UDN VRF
    ip link del br0.$IPVRF_VID 2>/dev/null || true
    ip link add br0.$IPVRF_VID link br0 type vlan id $IPVRF_VID
    ip link set br0.$IPVRF_VID addrgenmode none
    ip link set br0.$IPVRF_VID master $VRFNAME
    ip link set br0.$IPVRF_VID up
    
    echo 'MAC-VRF + IP-VRF configured'
  "
done
read

header "Step 14: Configure frr-k8s for EVPN (MAC-VRF + IP-VRF)"

# =============================================================================
# IMPORTANT: Understanding the route-target timing issue
# =============================================================================
#
# WHY WE USE "no route-target import" BEFORE "route-target import":
#
# 1. WHAT ALREADY EXISTS:
#    When Step 12 (RouteAdvertisements) is applied, frr-k8s automatically creates:
#      router bgp 64512 vrf <vrfname>
#        address-family ipv4 unicast
#          redistribute connected
#        exit-address-family
#      exit
#    This is needed for frr-k8s to advertise pod routes from the VRF.
#
# 2. THE TIMING PROBLEM:
#    - BGP session with external FRR establishes (from Step 11 FRRConfiguration)
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
#    - This also causes rp_filter to drop return traffic (no reverse path)
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
  
  # Discover actual VRF name on this node
  NODE=$(kubectl get pod -n frr-k8s-system $FRR_POD -o jsonpath='{.spec.nodeName}')
  OVN_POD=$(kubectl get pods -n ovn-kubernetes -l app=ovnkube-node --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
  VRFNAME=$(kubectl exec -n ovn-kubernetes $OVN_POD -c ovnkube-controller -- ip -o link show ovn-k8s-mp${NETWORK_ID} 2>/dev/null | grep -oP 'master \K[^ ]+' || echo "mp${NETWORK_ID}-udn-vrf")
  
  echo "  Node: $NODE, VRF: $VRFNAME"
  
  # Step 1: Apply base EVPN config (works on fresh install)
  kubectl exec -n frr-k8s-system $FRR_POD -c frr -- vtysh \
    -c "configure terminal" \
    -c "vrf $VRFNAME" \
    -c "vni $IPVRF_VNI" \
    -c "exit-vrf" \
    -c "router bgp 64512" \
    -c "address-family l2vpn evpn" \
    -c "neighbor $FRR_IP activate" \
    -c "advertise-all-vni" \
    -c "vni $MACVRF_VNI" \
    -c "rd 64512:$MACVRF_VNI" \
    -c "route-target import 64512:$MACVRF_VNI" \
    -c "route-target export 64512:$MACVRF_VNI" \
    -c "exit-vni" \
    -c "exit-address-family" \
    -c "exit" \
    -c "router bgp 64512 vrf $VRFNAME" \
    -c "address-family ipv4 unicast" \
    -c "redistribute connected" \
    -c "exit-address-family" \
    -c "address-family l2vpn evpn" \
    -c "rd 64512:$IPVRF_VNI" \
    -c "route-target import 64512:$IPVRF_VNI" \
    -c "route-target export 64512:$IPVRF_VNI" \
    -c "advertise ipv4 unicast" \
    -c "exit-address-family" \
    -c "end"
  
  # Small delay to let BGP routes arrive and FRR process the config
  # Seeing some pretty nasty races
  sleep 10
  
  # Step 2: Force route re-evaluation by toggling route-targets
  # This handles the timing issue where routes arrived before RT was configured
  # May fail on fresh install (no RT to remove) - that's OK, ignore errors
  kubectl exec -n frr-k8s-system $FRR_POD -c frr -- vtysh \
    -c "configure terminal" \
    -c "router bgp 64512 vrf $VRFNAME" \
    -c "address-family l2vpn evpn" \
    -c "no route-target import 64512:$IPVRF_VNI" \
    -c "route-target import 64512:$IPVRF_VNI" \
    -c "no route-target export 64512:$IPVRF_VNI" \
    -c "route-target export 64512:$IPVRF_VNI" \
    -c "end" 2>/dev/null || echo "  (Route re-evaluation skipped - fresh install)"
done
read

header "Step 15: Create Test Pod"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: evpn-l2-combo-test
spec:
  containers:
  - name: agnhost
    image: registry.k8s.io/e2e-test-images/agnhost:2.45
    command: ["sleep", "infinity"]
EOF
read

echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/test-pod -n evpn-l2-combo-test --timeout=120s

# Get UDN pod IP from annotation
POD_IP=$(kubectl get pod test-pod -n evpn-l2-combo-test -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | jq -r '.["evpn-l2-combo-test/evpn-l2-combo-test"].ip_addresses[0]' | cut -d'/' -f1)
echo "Test pod UDN IP: $POD_IP"
read

header "Step 16: Verify Connectivity"

echo "=== MAC-VRF: Testing pod -> agnhost-macvrf (${MACVRF_AGNHOST_IP}) via L2 ==="
run_cmd kubectl exec -n evpn-l2-combo-test test-pod -- curl -s --max-time 5 http://${MACVRF_AGNHOST_IP}:8080/hostname

echo "=== MAC-VRF: Testing agnhost-macvrf -> pod ($POD_IP) via L2 ==="
# Note: test pod runs 'sleep infinity', not netexec, so we use ping here
run_cmd docker exec agnhost-macvrf ping -c 3 $POD_IP

echo "=== IP-VRF: Testing pod -> agnhost-ipvrf (${IPVRF_AGNHOST_IP}) via L3 ==="
run_cmd kubectl exec -n evpn-l2-combo-test test-pod -- curl -s --max-time 5 http://${IPVRF_AGNHOST_IP}:8080/hostname

echo "=== IP-VRF: Testing agnhost-ipvrf -> pod ($POD_IP) via L3 ==="
run_cmd docker exec agnhost-ipvrf ping -c 3 $POD_IP

header "EVPN Layer2 MAC-VRF + IP-VRF Test Complete!"

echo "Debugging Commands:"
echo "  # MAC-VRF (Type-2/Type-3 routes)"
echo "  docker exec frr vtysh -c 'show bgp l2vpn evpn route type 2'"
echo "  docker exec frr vtysh -c 'show bgp l2vpn evpn route type 3'"
echo "  docker exec frr bridge fdb show"
echo ""
echo "  # IP-VRF (Type-5 routes)"
echo "  docker exec frr vtysh -c 'show bgp l2vpn evpn route type 5'"
echo "  docker exec frr ip route show vrf $IPVRF_VRF_NAME"
echo ""
echo "  # frr-k8s status"
echo "  kubectl exec -n frr-k8s-system \$(kubectl get pods -n frr-k8s-system -l app=frr-k8s -o jsonpath='{.items[0].metadata.name}') -c frr -- vtysh -c 'show bgp l2vpn evpn summary'"

