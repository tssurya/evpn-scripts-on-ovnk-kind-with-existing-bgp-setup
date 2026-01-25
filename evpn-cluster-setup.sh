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
    
    # ==========================================================================
    # CLEANUP ORDER: VNI binding -> BGP VRF -> Network devices -> FRR VRF
    # 
    # FRR considers a VRF "active" if ANY of these exist:
    # - VNI binding in the VRF
    # - BGP routing instance for the VRF
    # - Linux kernel VRF interface
    #
    # We must remove ALL of these before "no vrf" will succeed.
    # ==========================================================================
    
    # Step 1: Remove VNI binding from FRR
    if [ -n "$FRR_POD" ] && [ -n "$EVPN_IPVRF_VNI" ]; then
        log "[$node_name] Removing VNI binding from FRR..."
        kubectl exec -n $EVPN_FRR_NAMESPACE $FRR_POD -c frr -- vtysh \
            -c "configure terminal" \
            -c "vrf $VRFNAME" \
            -c "no vni ${EVPN_IPVRF_VNI}" \
            -c "exit-vrf" \
            -c "end" 2>/dev/null || true
    fi
    
    # Step 2: Remove BGP VRF instance (but NOT the FRR VRF definition yet)
    if [ -n "$FRR_POD" ]; then
        log "[$node_name] Cleaning up frr-k8s BGP config..."
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
                -c "end" 2>/dev/null || true
        fi
    fi
    
    # Step 3: Cleanup network devices (NOT including Linux VRF - that's done from FRR pod)
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
    
    # ==========================================================================
    # NOTE: We do NOT delete the FRR VRF definition ("no vrf evpnXXXX") here!
    #
    # Cleanup order:
    # 1. This script runs first (cleanup_node)
    # 2. e2e test AfterEach deletes CUDN
    # 3. OVN-K watches CUDN deletion → calls vrfManager.DeleteVRF()
    # 4. OVN-K deletes Linux VRF interface
    # 5. zebra sees Linux VRF gone → removes "vrf evpnXXXX" from FRR config
    #
    # If we tried "no vrf evpnXXXX" in step 1, it would FAIL because:
    # - CUDN still exists → OVN-K's VRF still exists → Linux VRF still exists
    # - FRR refuses: "Only inactive VRFs can be deleted"
    #
    # We already removed VNI binding (step 1) and BGP VRF instance (step 2).
    # The base "vrf evpnXXXX" definition will be cleaned up by zebra in step 5.
    # ==========================================================================
    
    # Step 5: Persist clean config to disk
    # ==========================================================================
    # frr-k8s periodically reconciles and reloads from /etc/frr/frr.conf.
    # If we don't save the clean config, frr-k8s will reload stale VRFs/BGP config.
    # ==========================================================================
    if [ -n "$FRR_POD" ]; then
        log "[$node_name] Saving clean FRR config to disk..."
        kubectl exec -n $EVPN_FRR_NAMESPACE $FRR_POD -c frr -- vtysh -c "write memory" 2>/dev/null || true
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
    
    # =============================================================================
    # IMPORTANT: Split vtysh commands to allow zebra-bgpd sync for VRF-VNI binding
    # =============================================================================
    # FRR has a timing issue where bgpd needs time to learn about VRF-VNI associations
    # from zebra. If we configure the BGP VRF with route-targets before bgpd knows
    # about the VRF-VNI mapping, routes won't be imported into the VRF.
    #
    # Solution: Split into 3 phases with delays between them.
    # =============================================================================
    
    # Phase 1: VRF-VNI binding (zebra config)
    if [ -n "$EVPN_IPVRF_VNI" ]; then
        log "[$node_name] Phase 1: Configuring VRF-VNI binding..."
        kubectl exec -n $EVPN_FRR_NAMESPACE $FRR_POD -c frr -- vtysh \
            -c "configure terminal" \
            -c "vrf ${VRFNAME}" \
            -c "vni ${EVPN_IPVRF_VNI}" \
            -c "exit-vrf" \
            -c "end" 2>/dev/null
        
        # Wait for zebra to notify bgpd about the VRF-VNI association
        log "[$node_name] Waiting for zebra-bgpd VRF-VNI sync..."
        sleep 5
    fi
    
    # Phase 2: Global EVPN BGP config (advertise-all-vni triggers VNI discovery)
    log "[$node_name] Phase 2: Configuring global EVPN BGP..."
    local VTYSH_CMDS="-c 'configure terminal'"
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
    VTYSH_CMDS="$VTYSH_CMDS -c 'end'"
    
    local vtysh_output
    if ! vtysh_output=$(eval "kubectl exec -n $EVPN_FRR_NAMESPACE $FRR_POD -c frr -- vtysh $VTYSH_CMDS" 2>&1); then
        log "[$node_name] ERROR: Failed to configure global EVPN BGP"
        log "[$node_name] vtysh output: $vtysh_output"
        return 1
    fi
    
    # Wait for BGP sessions to establish and EVPN routes to converge
    # This is needed for both MAC-VRF (Type-2/3) and IP-VRF (Type-5) routes
    log "[$node_name] Waiting for EVPN route convergence..."
    sleep 5
    
    # Phase 3: IP-VRF BGP config with route-targets (after bgpd knows about VRF-VNI)
    # NOTE: We do NOT use 'redistribute connected' here because RouteAdvertisements
    # handles pod subnet advertisement via explicit Prefixes in FRRConfiguration.
    if [ -n "$EVPN_IPVRF_VNI" ]; then
        # Additional wait for advertise-all-vni to discover VNIs and associate with VRFs
        log "[$node_name] Waiting for VNI discovery..."
        sleep 5
        
        log "[$node_name] Phase 3: Configuring IP-VRF BGP with route-targets..."
        VTYSH_CMDS="-c 'configure terminal'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'router bgp ${EVPN_BGP_ASN} vrf ${VRFNAME}'"
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
        VTYSH_CMDS="$VTYSH_CMDS -c 'end'"
        
        if ! vtysh_output=$(eval "kubectl exec -n $EVPN_FRR_NAMESPACE $FRR_POD -c frr -- vtysh $VTYSH_CMDS" 2>&1); then
            log "[$node_name] ERROR: Failed to configure IP-VRF BGP"
            log "[$node_name] vtysh output: $vtysh_output"
            return 1
        fi
    fi
    
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
    
    # Wait for full EVPN fabric convergence across all nodes
    # This ensures Type-5 routes from external FRR are imported into ALL cluster VRFs
    # before the test starts (per-node delays only ensure local node readiness)
    log "Waiting for full EVPN fabric convergence..."
    sleep 5
    
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
