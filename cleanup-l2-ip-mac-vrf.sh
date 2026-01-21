#!/bin/bash

export KUBECONFIG=/home/surya/ovn.conf

# Parameters (must match instructions-l2-ip-mac-vrf.sh)
MACVRF_VNI=10100
MACVRF_VID=100
IPVRF_VNI=20102
IPVRF_VID=202
IPVRF_VRF_NAME="vrf${IPVRF_VID}"
IPVRF_AGNHOST_NETWORK="agnhost-ipvrf-net"

echo "=== L2 MAC-VRF + IP-VRF EVPN Cleanup Script ==="
echo "MAC-VRF: VNI=$MACVRF_VNI, VID=$MACVRF_VID"
echo "IP-VRF: VNI=$IPVRF_VNI, VID=$IPVRF_VID"
echo ""

# ============================================================================
# Step 1: Delete Kubernetes Resources
# ============================================================================
echo "--- Deleting Kubernetes resources ---"

# Delete test pod
kubectl delete pod test-pod -n evpn-l2-combo-test --ignore-not-found 2>/dev/null
echo "Deleted test pod"

# Delete RouteAdvertisements
kubectl delete routeadvertisements evpn-l2-combo-test --ignore-not-found 2>/dev/null
echo "Deleted RouteAdvertisements"

# Delete FRRConfiguration
kubectl delete frrconfiguration evpn-l2-combo-test -n frr-k8s-system --ignore-not-found 2>/dev/null
echo "Deleted FRRConfiguration"

# Delete CUDN
kubectl delete clusteruserdefinednetwork evpn-l2-combo-test --ignore-not-found 2>/dev/null
echo "Deleted CUDN"

# Wait for net-attach-def to be cleaned up
echo "Waiting for net-attach-def cleanup..."
timeout 30 bash -c 'while kubectl get net-attach-def -n evpn-l2-combo-test evpn-l2-combo-test 2>/dev/null; do sleep 1; done' || true

# Delete Namespace
kubectl delete namespace evpn-l2-combo-test --ignore-not-found 2>/dev/null
echo "Deleted namespace"

# ============================================================================
# Step 2: Clean up frr-k8s EVPN Config
# ============================================================================
echo ""
echo "--- Cleaning up frr-k8s EVPN config ---"

FRR_IP=$(docker inspect frr --format '{{range .NetworkSettings.Networks}}{{if eq .NetworkID "'$(docker network inspect kind -f '{{.Id}}')'"}}{{.IPAddress}}{{end}}{{end}}' 2>/dev/null)

kubectl get pods -n frr-k8s-system -l app=frr-k8s -o custom-columns=POD:.metadata.name --no-headers 2>/dev/null | while read FRR_POD; do
  if [ -n "$FRR_POD" ]; then
    echo "  Cleaning frr-k8s pod: $FRR_POD"
    
    # Remove VRF BGP config
    kubectl exec -n frr-k8s-system $FRR_POD -c frr -- vtysh \
      -c "configure terminal" \
      -c "no router bgp 64512 vrf evpn-l2-combo-test" \
      -c "no vrf evpn-l2-combo-test" \
      -c "router bgp 64512" \
      -c "address-family l2vpn evpn" \
      -c "no advertise-all-vni" \
      -c "no neighbor $FRR_IP activate" \
      -c "exit-address-family" \
      -c "end" 2>/dev/null || true
  fi
done

# ============================================================================
# Step 3: Clean up Cluster Nodes
# ============================================================================
echo ""
echo "--- Cleaning up cluster nodes ---"

NETWORK_NAME="evpn-l2-combo-test"
NETWORK_DOTTED=${NETWORK_NAME//-/.}
OVN_PORT="cluster_udn_${NETWORK_DOTTED}_evpn_port"

kubectl get pods -l app=ovnkube-node -n ovn-kubernetes -o custom-columns=POD:.metadata.name --no-headers 2>/dev/null | while read POD; do
  if [ -n "$POD" ]; then
    echo "  Cleaning node: $POD"
    kubectl exec -n ovn-kubernetes $POD -c ovnkube-controller -- /bin/sh -c "
      # Remove OVS port (MAC-VRF)
      ovs-vsctl --if-exists del-port br-int evpn${MACVRF_VNI} 2>/dev/null || true
      
      # Remove IP-VRF SVI
      ip link del br0.$IPVRF_VID 2>/dev/null || true
      
      # Remove MAC-VRF VLAN/VNI config
      bridge vlan del dev vxlan0 vid $MACVRF_VID 2>/dev/null || true
      bridge vni del dev vxlan0 vni $MACVRF_VNI 2>/dev/null || true
      bridge vlan del dev br0 vid $MACVRF_VID self 2>/dev/null || true
      
      # Remove IP-VRF VLAN/VNI config
      bridge vlan del dev vxlan0 vid $IPVRF_VID 2>/dev/null || true
      bridge vni del dev vxlan0 vni $IPVRF_VNI 2>/dev/null || true
      bridge vlan del dev br0 vid $IPVRF_VID self 2>/dev/null || true
      
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
  # Remove IP-VRF BGP config
  echo "  Removing IP-VRF BGP config..."
  docker exec frr vtysh \
    -c "configure terminal" \
    -c "no router bgp 64512 vrf $IPVRF_VRF_NAME" \
    -c "end" 2>/dev/null || true
  
  # Remove advertise-all-vni from main BGP
  echo "  Removing BGP l2vpn evpn config..."
  docker exec frr vtysh \
    -c "configure terminal" \
    -c "router bgp 64512" \
    -c "address-family l2vpn evpn" \
    -c "no advertise-all-vni" \
    -c "exit-address-family" \
    -c "exit" \
    -c "no vrf $IPVRF_VRF_NAME" \
    -c "end" 2>/dev/null || true

  # Remove macvrf0 interface (veth to agnhost)
  echo "  Removing macvrf0 interface..."
  docker exec frr ip link del macvrf0 2>/dev/null || true

  # Remove IP-VRF SVI
  echo "  Removing IP-VRF SVI br0.$IPVRF_VID..."
  docker exec frr ip link del br0.$IPVRF_VID 2>/dev/null || true

  # Remove IP-VRF Linux VRF
  echo "  Removing IP-VRF $IPVRF_VRF_NAME..."
  docker exec frr ip link del $IPVRF_VRF_NAME 2>/dev/null || true

  # Remove MAC-VRF VLAN/VNI config
  echo "  Removing MAC-VRF VLAN/VNI config..."
  docker exec frr bridge vlan del dev vxlan0 vid $MACVRF_VID 2>/dev/null || true
  docker exec frr bridge vni del dev vxlan0 vni $MACVRF_VNI 2>/dev/null || true
  docker exec frr bridge vlan del dev br0 vid $MACVRF_VID self 2>/dev/null || true

  # Remove IP-VRF VLAN/VNI config
  echo "  Removing IP-VRF VLAN/VNI config..."
  docker exec frr bridge vlan del dev vxlan0 vid $IPVRF_VID 2>/dev/null || true
  docker exec frr bridge vni del dev vxlan0 vni $IPVRF_VNI 2>/dev/null || true
  docker exec frr bridge vlan del dev br0 vid $IPVRF_VID self 2>/dev/null || true

  # Remove vxlan0 and br0
  echo "  Removing EVPN bridge..."
  docker exec frr ip link del vxlan0 2>/dev/null || true
  docker exec frr ip link del br0 2>/dev/null || true
  
  echo "  External FRR cleanup complete"
else
  echo "  FRR container not running, skipping"
fi

# ============================================================================
# Step 5: Clean up Agnhost Containers and Networks
# ============================================================================
echo ""
echo "--- Cleaning up agnhosts ---"

# MAC-VRF agnhost
if docker ps -a --format '{{.Names}}' | grep -q '^agnhost-macvrf$'; then
  docker stop agnhost-macvrf 2>/dev/null || true
  docker rm agnhost-macvrf 2>/dev/null || true
  echo "  Removed agnhost-macvrf container"
fi

# IP-VRF agnhost
if docker network inspect ${IPVRF_AGNHOST_NETWORK} &>/dev/null; then
  docker network disconnect ${IPVRF_AGNHOST_NETWORK} frr 2>/dev/null || true
  echo "  Disconnected FRR from ${IPVRF_AGNHOST_NETWORK}"
fi

if docker ps -a --format '{{.Names}}' | grep -q '^agnhost-ipvrf$'; then
  docker stop agnhost-ipvrf 2>/dev/null || true
  docker rm agnhost-ipvrf 2>/dev/null || true
  echo "  Removed agnhost-ipvrf container"
fi

if docker network inspect ${IPVRF_AGNHOST_NETWORK} &>/dev/null; then
  docker network rm ${IPVRF_AGNHOST_NETWORK} 2>/dev/null || true
  echo "  Removed ${IPVRF_AGNHOST_NETWORK} network"
fi

# ============================================================================
# Done
# ============================================================================
echo ""
echo "=== L2 MAC-VRF + IP-VRF Cleanup Complete ==="
echo ""
echo "Verify cleanup:"
echo "  kubectl get clusteruserdefinednetwork"
echo "  kubectl get ns evpn-l2-combo-test"
echo "  docker exec frr ip link show br0"
echo "  docker ps | grep agnhost"

