#!/bin/bash
# =============================================================================
# EVPN Cluster-Side Setup Script (Portable Version)
# =============================================================================
# This script runs from the host machine and uses kubectl exec to configure
# ALL cluster nodes. It discovers nodes automatically via kubectl.
#
# REVERT ME: Remove this script once OVN-K EVPN implementation is complete.
#
# Environment variables (set by Go test):
#   NETWORK_NAME     - Name of the CUDN
#   EXTERNAL_FRR_IP  - IP of external FRR for BGP peering
#   BGP_ASN          - BGP Autonomous System Number (e.g., 64512)
#   CUDN_SUBNETS     - Comma-separated CUDN subnets
#   OVN_NAMESPACE    - OVN-Kubernetes namespace (e.g., ovn-kubernetes)
#   FRR_NAMESPACE    - frr-k8s namespace (e.g., frr-k8s-system)
#   MACVRF_VNI       - MAC-VRF VNI (optional, if MAC-VRF test)
#   MACVRF_VID       - MAC-VRF VLAN ID (optional, if MAC-VRF test)
#   IPVRF_VNI        - IP-VRF VNI (optional, if IP-VRF test)
#   IPVRF_VID        - IP-VRF VLAN ID (optional, if IP-VRF test)
#   CLEANUP          - Set to "true" to run cleanup instead of setup
#
# This script runs on the HOST machine (where kubectl is available).
# =============================================================================

set -e

# Log with timestamp
log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

# Validate required environment variables
validate_env() {
    local required_vars="NETWORK_NAME EXTERNAL_FRR_IP BGP_ASN OVN_NAMESPACE FRR_NAMESPACE"
    for var in $required_vars; do
        if [ -z "${!var}" ]; then
            echo "ERROR: Required environment variable $var is not set"
            exit 1
        fi
    done
}

# Get node's internal IP (prefer IPv4, fall back to IPv6)
get_node_ip() {
    local node_name=$1
    local ip
    
    # Try IPv4 first
    ip=$(kubectl get node $node_name -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n' | grep -v ':' | head -1)
    if [ -n "$ip" ]; then
        echo "$ip"
        return
    fi
    
    # Fall back to IPv6
    ip=$(kubectl get node $node_name -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n' | grep ':' | head -1)
    echo "$ip"
}

# Find ovnkube-node pod on a node
find_ovn_pod() {
    local node_name=$1
    kubectl get pods -n $OVN_NAMESPACE -l name=ovnkube-node \
        --field-selector spec.nodeName=$node_name \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Find frr-k8s pod on a node
find_frr_pod() {
    local node_name=$1
    kubectl get pods -n $FRR_NAMESPACE -l app=frr-k8s \
        --field-selector spec.nodeName=$node_name \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Detect IP families from CUDN_SUBNETS
detect_ip_families() {
    HAS_IPV4=false
    HAS_IPV6=false
    
    IFS=',' read -ra SUBNETS <<< "$CUDN_SUBNETS"
    for subnet in "${SUBNETS[@]}"; do
        if [[ "$subnet" == *":"* ]]; then
            HAS_IPV6=true
        else
            HAS_IPV4=true
        fi
    done
}

# =============================================================================
# CLEANUP FUNCTIONS (per node)
# =============================================================================

cleanup_node() {
    local node_name=$1
    log "[$node_name] Starting cleanup..."
    
    local OVN_POD=$(find_ovn_pod $node_name)
    local FRR_POD=$(find_frr_pod $node_name)
    local VRFNAME=$NETWORK_NAME
    
    # Cleanup frr-k8s
    if [ -n "$FRR_POD" ]; then
        log "[$node_name] Cleaning up frr-k8s EVPN config..."
        kubectl exec -n $FRR_NAMESPACE $FRR_POD -c frr -- vtysh \
            -c "configure terminal" \
            -c "router bgp ${BGP_ASN}" \
            -c "address-family l2vpn evpn" \
            -c "no advertise-all-vni" \
            -c "exit-address-family" \
            -c "end" 2>/dev/null || true
        
        if [ -n "$IPVRF_VNI" ]; then
            kubectl exec -n $FRR_NAMESPACE $FRR_POD -c frr -- vtysh \
                -c "configure terminal" \
                -c "no router bgp ${BGP_ASN} vrf $VRFNAME" \
                -c "no vrf $VRFNAME" \
                -c "end" 2>/dev/null || true
        fi
    fi
    
    # Cleanup network devices
    if [ -n "$OVN_POD" ]; then
        log "[$node_name] Cleaning up network devices..."
        
        local NETWORK_DOTTED=${NETWORK_NAME//-/.}
        local OVN_PORT="cluster_udn_${NETWORK_DOTTED}_evpn_port"
        
        kubectl exec -n $OVN_NAMESPACE $OVN_POD -c ovnkube-controller -- /bin/sh -c "
            # IP-VRF SVI
            ip link del br0.${IPVRF_VID:-0} 2>/dev/null || true
            
            # MAC-VRF OVS/OVN
            ovs-vsctl --if-exists del-port br-int evpn${MACVRF_VNI:-0} 2>/dev/null || true
            ovn-nbctl --if-exists lsp-del ${OVN_PORT} 2>/dev/null || true
            
            # EVPN bridge
            ip link del vxlan0 2>/dev/null || true
            ip link del br0 2>/dev/null || true
        " || true
    fi
    
    log "[$node_name] Cleanup complete"
}

run_cleanup() {
    log "Starting EVPN cleanup on all nodes..."
    
    local nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
    local failed_nodes=""
    
    for node_name in $nodes; do
        if ! cleanup_node "$node_name"; then
            failed_nodes="$failed_nodes $node_name"
            log "[$node_name] WARNING: Cleanup had errors (continuing with other nodes)"
        fi
    done
    
    if [ -n "$failed_nodes" ]; then
        log "WARNING: Cleanup had errors on nodes:$failed_nodes"
    fi
    
    log "EVPN cleanup complete on all nodes"
}

# =============================================================================
# SETUP FUNCTIONS (per node)
# =============================================================================

setup_node() {
    local node_name=$1
    local node_ip=$(get_node_ip $node_name)
    
    if [ -z "$node_ip" ]; then
        log "[$node_name] ERROR: Could not get node IP"
        return 1
    fi
    
    log "[$node_name] Starting setup (IP: $node_ip)..."
    
    local OVN_POD=$(find_ovn_pod $node_name)
    local FRR_POD=$(find_frr_pod $node_name)
    
    if [ -z "$OVN_POD" ]; then
        log "[$node_name] ERROR: Could not find ovnkube-node pod"
        return 1
    fi
    
    # === Setup EVPN Bridge ===
    log "[$node_name] Setting up EVPN bridge (br0/vxlan0)..."
    kubectl exec -n $OVN_NAMESPACE $OVN_POD -c ovnkube-controller -- /bin/sh -c "
        ip link del br0 2>/dev/null || true
        ip link del vxlan0 2>/dev/null || true
        
        ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
        ip link set br0 addrgenmode none
        
        ip link add vxlan0 type vxlan dstport 4789 local $node_ip nolearning external vnifilter
        ip link set vxlan0 addrgenmode none master br0
        
        ip link set br0 up
        ip link set vxlan0 up
        
        bridge link set dev vxlan0 vlan_tunnel on neigh_suppress on learning off
    "
    
    # === Setup MAC-VRF ===
    if [ -n "$MACVRF_VNI" ] && [ -n "$MACVRF_VID" ]; then
        log "[$node_name] Setting up MAC-VRF (VNI: $MACVRF_VNI, VID: $MACVRF_VID)..."
        
        local NETWORK_DOTTED=${NETWORK_NAME//-/.}
        local OVN_SWITCH="cluster_udn_${NETWORK_DOTTED}_ovn_layer2_switch"
        local OVN_PORT="cluster_udn_${NETWORK_DOTTED}_evpn_port"
        
        kubectl exec -n $OVN_NAMESPACE $OVN_POD -c ovnkube-controller -- /bin/sh -c "
            bridge vlan add dev br0 vid $MACVRF_VID self
            bridge vlan add dev vxlan0 vid $MACVRF_VID
            bridge vni add dev vxlan0 vni $MACVRF_VNI
            bridge vlan add dev vxlan0 vid $MACVRF_VID tunnel_info id $MACVRF_VNI
            
            ovs-vsctl --if-exists del-port br-int evpn${MACVRF_VNI}
            ovs-vsctl add-port br-int evpn${MACVRF_VNI} -- set interface evpn${MACVRF_VNI} type=internal external-ids:iface-id=${OVN_PORT}
            
            ip link set evpn${MACVRF_VNI} master br0
            bridge vlan add dev evpn${MACVRF_VNI} vid $MACVRF_VID pvid untagged
            ip link set evpn${MACVRF_VNI} up
            
            ovn-nbctl --if-exists lsp-del ${OVN_PORT}
            ovn-nbctl lsp-add $OVN_SWITCH ${OVN_PORT}
            ovn-nbctl lsp-set-addresses ${OVN_PORT} unknown
        "
    fi
    
    # === Setup IP-VRF ===
    if [ -n "$IPVRF_VNI" ] && [ -n "$IPVRF_VID" ]; then
        log "[$node_name] Setting up IP-VRF (VNI: $IPVRF_VNI, VID: $IPVRF_VID)..."
        
        local VRFNAME=$NETWORK_NAME
        
        kubectl exec -n $OVN_NAMESPACE $OVN_POD -c ovnkube-controller -- /bin/sh -c "
            bridge vlan add dev br0 vid $IPVRF_VID self
            bridge vlan add dev vxlan0 vid $IPVRF_VID
            bridge vni add dev vxlan0 vni $IPVRF_VNI
            bridge vlan add dev vxlan0 vid $IPVRF_VID tunnel_info id $IPVRF_VNI
            
            ip link del br0.$IPVRF_VID 2>/dev/null || true
            ip link add br0.$IPVRF_VID link br0 type vlan id $IPVRF_VID
            ip link set br0.$IPVRF_VID addrgenmode none
            ip link set br0.$IPVRF_VID master $VRFNAME
            ip link set br0.$IPVRF_VID up
        "
    fi
    
    # === Setup frr-k8s ===
    if [ -z "$FRR_POD" ]; then
        log "[$node_name] ERROR: Could not find frr-k8s pod"
        return 1
    fi
    
    log "[$node_name] Configuring frr-k8s for EVPN..."
    
    local VRFNAME=$NETWORK_NAME
    local VTYSH_CMDS="-c 'configure terminal'"
    
    # VRF-VNI binding first
    if [ -n "$IPVRF_VNI" ]; then
        VTYSH_CMDS="$VTYSH_CMDS -c 'vrf ${VRFNAME}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'vni ${IPVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'exit-vrf'"
    fi
    
    # Global EVPN BGP
    VTYSH_CMDS="$VTYSH_CMDS -c 'router bgp ${BGP_ASN}'"
    VTYSH_CMDS="$VTYSH_CMDS -c 'address-family l2vpn evpn'"
    VTYSH_CMDS="$VTYSH_CMDS -c 'neighbor ${EXTERNAL_FRR_IP} activate'"
    VTYSH_CMDS="$VTYSH_CMDS -c 'advertise-all-vni'"
    
    # MAC-VRF VNI config
    if [ -n "$MACVRF_VNI" ]; then
        VTYSH_CMDS="$VTYSH_CMDS -c 'vni ${MACVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'rd ${BGP_ASN}:${MACVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'route-target import ${BGP_ASN}:${MACVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'route-target export ${BGP_ASN}:${MACVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'exit-vni'"
    fi
    
    VTYSH_CMDS="$VTYSH_CMDS -c 'exit-address-family'"
    VTYSH_CMDS="$VTYSH_CMDS -c 'exit'"
    
    # IP-VRF BGP config (dual-stack aware)
    if [ -n "$IPVRF_VNI" ]; then
        VTYSH_CMDS="$VTYSH_CMDS -c 'router bgp ${BGP_ASN} vrf ${VRFNAME}'"
        
        if [ "$HAS_IPV4" = "true" ]; then
            VTYSH_CMDS="$VTYSH_CMDS -c 'address-family ipv4 unicast'"
            VTYSH_CMDS="$VTYSH_CMDS -c 'redistribute connected'"
            VTYSH_CMDS="$VTYSH_CMDS -c 'exit-address-family'"
        fi
        
        if [ "$HAS_IPV6" = "true" ]; then
            VTYSH_CMDS="$VTYSH_CMDS -c 'address-family ipv6 unicast'"
            VTYSH_CMDS="$VTYSH_CMDS -c 'redistribute connected'"
            VTYSH_CMDS="$VTYSH_CMDS -c 'exit-address-family'"
        fi
        
        VTYSH_CMDS="$VTYSH_CMDS -c 'address-family l2vpn evpn'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'rd ${BGP_ASN}:${IPVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'route-target import ${BGP_ASN}:${IPVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'route-target export ${BGP_ASN}:${IPVRF_VNI}'"
        
        if [ "$HAS_IPV4" = "true" ]; then
            VTYSH_CMDS="$VTYSH_CMDS -c 'advertise ipv4 unicast'"
        fi
        if [ "$HAS_IPV6" = "true" ]; then
            VTYSH_CMDS="$VTYSH_CMDS -c 'advertise ipv6 unicast'"
        fi
        
        VTYSH_CMDS="$VTYSH_CMDS -c 'exit-address-family'"
    fi
    
    VTYSH_CMDS="$VTYSH_CMDS -c 'end'"
    
    eval "kubectl exec -n $FRR_NAMESPACE $FRR_POD -c frr -- vtysh $VTYSH_CMDS"
    
    # Force route re-evaluation for IP-VRF
    if [ -n "$IPVRF_VNI" ]; then
        log "[$node_name] Waiting for BGP routes..."
        sleep 10
        
        log "[$node_name] Forcing route re-evaluation..."
        kubectl exec -n $FRR_NAMESPACE $FRR_POD -c frr -- vtysh \
            -c "configure terminal" \
            -c "router bgp ${BGP_ASN} vrf ${VRFNAME}" \
            -c "address-family l2vpn evpn" \
            -c "no route-target import ${BGP_ASN}:${IPVRF_VNI}" \
            -c "route-target import ${BGP_ASN}:${IPVRF_VNI}" \
            -c "end" 2>/dev/null || true
        
        sleep 5
        
        kubectl exec -n $FRR_NAMESPACE $FRR_POD -c frr -- vtysh \
            -c "configure terminal" \
            -c "router bgp ${BGP_ASN} vrf ${VRFNAME}" \
            -c "address-family l2vpn evpn" \
            -c "no route-target import ${BGP_ASN}:${IPVRF_VNI}" \
            -c "route-target import ${BGP_ASN}:${IPVRF_VNI}" \
            -c "end" 2>/dev/null || true
    fi
    
    log "[$node_name] Setup complete"
}

run_setup() {
    log "Starting EVPN setup on all nodes..."
    log "  NETWORK_NAME: $NETWORK_NAME"
    log "  EXTERNAL_FRR_IP: $EXTERNAL_FRR_IP"
    log "  BGP_ASN: $BGP_ASN"
    log "  CUDN_SUBNETS: $CUDN_SUBNETS"
    log "  MACVRF_VNI/VID: ${MACVRF_VNI:-none}/${MACVRF_VID:-none}"
    log "  IPVRF_VNI/VID: ${IPVRF_VNI:-none}/${IPVRF_VID:-none}"
    
    # Detect IP families once
    detect_ip_families
    log "  IP families: IPv4=$HAS_IPV4, IPv6=$HAS_IPV6"
    
    local nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
    for node_name in $nodes; do
        setup_node "$node_name"
    done
    
    log "EVPN setup complete on all nodes"
}

# =============================================================================
# MAIN
# =============================================================================

validate_env

if [ "$CLEANUP" = "true" ]; then
    run_cleanup
else
    run_setup
fi
