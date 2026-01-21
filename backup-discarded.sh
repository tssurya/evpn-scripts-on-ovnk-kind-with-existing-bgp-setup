#!/bin/bash
# =============================================================================
# DISCARDED - Type-5 Route Workaround (Manual FDB/ARP/Route programming)
# This was a workaround that manually programs the data plane
# NOT needed when proper EVPN BGP config is used
# =============================================================================

# header "Configure Type-5 Route Workaround"
# 
# ROUTER_MAC=$(docker exec frr ip link show br0.$VID | grep "link/ether" | awk '{print $2}')
# echo "Router MAC: $ROUTER_MAC"
# 
# VTEP_IP="$FRR_IP"
# 
# NETWORK_ID=$(kubectl get net-attach-def -n evpn-l3-test evpn-l3-test -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/network-id}' 2>/dev/null)
# 
# kubectl get pods -l app=ovnkube-node -n ovn-kubernetes -o custom-columns=POD:.metadata.name --no-headers | while read POD; do
#   echo "=== Applying Type-5 workaround on $POD ==="
#   
#   VRFNAME=$(kubectl exec -n ovn-kubernetes $POD -c ovnkube-controller -- ip -o link show ovn-k8s-mp${NETWORK_ID} 2>/dev/null | grep -oP 'master \K[^ ]+' || echo "mp${NETWORK_ID}-udn-vrf")
#   
#   kubectl exec -n ovn-kubernetes $POD -c ovnkube-controller -- /bin/sh -c "
#     # FDB entry for remote VTEP's router MAC
#     bridge fdb replace $ROUTER_MAC dev vxlan0 dst $VTEP_IP vni $VNI self
#     
#     # Bridge FDB for VLAN
#     bridge fdb add $ROUTER_MAC dev vxlan0 master vlan $VID 2>/dev/null || true
#     
#     # Static ARP entry
#     ip neigh replace $VTEP_IP lladdr $ROUTER_MAC dev br0.$VID nud permanent
#     
#     # Static route for agnhost subnet (bypassing BGP EVPN)
#     ip route replace ${AGNHOST_SUBNET} via $VTEP_IP dev br0.$VID vrf $VRFNAME onlink
#     
#     echo 'Type-5 workaround applied'
#   "
# done
