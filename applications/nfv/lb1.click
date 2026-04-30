// lb1.click — Load Balancer (IK2221 Phase 1)
// VIP 100.0.0.45:80, round-robin to llm1(100.0.0.40), llm2(.41), llm3(.42).
// lb1-eth1 = client/IDS side;  lb1-eth2 = server/sw3 side.
//
// Mininet startup_services sets lb1-eth1 MAC = 02:00:00:00:01:45
//                              lb1-eth2 MAC = 02:00:00:00:02:45
//
// Proxy-ARP on eth2 (100.0.0.0/24): the LLM servers send replies toward 100.0.0.1
// (the NAPT inf-side address), which is in the same /24. Without proxy-ARP, their
// ARP for 100.0.0.1 goes unanswered and the return path breaks. lb1 answers for the
// whole inferencing subnet so all return traffic is intercepted and rewritten by
// the IPRewriter mapping table.

define($ETH1 lb1-eth1, $ETH2 lb1-eth2)
define($VIP 100.0.0.45)
define($MAC1 02:00:00:00:01:45)
define($MAC2 02:00:00:00:02:45)

AddressInfo(
  lb1_client  $VIP  100.0.0.0/24  $MAC1,
  lb1_server  $VIP  100.0.0.0/24  $MAC2
);

// Round-robin mapper: new client→VIP flows are distributed across the three backends.
// Pattern format: SADDR SPORT DADDR DPORT FOUTPUT ROUTPUT
// "-" keeps the original field. Forward exits at 0, reverse at 1.
rr :: RoundRobinIPMapper(
  - - 100.0.0.40 80 0 1,
  - - 100.0.0.41 80 0 1,
  - - 100.0.0.42 80 0 1
);

// IPRewriter input 0: new client flows (apply rr mapper).
// IPRewriter input 1: server return flows (hit reverse mapping, rewrite src back to VIP).
tcp_rw :: IPRewriter(rr, pass 1);

arq1 :: ARPQuerier(lb1_client);   // resolves MACs on the client/IDS side
arq2 :: ARPQuerier(lb1_server);   // resolves MACs on the server/sw3 side

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

// ---- Client side (eth1) -----------------------------------------------
fd1 -> m1_in -> c1 :: Classifier(12/0806 20/0001, 12/0806 20/0002, 12/0800, -);

// MixedQueue merges two push sources into one pull stream toward ToDevice.
eth1_tx :: MixedQueue(2048);
// ICMP + TCP return toward the client: both are push; fan in directly to ARPQuerier[0]
// (MixedQueue is pull output -> incompatible with ARPQuerier push input; see napt.click).

// ARP request for VIP -> answer immediately with MAC1
c1[0] -> cnt_arp_req_c
       -> ARPResponder($VIP/32 $MAC1)
       -> [0]eth1_tx;

// ARP reply -> update ARPQuerier cache
c1[1] -> cnt_arp_rep_c
       -> [1]arq1;

// IPv4: strip Ethernet, validate IP header, then classify
c1[2] -> Strip(14)
       -> MarkIPHeader(0)
       -> CheckIPHeader(INTERFACES 100.0.0.0/24)
       -> ipc :: IPClassifier(
              dst host $VIP and icmp type echo,
              dst host $VIP and tcp dst port 80,
              -);

// ICMP echo to VIP -> synthesise reply locally
ipc[0] -> cnt_icmp_echo
       -> icmppr :: ICMPPingResponder;
icmppr -> [0]arq1;  // IP reply -> same push input as TCP reverse

// TCP to VIP:80 -> round-robin rewrite
ipc[1] -> cnt_svc_tcp_c
       -> [0]tcp_rw;

// Other IP to eth1 -> drop
ipc[2] -> cnt_drop_c
       -> Discard;

// Non-IP/non-ARP -> drop
c1[3] -> cnt_other_l2_c
       -> Discard;

// IPRewriter reverse output (server→client after VIP rewrite) -> arq1 -> eth1
tcp_rw[1] -> [0]arq1;
arq1 -> [1]eth1_tx;
eth1_tx -> m1_out -> td1;

// ---- Server side (eth2) -----------------------------------------------
eth2_tx :: MixedQueue(2048);

fd2 -> m2_in -> c2 :: Classifier(12/0806 20/0001, 12/0806 20/0002, 12/0800, -);

// Proxy-ARP for the whole inferencing subnet: LLM servers send replies addressed
// to 100.0.0.1 (NAPT inf side, same /24). lb1 answers all such ARP requests with
// MAC2 so return traffic is delivered here and hits the IPRewriter reverse mapping.
c2[0] -> cnt_arp_req_s
       -> ARPResponder(100.0.0.0/24 $MAC2)
       -> [0]eth2_tx;

c2[1] -> cnt_arp_rep_s
       -> [1]arq2;

c2[2] -> Strip(14)
       -> MarkIPHeader(0)
       -> CheckIPHeader(INTERFACES 100.0.0.0/24)
       -> ips :: IPClassifier(tcp, -);

// TCP from server -> IPRewriter input 1 (reverse mapping lookup)
ips[0] -> [1]tcp_rw;

// Non-TCP from server -> drop
ips[1] -> cnt_drop_s
       -> Discard;

c2[3] -> cnt_other_l2_s
       -> Discard;

// IPRewriter forward output (client→backend, dst rewritten to llm) -> arq2 -> eth2
tcp_rw[0] -> [0]arq2 -> [1]eth2_tx;
eth2_tx -> m2_out -> td2;

ScheduleInfo(fd1 .1, td1 1, fd2 .1, td2 1);

DriverManager(
  print "LB1 starting (VIP=100.0.0.45 -> llm1/llm2/llm3)",
  pause,
  print "=================== LB1 Report ===================",
  print "eth1 in  avg pps:              ", read m1_in/ac.rate,
  print "eth1 in  total pkts:           ", read m1_in/cnt.count,
  print "eth2 in  avg pps:              ", read m2_in/ac.rate,
  print "eth2 in  total pkts:           ", read m2_in/cnt.count,
  print "eth1 out avg pps:              ", read m1_out/ac.rate,
  print "eth1 out total pkts:           ", read m1_out/cnt.count,
  print "eth2 out avg pps:              ", read m2_out/ac.rate,
  print "eth2 out total pkts:           ", read m2_out/cnt.count,
  print "ARP requests  (client side):   ", read cnt_arp_req_c.count,
  print "ARP replies   (client side):   ", read cnt_arp_rep_c.count,
  print "ARP requests  (server side):   ", read cnt_arp_req_s.count,
  print "ARP replies   (server side):   ", read cnt_arp_rep_s.count,
  print "Service TCP   (client→VIP:80): ", read cnt_svc_tcp_c.count,
  print "ICMP echo to VIP:              ", read cnt_icmp_echo.count,
  print "IP drops      (client side):   ", read cnt_drop_c.count,
  print "IP drops      (server side):   ", read cnt_drop_s.count,
  print "L2 drops      (client side):   ", read cnt_other_l2_c.count,
  print "L2 drops      (server side):   ", read cnt_other_l2_s.count,
  print "IPRewriter mapping failures:   ", read tcp_rw.mapping_failures,
);
