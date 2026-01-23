#!/bin/bash
# =============================================================================
# EVPN Cluster-Side Setup Script (Portable Version)
# =============================================================================
# This script runs from the host machine and uses kubectl exec to configure
# ALL cluster nodes. It discovers nodes automatically via kubectl.
#
# REVERT ME: Remove this script once OVN-K EVPN implementation is complete.
#
# Environment variables (set by Go test, all prefixed with EVPN_ to avoid conflicts):
#   EVPN_NETWORK_NAME     - Name of the CUDN
#   EVPN_EXTERNAL_FRR_IP  - IP of external FRR for BGP peering
#   EVPN_BGP_ASN          - BGP Autonomous System Number (e.g., 64512)
#   EVPN_CUDN_SUBNETS     - Comma-separated CUDN subnets
#   EVPN_OVN_NAMESPACE    - OVN-Kubernetes namespace (e.g., ovn-kubernetes)
#   EVPN_FRR_NAMESPACE    - frr-k8s namespace (e.g., frr-k8s-system)
#   EVPN_MACVRF_VNI       - MAC-VRF VNI (optional, if MAC-VRF test)
#   EVPN_MACVRF_VID       - MAC-VRF VLAN ID (optional, if MAC-VRF test)
#   EVPN_IPVRF_VNI        - IP-VRF VNI (optional, if IP-VRF test)
#   EVPN_IPVRF_VID        - IP-VRF VLAN ID (optional, if IP-VRF test)
#   EVPN_CLEANUP          - Set to "true" to run cleanup instead of setup
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
    local required_vars="EVPN_NETWORK_NAME EVPN_EXTERNAL_FRR_IP EVPN_BGP_ASN EVPN_OVN_NAMESPACE EVPN_FRR_NAMESPACE"
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
    kubectl get pods -n $EVPN_OVN_NAMESPACE -l name=ovnkube-node \
        --field-selector spec.nodeName=$node_name \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Find frr-k8s pod on a node
find_frr_pod() {
    local node_name=$1
    kubectl get pods -n $EVPN_FRR_NAMESPACE -l app=frr-k8s \
        --field-selector spec.nodeName=$node_name \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Detect IP families from EVPN_CUDN_SUBNETS
detect_ip_families() {
    HAS_IPV4=false
    HAS_IPV6=false
    
    IFS=',' read -ra SUBNETS <<< "$EVPN_CUDN_SUBNETS"
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
    local VRFNAME=$EVPN_NETWORK_NAME
    
    # Cleanup frr-k8s
    if [ -n "$FRR_POD" ]; then
        log "[$node_name] Cleaning up frr-k8s EVPN config..."
        kubectl exec -n $EVPN_FRR_NAMESPACE $FRR_POD -c frr -- vtysh \
            -c "configure terminal" \
            -c "router bgp ${EVPN_BGP_ASN}" \
            -c "address-family l2vpn evpn" \
            -c "no advertise-all-vni" \
            -c "exit-address-family" \
            -c "end" 2>/dev/null || true
        
        if [ -n "$EVPN_IPVRF_VNI" ]; then
            kubectl exec -n $EVPN_FRR_NAMESPACE $FRR_POD -c frr -- vtysh \
                -c "configure terminal" \
                -c "no router bgp ${EVPN_BGP_ASN} vrf $VRFNAME" \
                -c "no vrf $VRFNAME" \
                -c "end" 2>/dev/null || true
        fi
    fi
    
    # Cleanup network devices
    if [ -n "$OVN_POD" ]; then
        log "[$node_name] Cleaning up network devices..."
        
        local NETWORK_DOTTED=${EVPN_NETWORK_NAME//-/.}
        local OVN_PORT="cluster_udn_${NETWORK_DOTTED}_evpn_port"
        
        kubectl exec -n $EVPN_OVN_NAMESPACE $OVN_POD -c ovnkube-controller -- /bin/sh -c "
            # IP-VRF SVI
            ip link del br0.${EVPN_IPVRF_VID:-0} 2>/dev/null || true
            
            # MAC-VRF OVS/OVN
            ovs-vsctl --if-exists del-port br-int evpn${EVPN_MACVRF_VNI:-0} 2>/dev/null || true
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
    kubectl exec -n $EVPN_OVN_NAMESPACE $OVN_POD -c ovnkube-controller -- /bin/sh -c "
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
    if [ -n "$EVPN_MACVRF_VNI" ] && [ -n "$EVPN_MACVRF_VID" ]; then
        log "[$node_name] Setting up MAC-VRF (VNI: $EVPN_MACVRF_VNI, VID: $EVPN_MACVRF_VID)..."
        
        local NETWORK_DOTTED=${EVPN_NETWORK_NAME//-/.}
        local OVN_SWITCH="cluster_udn_${NETWORK_DOTTED}_ovn_layer2_switch"
        local OVN_PORT="cluster_udn_${NETWORK_DOTTED}_evpn_port"
        
        kubectl exec -n $EVPN_OVN_NAMESPACE $OVN_POD -c ovnkube-controller -- /bin/sh -c "
            bridge vlan add dev br0 vid $EVPN_MACVRF_VID self
            bridge vlan add dev vxlan0 vid $EVPN_MACVRF_VID
            bridge vni add dev vxlan0 vni $EVPN_MACVRF_VNI
            bridge vlan add dev vxlan0 vid $EVPN_MACVRF_VID tunnel_info id $EVPN_MACVRF_VNI
            
            ovs-vsctl --if-exists del-port br-int evpn${EVPN_MACVRF_VNI}
            ovs-vsctl add-port br-int evpn${EVPN_MACVRF_VNI} -- set interface evpn${EVPN_MACVRF_VNI} type=internal external-ids:iface-id=${OVN_PORT}
            
            ip link set evpn${EVPN_MACVRF_VNI} master br0
            bridge vlan add dev evpn${EVPN_MACVRF_VNI} vid $EVPN_MACVRF_VID pvid untagged
            ip link set evpn${EVPN_MACVRF_VNI} up
            
            ovn-nbctl --if-exists lsp-del ${OVN_PORT}
            ovn-nbctl lsp-add $OVN_SWITCH ${OVN_PORT}
            ovn-nbctl lsp-set-addresses ${OVN_PORT} unknown
        "
    fi
    
    # === Setup IP-VRF ===
    if [ -n "$EVPN_IPVRF_VNI" ] && [ -n "$EVPN_IPVRF_VID" ]; then
        log "[$node_name] Setting up IP-VRF (VNI: $EVPN_IPVRF_VNI, VID: $EVPN_IPVRF_VID)..."
        
        local VRFNAME=$EVPN_NETWORK_NAME
        
        kubectl exec -n $EVPN_OVN_NAMESPACE $OVN_POD -c ovnkube-controller -- /bin/sh -c "
            bridge vlan add dev br0 vid $EVPN_IPVRF_VID self
            bridge vlan add dev vxlan0 vid $EVPN_IPVRF_VID
            bridge vni add dev vxlan0 vni $EVPN_IPVRF_VNI
            bridge vlan add dev vxlan0 vid $EVPN_IPVRF_VID tunnel_info id $EVPN_IPVRF_VNI
            
            ip link del br0.$EVPN_IPVRF_VID 2>/dev/null || true
            ip link add br0.$EVPN_IPVRF_VID link br0 type vlan id $EVPN_IPVRF_VID
            ip link set br0.$EVPN_IPVRF_VID addrgenmode none
            ip link set br0.$EVPN_IPVRF_VID master $VRFNAME
            ip link set br0.$EVPN_IPVRF_VID up
        "
    fi
    
    # === Setup frr-k8s ===
    if [ -z "$FRR_POD" ]; then
        log "[$node_name] ERROR: Could not find frr-k8s pod"
        return 1
    fi
    
    log "[$node_name] Configuring frr-k8s for EVPN..."
    
    local VRFNAME=$EVPN_NETWORK_NAME
    local VTYSH_CMDS="-c 'configure terminal'"
    
    # VRF-VNI binding first
    if [ -n "$EVPN_IPVRF_VNI" ]; then
        VTYSH_CMDS="$VTYSH_CMDS -c 'vrf ${VRFNAME}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'vni ${EVPN_IPVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'exit-vrf'"
    fi
    
    # Global EVPN BGP
    VTYSH_CMDS="$VTYSH_CMDS -c 'router bgp ${EVPN_BGP_ASN}'"
    VTYSH_CMDS="$VTYSH_CMDS -c 'address-family l2vpn evpn'"
    VTYSH_CMDS="$VTYSH_CMDS -c 'neighbor ${EVPN_EXTERNAL_FRR_IP} activate'"
    VTYSH_CMDS="$VTYSH_CMDS -c 'advertise-all-vni'"
    
    # MAC-VRF VNI config
    if [ -n "$EVPN_MACVRF_VNI" ]; then
        VTYSH_CMDS="$VTYSH_CMDS -c 'vni ${EVPN_MACVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'rd ${EVPN_BGP_ASN}:${EVPN_MACVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'route-target import ${EVPN_BGP_ASN}:${EVPN_MACVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'route-target export ${EVPN_BGP_ASN}:${EVPN_MACVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'exit-vni'"
    fi
    
    VTYSH_CMDS="$VTYSH_CMDS -c 'exit-address-family'"
    VTYSH_CMDS="$VTYSH_CMDS -c 'exit'"
    
    # IP-VRF BGP config (dual-stack aware)
    if [ -n "$EVPN_IPVRF_VNI" ]; then
        VTYSH_CMDS="$VTYSH_CMDS -c 'router bgp ${EVPN_BGP_ASN} vrf ${VRFNAME}'"
        
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
        VTYSH_CMDS="$VTYSH_CMDS -c 'rd ${EVPN_BGP_ASN}:${EVPN_IPVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'route-target import ${EVPN_BGP_ASN}:${EVPN_IPVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'route-target export ${EVPN_BGP_ASN}:${EVPN_IPVRF_VNI}'"
        
        if [ "$HAS_IPV4" = "true" ]; then
            VTYSH_CMDS="$VTYSH_CMDS -c 'advertise ipv4 unicast'"
        fi
        if [ "$HAS_IPV6" = "true" ]; then
            VTYSH_CMDS="$VTYSH_CMDS -c 'advertise ipv6 unicast'"
        fi
        
        VTYSH_CMDS="$VTYSH_CMDS -c 'exit-address-family'"
    fi
    
    VTYSH_CMDS="$VTYSH_CMDS -c 'end'"
    
    eval "kubectl exec -n $EVPN_FRR_NAMESPACE $FRR_POD -c frr -- vtysh $VTYSH_CMDS"
    
    # Force route re-evaluation for IP-VRF
    # This handles the timing issue where routes arrived before RT was configured
    # Toggle BOTH import AND export to force FRR to re-evaluate routes
    if [ -n "$EVPN_IPVRF_VNI" ]; then
        log "[$node_name] Waiting for BGP routes to arrive..."
        sleep 10
        
        log "[$node_name] Forcing route re-evaluation by toggling route-targets..."
        kubectl exec -n $EVPN_FRR_NAMESPACE $FRR_POD -c frr -- vtysh \
            -c "configure terminal" \
            -c "router bgp ${EVPN_BGP_ASN} vrf ${VRFNAME}" \
            -c "address-family l2vpn evpn" \
            -c "no route-target import ${EVPN_BGP_ASN}:${EVPN_IPVRF_VNI}" \
            -c "route-target import ${EVPN_BGP_ASN}:${EVPN_IPVRF_VNI}" \
            -c "no route-target export ${EVPN_BGP_ASN}:${EVPN_IPVRF_VNI}" \
            -c "route-target export ${EVPN_BGP_ASN}:${EVPN_IPVRF_VNI}" \
            -c "end" 2>/dev/null || log "[$node_name] (Route re-evaluation skipped - fresh install)"
    fi
    
    log "[$node_name] Setup complete"
}

run_setup() {
    log "Starting EVPN setup on all nodes..."
    log "  EVPN_NETWORK_NAME: $EVPN_NETWORK_NAME"
    log "  EVPN_EXTERNAL_FRR_IP: $EVPN_EXTERNAL_FRR_IP"
    log "  EVPN_BGP_ASN: $EVPN_BGP_ASN"
    log "  EVPN_CUDN_SUBNETS: $EVPN_CUDN_SUBNETS"
    log "  EVPN_MACVRF_VNI/VID: ${EVPN_MACVRF_VNI:-none}/${EVPN_MACVRF_VID:-none}"
    log "  EVPN_IPVRF_VNI/VID: ${EVPN_IPVRF_VNI:-none}/${EVPN_IPVRF_VID:-none}"
    
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

if [ "$EVPN_CLEANUP" = "true" ]; then
    run_cleanup
else
    run_setup
fi
