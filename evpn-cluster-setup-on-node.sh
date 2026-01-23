#!/bin/bash
# =============================================================================
# EVPN Cluster-Side Setup Script
# =============================================================================
# This script is downloaded and executed on each KIND node by the Go E2E tests.
# It configures the cluster-side EVPN infrastructure until OVN-K implements it natively.
#
# REVERT ME: Remove this script once OVN-K EVPN implementation is complete.
#
# Environment variables (set by Go test):
#   NETWORK_NAME     - Name of the CUDN
#   EXTERNAL_FRR_IP  - IP of external FRR for BGP peering
#   BGP_ASN          - BGP Autonomous System Number (e.g., 64512)
#   CUDN_SUBNETS     - Comma-separated CUDN subnets
#   NODE_IP          - Node's internal IP (for VTEP)
#   MACVRF_VNI       - MAC-VRF VNI (optional, if MAC-VRF test)
#   MACVRF_VID       - MAC-VRF VLAN ID (optional, if MAC-VRF test)
#   IPVRF_VNI        - IP-VRF VNI (optional, if IP-VRF test)
#   IPVRF_VID        - IP-VRF VLAN ID (optional, if IP-VRF test)
#   CLEANUP          - Set to "true" to run cleanup instead of setup
#
# This script runs INSIDE the KIND node container (not on the host).
# =============================================================================

set -e

# Log with timestamp
log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

# Validate required environment variables
validate_env() {
    local required_vars="NETWORK_NAME EXTERNAL_FRR_IP BGP_ASN"
    # NODE_IP is only required for setup, not cleanup
    if [ "$CLEANUP" != "true" ]; then
        required_vars="$required_vars NODE_IP"
    fi
    for var in $required_vars; do
        if [ -z "${!var}" ]; then
            echo "ERROR: Required environment variable $var is not set"
            exit 1
        fi
    done
}

# Detect IP families from CUDN_SUBNETS
# Sets HAS_IPV4=true and/or HAS_IPV6=true
detect_ip_families() {
    HAS_IPV4=false
    HAS_IPV6=false
    
    # CUDN_SUBNETS is comma-separated
    IFS=',' read -ra SUBNETS <<< "$CUDN_SUBNETS"
    for subnet in "${SUBNETS[@]}"; do
        if [[ "$subnet" == *":"* ]]; then
            HAS_IPV6=true
        else
            HAS_IPV4=true
        fi
    done
    
    log "  IP families: IPv4=$HAS_IPV4, IPv6=$HAS_IPV6"
}

# =============================================================================
# CLEANUP FUNCTIONS
# =============================================================================

cleanup_evpn_bridge() {
    log "Cleaning up EVPN bridge (br0/vxlan0)..."
    ip link del vxlan0 2>/dev/null || true
    ip link del br0 2>/dev/null || true
    log "EVPN bridge cleanup complete"
}

cleanup_macvrf() {
    if [ -z "$MACVRF_VNI" ]; then
        return
    fi
    log "Cleaning up MAC-VRF (VNI: $MACVRF_VNI)..."
    
    # Remove OVS port
    ovs-vsctl --if-exists del-port br-int evpn${MACVRF_VNI}
    
    # Remove OVN logical switch port
    local NETWORK_DOTTED=${NETWORK_NAME//-/.}
    local OVN_PORT="cluster_udn_${NETWORK_DOTTED}_evpn_port"
    ovn-nbctl --if-exists lsp-del ${OVN_PORT}
    
    log "MAC-VRF cleanup complete"
}

cleanup_ipvrf() {
    if [ -z "$IPVRF_VID" ]; then
        return
    fi
    log "Cleaning up IP-VRF (VID: $IPVRF_VID)..."
    
    # Remove SVI
    ip link del br0.${IPVRF_VID} 2>/dev/null || true
    
    log "IP-VRF cleanup complete"
}

cleanup_frrk8s() {
    log "Cleaning up frr-k8s EVPN config..."
    
    # Find the frr-k8s pod on this node
    local NODE_NAME=$(hostname)
    local FRR_POD=$(crictl ps --name frr -q 2>/dev/null | head -1)
    
    if [ -z "$FRR_POD" ]; then
        log "No frr-k8s container found, skipping BGP cleanup"
        return
    fi
    
    # Use network name as VRF name (works for names ≤15 chars, which our tests always use)
    local VRFNAME=$NETWORK_NAME
    
    # Remove EVPN BGP config via vtysh
    # Note: We run vtysh directly since we're inside the node, and frr-k8s
    # container shares the network namespace
    crictl exec $FRR_POD vtysh \
        -c "configure terminal" \
        -c "router bgp ${BGP_ASN}" \
        -c "address-family l2vpn evpn" \
        -c "no advertise-all-vni" \
        -c "exit-address-family" \
        -c "end" 2>/dev/null || true
    
    # Remove VRF BGP if IP-VRF was configured
    if [ -n "$IPVRF_VNI" ]; then
        crictl exec $FRR_POD vtysh \
            -c "configure terminal" \
            -c "no router bgp ${BGP_ASN} vrf $VRFNAME" \
            -c "no vrf $VRFNAME" \
            -c "end" 2>/dev/null || true
    fi
    
    log "frr-k8s cleanup complete"
}

run_cleanup() {
    log "Starting EVPN cleanup on $(hostname)..."
    
    # Cleanup in reverse order of setup
    cleanup_frrk8s
    cleanup_ipvrf
    cleanup_macvrf
    cleanup_evpn_bridge
    
    log "EVPN cleanup complete on $(hostname)"
}

# =============================================================================
# SETUP FUNCTIONS
# =============================================================================

setup_evpn_bridge() {
    log "Setting up EVPN bridge (br0/vxlan0)..."
    
    # NODE_IP is passed from Go test via environment variable
    
    # Clean up any existing config
    ip link del br0 2>/dev/null || true
    ip link del vxlan0 2>/dev/null || true
    
    # Create br0 bridge with VLAN filtering
    ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
    ip link set br0 addrgenmode none
    
    # Create vxlan0 in SVD mode
    ip link add vxlan0 type vxlan dstport 4789 local $NODE_IP nolearning external vnifilter
    ip link set vxlan0 addrgenmode none master br0
    
    # Bring up interfaces
    ip link set br0 up
    ip link set vxlan0 up
    
    # Configure vxlan0 bridge options
    bridge link set dev vxlan0 vlan_tunnel on neigh_suppress on learning off
    
    log "EVPN bridge setup complete (VTEP IP: $NODE_IP)"
}

setup_macvrf() {
    if [ -z "$MACVRF_VNI" ] || [ -z "$MACVRF_VID" ]; then
        log "MAC-VRF not configured (no VNI/VID), skipping..."
        return
    fi
    
    log "Setting up MAC-VRF (VNI: $MACVRF_VNI, VID: $MACVRF_VID)..."
    
    # Add VLAN/VNI mapping
    bridge vlan add dev br0 vid $MACVRF_VID self
    bridge vlan add dev vxlan0 vid $MACVRF_VID
    bridge vni add dev vxlan0 vni $MACVRF_VNI
    bridge vlan add dev vxlan0 vid $MACVRF_VID tunnel_info id $MACVRF_VNI
    
    # Get OVN switch and port names
    local NETWORK_DOTTED=${NETWORK_NAME//-/.}
    local OVN_SWITCH="cluster_udn_${NETWORK_DOTTED}_ovn_layer2_switch"
    local OVN_PORT="cluster_udn_${NETWORK_DOTTED}_evpn_port"
    
    # Create OVS internal port
    ovs-vsctl --if-exists del-port br-int evpn${MACVRF_VNI}
    ovs-vsctl add-port br-int evpn${MACVRF_VNI} -- set interface evpn${MACVRF_VNI} type=internal external-ids:iface-id=${OVN_PORT}
    
    # Connect to Linux bridge
    ip link set evpn${MACVRF_VNI} master br0
    bridge vlan add dev evpn${MACVRF_VNI} vid $MACVRF_VID pvid untagged
    ip link set evpn${MACVRF_VNI} up
    
    # Add port to OVN logical switch
    ovn-nbctl --if-exists lsp-del ${OVN_PORT}
    ovn-nbctl lsp-add $OVN_SWITCH ${OVN_PORT}
    ovn-nbctl lsp-set-addresses ${OVN_PORT} unknown
    
    log "MAC-VRF setup complete"
}

setup_ipvrf() {
    if [ -z "$IPVRF_VNI" ] || [ -z "$IPVRF_VID" ]; then
        log "IP-VRF not configured (no VNI/VID), skipping..."
        return
    fi
    
    log "Setting up IP-VRF (VNI: $IPVRF_VNI, VID: $IPVRF_VID)..."
    
    # Use network name as VRF name (works for names ≤15 chars, which our tests always use)
    local VRFNAME=$NETWORK_NAME
    log "  Using VRF: $VRFNAME"
    
    # Add VLAN/VNI mapping
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
    
    log "IP-VRF setup complete"
}

setup_frrk8s() {
    log "Configuring frr-k8s for EVPN..."
    
    # Detect IP families from subnets
    detect_ip_families
    
    # Find the frr-k8s container on this node
    local FRR_POD=$(crictl ps --name frr -q 2>/dev/null | head -1)
    
    if [ -z "$FRR_POD" ]; then
        log "ERROR: No frr-k8s container found on this node"
        exit 1
    fi
    
    # Use network name as VRF name (works for names ≤15 chars, which our tests always use)
    local VRFNAME=$NETWORK_NAME
    log "  VRF: $VRFNAME, FRR container: $FRR_POD"
    
    # Build vtysh commands for base EVPN config (matching bash script order)
    local VTYSH_CMDS="-c 'configure terminal'"
    
    # IP-VRF: VRF-VNI binding FIRST (before global BGP, same as bash script lines 480-482)
    if [ -n "$IPVRF_VNI" ]; then
        VTYSH_CMDS="$VTYSH_CMDS -c 'vrf ${VRFNAME}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'vni ${IPVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'exit-vrf'"
    fi
    
    # Global EVPN BGP config (same as bash script lines 483-492)
    VTYSH_CMDS="$VTYSH_CMDS -c 'router bgp ${BGP_ASN}'"
    VTYSH_CMDS="$VTYSH_CMDS -c 'address-family l2vpn evpn'"
    VTYSH_CMDS="$VTYSH_CMDS -c 'neighbor ${EXTERNAL_FRR_IP} activate'"
    VTYSH_CMDS="$VTYSH_CMDS -c 'advertise-all-vni'"
    
    # MAC-VRF VNI config (same as bash script lines 487-491)
    if [ -n "$MACVRF_VNI" ]; then
        VTYSH_CMDS="$VTYSH_CMDS -c 'vni ${MACVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'rd ${BGP_ASN}:${MACVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'route-target import ${BGP_ASN}:${MACVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'route-target export ${BGP_ASN}:${MACVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'exit-vni'"
    fi
    
    VTYSH_CMDS="$VTYSH_CMDS -c 'exit-address-family'"
    VTYSH_CMDS="$VTYSH_CMDS -c 'exit'"
    
    # IP-VRF BGP config (same as bash script lines 494-503, dual-stack aware)
    if [ -n "$IPVRF_VNI" ]; then
        # BGP for VRF
        VTYSH_CMDS="$VTYSH_CMDS -c 'router bgp ${BGP_ASN} vrf ${VRFNAME}'"
        
        # Configure IPv4 unicast if cluster has IPv4
        if [ "$HAS_IPV4" = "true" ]; then
            VTYSH_CMDS="$VTYSH_CMDS -c 'address-family ipv4 unicast'"
            VTYSH_CMDS="$VTYSH_CMDS -c 'redistribute connected'"
            VTYSH_CMDS="$VTYSH_CMDS -c 'exit-address-family'"
        fi
        
        # Configure IPv6 unicast if cluster has IPv6
        if [ "$HAS_IPV6" = "true" ]; then
            VTYSH_CMDS="$VTYSH_CMDS -c 'address-family ipv6 unicast'"
            VTYSH_CMDS="$VTYSH_CMDS -c 'redistribute connected'"
            VTYSH_CMDS="$VTYSH_CMDS -c 'exit-address-family'"
        fi
        
        # l2vpn evpn address-family with route-targets and advertise
        VTYSH_CMDS="$VTYSH_CMDS -c 'address-family l2vpn evpn'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'rd ${BGP_ASN}:${IPVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'route-target import ${BGP_ASN}:${IPVRF_VNI}'"
        VTYSH_CMDS="$VTYSH_CMDS -c 'route-target export ${BGP_ASN}:${IPVRF_VNI}'"
        
        # Advertise unicast routes for each IP family
        if [ "$HAS_IPV4" = "true" ]; then
            VTYSH_CMDS="$VTYSH_CMDS -c 'advertise ipv4 unicast'"
        fi
        if [ "$HAS_IPV6" = "true" ]; then
            VTYSH_CMDS="$VTYSH_CMDS -c 'advertise ipv6 unicast'"
        fi
        
        VTYSH_CMDS="$VTYSH_CMDS -c 'exit-address-family'"
    fi
    
    VTYSH_CMDS="$VTYSH_CMDS -c 'end'"
    
    # Apply base config
    log "  Applying base EVPN config..."
    eval "crictl exec $FRR_POD vtysh $VTYSH_CMDS"
    
    # Force route re-evaluation for IP-VRF (handles timing issue)
    # We do this twice with delays to handle FRR's async route processing
    if [ -n "$IPVRF_VNI" ]; then
        log "  Waiting for BGP routes to arrive..."
        sleep 10
        
        log "  Forcing route re-evaluation for IP-VRF (attempt 1)..."
        crictl exec $FRR_POD vtysh \
            -c "configure terminal" \
            -c "router bgp ${BGP_ASN} vrf ${VRFNAME}" \
            -c "address-family l2vpn evpn" \
            -c "no route-target import ${BGP_ASN}:${IPVRF_VNI}" \
            -c "route-target import ${BGP_ASN}:${IPVRF_VNI}" \
            -c "end" 2>/dev/null || true
        
        sleep 5
        
        log "  Forcing route re-evaluation for IP-VRF (attempt 2)..."
        crictl exec $FRR_POD vtysh \
            -c "configure terminal" \
            -c "router bgp ${BGP_ASN} vrf ${VRFNAME}" \
            -c "address-family l2vpn evpn" \
            -c "no route-target import ${BGP_ASN}:${IPVRF_VNI}" \
            -c "route-target import ${BGP_ASN}:${IPVRF_VNI}" \
            -c "end" 2>/dev/null || true
    fi
    
    log "frr-k8s configuration complete"
}

run_setup() {
    log "Starting EVPN setup on $(hostname)..."
    log "  NETWORK_NAME: $NETWORK_NAME"
    log "  NODE_IP: $NODE_IP"
    log "  EXTERNAL_FRR_IP: $EXTERNAL_FRR_IP"
    log "  BGP_ASN: $BGP_ASN"
    log "  CUDN_SUBNETS: $CUDN_SUBNETS"
    log "  MACVRF_VNI/VID: ${MACVRF_VNI:-none}/${MACVRF_VID:-none}"
    log "  IPVRF_VNI/VID: ${IPVRF_VNI:-none}/${IPVRF_VID:-none}"
    
    setup_evpn_bridge
    setup_macvrf
    setup_ipvrf
    setup_frrk8s
    
    log "EVPN setup complete on $(hostname)"
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

