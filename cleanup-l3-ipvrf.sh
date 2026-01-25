#!/bin/bash

export KUBECONFIG=/home/surya/ovn.conf

# IP-VRF parameters (must match instructions-l3-ipvrf.sh)
VNI=20102
VID=202
VRF_NAME="vrf${VID}"
AGNHOST_NETWORK="agnhost-ipvrf-net"

echo "=== L3 IP-VRF EVPN Cleanup Script ==="
echo "VNI=$VNI, VID=$VID, VRF=$VRF_NAME"
echo ""

# ============================================================================
# Step 1: Delete Kubernetes Resources
# ============================================================================
echo "--- Deleting Kubernetes resources ---"

# Delete test pod
kubectl delete pod test-pod -n evpn-l3-test --ignore-not-found 2>/dev/null
echo "Deleted test pod"

# Delete RouteAdvertisements
kubectl delete routeadvertisements evpn-l3-test --ignore-not-found 2>/dev/null
echo "Deleted RouteAdvertisements"

# Delete FRRConfiguration
kubectl delete frrconfiguration evpn-l3-test -n frr-k8s-system --ignore-not-found 2>/dev/null
echo "Deleted FRRConfiguration"

# Delete CUDN
kubectl delete clusteruserdefinednetwork evpn-l3-test --ignore-not-found 2>/dev/null
echo "Deleted CUDN"

# Delete Namespace
kubectl delete namespace evpn-l3-test --ignore-not-found 2>/dev/null
echo "Deleted namespace"

# ============================================================================
# Step 2: Clean up frr-k8s VRF Config
# ============================================================================
echo ""
echo "--- Cleaning up frr-k8s VRF config ---"

NETWORK_ID=$(kubectl get net-attach-def -n evpn-l3-test evpn-l3-test -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/network-id}' 2>/dev/null)

kubectl get pods -n frr-k8s-system -l app=frr-k8s -o custom-columns=POD:.metadata.name --no-headers 2>/dev/null | while read FRR_POD; do
  if [ -n "$FRR_POD" ]; then
    echo "  Cleaning frr-k8s pod: $FRR_POD"
    
    NODE=$(kubectl get pod -n frr-k8s-system $FRR_POD -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    OVN_POD=$(kubectl get pods -n ovn-kubernetes -l app=ovnkube-node --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    VRFNAME=$(kubectl exec -n ovn-kubernetes $OVN_POD -c ovnkube-controller -- ip -o link show ovn-k8s-mp${NETWORK_ID} 2>/dev/null | grep -oP 'master \K[^ ]+' || echo "mp${NETWORK_ID}-udn-vrf")
    
    # Remove VRF BGP config
    kubectl exec -n frr-k8s-system $FRR_POD -c frr -- vtysh \
      -c "configure terminal" \
      -c "no router bgp 64512 vrf $VRFNAME" \
      -c "no vrf $VRFNAME" \
      -c "end" 2>/dev/null || true
  fi
done

# ============================================================================
# Step 3: Clean up Cluster Nodes (EVPN bridge, VRF SVI)
# ============================================================================
echo ""
echo "--- Cleaning up cluster nodes ---"

kubectl get pods -l app=ovnkube-node -n ovn-kubernetes -o custom-columns=POD:.metadata.name --no-headers 2>/dev/null | while read POD; do
  if [ -n "$POD" ]; then
    echo "  Cleaning node: $POD"
    kubectl exec -n ovn-kubernetes $POD -c ovnkube-controller -- /bin/sh -c "
      # Remove SVI
      ip link del br0.$VID 2>/dev/null || true
      
      # Remove VLAN/VNI config
      bridge vlan del dev vxlan0 vid $VID 2>/dev/null || true
      bridge vni del dev vxlan0 vni $VNI 2>/dev/null || true
      bridge vlan del dev br0 vid $VID self 2>/dev/null || true
      
      # Remove EVPN bridge and vxlan
      ip link del vxlan0 2>/dev/null || true
      ip link del br0 2>/dev/null || true
      
      echo 'Cleanup complete'
    " 2>/dev/null || true
  fi
done

# ============================================================================
# Step 4: Clean up External FRR
# ============================================================================
echo ""
echo "--- Cleaning up external FRR ---"

if docker ps --format '{{.Names}}' | grep -q '^frr$'; then
  # Remove in correct order: VNI binding -> BGP VRF -> FRR VRF -> Linux VRF
  echo "  Removing BGP config..."
  
  # 1. Remove VNI binding from VRF FIRST (required before anything else)
  echo "    Removing VNI binding..."
  docker exec frr vtysh \
    -c "configure terminal" \
    -c "vrf $VRF_NAME" \
    -c "no vni $VNI" \
    -c "exit-vrf" \
    -c "end" 2>/dev/null || true
  
  # 2. Remove the VRF-specific BGP instance
  echo "    Removing BGP VRF instance..."
  docker exec frr vtysh \
    -c "configure terminal" \
    -c "no router bgp 64512 vrf $VRF_NAME" \
    -c "end" 2>/dev/null || true
  
  # 3. Remove advertise-all-vni from main BGP
  docker exec frr vtysh \
    -c "configure terminal" \
    -c "router bgp 64512" \
    -c "address-family l2vpn evpn" \
    -c "no advertise-all-vni" \
    -c "exit-address-family" \
    -c "exit" \
    -c "end" 2>/dev/null || true
  
  # 4. Remove the VRF definition from FRR
  echo "    Removing FRR VRF definition..."
  docker exec frr vtysh \
    -c "configure terminal" \
    -c "no vrf $VRF_NAME" \
    -c "end" 2>/dev/null || true

  # Remove SVI
  echo "  Removing SVI br0.$VID..."
  docker exec frr ip link del br0.$VID 2>/dev/null || true

  # Remove VRF (Linux)
  echo "  Removing VRF $VRF_NAME..."
  docker exec frr ip link del $VRF_NAME 2>/dev/null || true

  # Remove VLAN/VNI config
  echo "  Removing VLAN/VNI config..."
  docker exec frr bridge vlan del dev vxlan0 vid $VID 2>/dev/null || true
  docker exec frr bridge vni del dev vxlan0 vni $VNI 2>/dev/null || true
  docker exec frr bridge vlan del dev br0 vid $VID self 2>/dev/null || true

  # Remove vxlan0 and br0
  echo "  Removing EVPN bridge..."
  docker exec frr ip link del vxlan0 2>/dev/null || true
  docker exec frr ip link del br0 2>/dev/null || true
  
  echo "  External FRR cleanup complete"
else
  echo "  FRR container not running, skipping"
fi

# ============================================================================
# Step 5: Clean up Agnhost and Network
# ============================================================================
echo ""
echo "--- Cleaning up agnhost ---"

# Disconnect FRR from agnhost network first
if docker network inspect ${AGNHOST_NETWORK} &>/dev/null; then
  docker network disconnect ${AGNHOST_NETWORK} frr 2>/dev/null || true
  echo "  Disconnected FRR from ${AGNHOST_NETWORK}"
fi

# Stop and remove agnhost container
if docker ps -a --format '{{.Names}}' | grep -q '^agnhost-ipvrf$'; then
  docker stop agnhost-ipvrf 2>/dev/null || true
  docker rm agnhost-ipvrf 2>/dev/null || true
  echo "  Removed agnhost-ipvrf container"
fi

# Remove agnhost network
if docker network inspect ${AGNHOST_NETWORK} &>/dev/null; then
  docker network rm ${AGNHOST_NETWORK} 2>/dev/null || true
  echo "  Removed ${AGNHOST_NETWORK} network"
fi

# ============================================================================
# Done
# ============================================================================
echo ""
echo "=== L3 IP-VRF Cleanup Complete ==="
echo ""
echo "Verify cleanup:"
echo "  kubectl get cudn"
echo "  kubectl get ns evpn-l3-test"
echo "  docker exec frr ip link show br0"
echo "  docker ps | grep agnhost"

