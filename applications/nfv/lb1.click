// lb1.click — Load balancer (IK2221 Phase 1)
// VIP 100.0.0.45:80, round-robin to 100.0.0.40–42; ICMP echo to VIP.
// lb1-eth1 = client/IDS side; lb1-eth2 = server (sw3) side.
// Set interface MACs in Mininet (see topology startup_services) to match $MAC1 / $MAC2.

define($ETH1 lb1-eth1, $ETH2 lb1-eth2)
define($VIP 100.0.0.45)
define($MAC1 02-00-00-00-01-45)
define($MAC2 02-00-00-00-02-45)

AddressInfo(
  lb1_out  $VIP  100.0.0.0/24  $MAC1,
  lb2_out  $VIP  100.0.0.0/24  $MAC2
);

rr :: RoundRobinIPMapper(
  "- - 100.0.0.40 80 0 1",
  "- - 100.0.0.41 80 0 1",
  "- - 100.0.0.42 80 0 1"
);

// Input 0: new client flows; input 1: return traffic (mapping table consulted first).
tcp_rw :: IPRewriter(rr, pass 1);

arq1 :: ARPQuerier(lb1_out);
arq2 :: ARPQuerier(lb2_out);

elementclass Meter {
  input -> ac::AverageCounter -> cnt::Counter -> output;
}

fd1 :: FromDevice($ETH1, SNIFFER false, METHOD LINUX, PROMISC true)
fd2 :: FromDevice($ETH2, SNIFFER false, METHOD LINUX, PROMISC true)

td1 :: ToDevice($ETH1, METHOD LINUX)
td2 :: ToDevice($ETH2, METHOD LINUX)

m1_in  :: Meter;
m2_in  :: Meter;
m1_out :: Meter;
m2_out :: Meter;

cnt_arp_req_c  :: Counter;
cnt_arp_rep_c  :: Counter;
cnt_arp_req_s  :: Counter;
cnt_arp_rep_s  :: Counter;
cnt_svc_tcp_c  :: Counter;
cnt_icmp_echo  :: Counter;
cnt_drop_c     :: Counter;
cnt_drop_s     :: Counter;
cnt_other_l2_c :: Counter;
cnt_other_l2_s :: Counter;

fd1 -> m1_in -> c1 :: Classifier(12/0806 20/0001, 12/0806 20/0002, 12/0800, -);
fd2 -> m2_in -> c2 :: Classifier(12/0806 20/0001, 12/0806 20/0002, 12/0800, -);

// Merge Ethernet sources bound for eth1 (ARPResponder is FIFO[0], ARPQuerier is LIFO[1]).
eth1_tx :: MixedQueue(2048);
// Merge IP streams into one ARPQuerier (TCP replies FIFO, ICMP replies LIFO).
ip_to_arq1 :: MixedQueue(2048);

c1[0]  -> cnt_arp_req_c
       -> ARPResponder($VIP/32 $MAC1)
       -> [0]eth1_tx;

c1[1]  -> cnt_arp_rep_c
       -> [1]arq1;

c1[2]  -> Strip(14)
       -> MarkIPHeader(0)
       -> CheckIPHeader(INTERFACES 100.0.0.0/24)
       -> ipc :: IPClassifier(dst host $VIP and icmp type echo,
                              dst host $VIP and tcp dst port 80,
                              -);

ipc[0] -> cnt_icmp_echo
       -> icmppr :: ICMPPingResponder;
icmppr[0] -> [1]ip_to_arq1;
icmppr[1] -> Discard;

ipc[1] -> cnt_svc_tcp_c
       -> [0]tcp_rw;

ipc[2] -> cnt_drop_c
       -> Discard;

c1[3]  -> cnt_other_l2_c
       -> Discard;

tcp_rw[1] -> [0]ip_to_arq1;
ip_to_arq1 -> [0]arq1 -> [1]eth1_tx;
eth1_tx -> m1_out -> td1;

// ---- Server side (eth2) ----------------------------------------------
eth2_tx :: MixedQueue(2048);

c2[0]  -> cnt_arp_req_s
       -> ARPResponder($VIP/32 $MAC2)
       -> [0]eth2_tx;

c2[1]  -> cnt_arp_rep_s
       -> [1]arq2;

c2[2]  -> Strip(14)
       -> MarkIPHeader(0)
       -> CheckIPHeader(INTERFACES 100.0.0.0/24)
       -> ips :: IPClassifier(tcp, -);

ips[0] -> [1]tcp_rw;

ips[1] -> cnt_drop_s
       -> Discard;

c2[3]  -> cnt_other_l2_s
       -> Discard;

tcp_rw[0] -> [0]arq2 -> [1]eth2_tx;
eth2_tx -> m2_out -> td2;

ScheduleInfo(fd1 .1, td1 1, fd2 .1, td2 1);

DriverManager(
  print "=================== LB1 Report ===================",
  print "eth1 in avg pps:", $(m1_in/ac.rate),
  print "eth1 in pkts:", $(m1_in/cnt.count),
  print "eth2 in avg pps:", $(m2_in/ac.rate),
  print "eth2 in pkts:", $(m2_in/cnt.count),
  print "eth1 out avg pps:", $(m1_out/ac.rate),
  print "eth1 out pkts:", $(m1_out/cnt.count),
  print "eth2 out avg pps:", $(m2_out/ac.rate),
  print "eth2 out pkts:", $(m2_out/cnt.count),
  print "ARP requests (client if):", $(cnt_arp_req_c.count),
  print "ARP replies (client if):", $(cnt_arp_rep_c.count),
  print "ARP requests (server if):", $(cnt_arp_req_s.count),
  print "ARP replies (server if):", $(cnt_arp_rep_s.count),
  print "Service TCP (client->VIP:80):", $(cnt_svc_tcp_c.count),
  print "ICMP echo to VIP:", $(cnt_icmp_echo.count),
  print "Dropped IP (client if, non-echo/non-:80):", $(cnt_drop_c.count),
  print "Dropped IP (server if, non-TCP):", $(cnt_drop_s.count),
  print "Non-IP/L2 drops (eth1):", $(cnt_other_l2_c.count),
  print "Non-IP/L2 drops (eth2):", $(cnt_other_l2_s.count),
  print "IPRewriter mapping failures:", $(tcp_rw.mapping_failures),
  pause,
);
