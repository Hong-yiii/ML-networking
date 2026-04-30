define($PORT1 ids-eth1)
define($PORT2 ids-eth2)
define($PORT3 ids-eth3)

Script(print "IDS starting on $PORT1 $PORT2 $PORT3")

fd1::FromDevice($PORT1, SNIFFER false, METHOD LINUX, PROMISC true)
fd2::FromDevice($PORT2, SNIFFER false, METHOD LINUX, PROMISC true)
fd3::FromDevice($PORT3, SNIFFER false, METHOD LINUX, PROMISC true)

td1::ToDevice($PORT1, METHOD LINUX)
td2::ToDevice($PORT2, METHOD LINUX)
td3::ToDevice($PORT3, METHOD LINUX)

q1::Queue -> td1
q2::Queue -> td2
q3::Queue -> td3

fd1 -> ac_in1::AverageCounter -> cl1::Classifier(
    12/0806,
    12/0800 23/01,
    12/0800 23/06,
    -
);

fd3 -> ac_in3::AverageCounter -> q1
fd2 -> ac_in2::AverageCounter -> q3

cl1[0] -> cnt_arp::Counter -> q3
cl1[1] -> cnt_icmp::Counter -> q3
cl1[3] -> cnt_drop::Counter -> Discard

cl1[2] -> Strip(14) -> MarkIPHeader(0) -> Print(IP-PKT, MAXLENGTH 200) -> ipc::IPClassifier(
    dst port 80,
    src port 80,
    -
);

ipc[1] -> cnt_resp::Counter -> q3
ipc[2] -> cnt_tcpsig::Counter -> Print(TCP-OTHER, MAXLENGTH -1) -> q3

ipc[0] -> Print(HTTP-REQ, MAXLENGTH 200) -> method_cl::Classifier(
    0/504f5354,
    0/50555420,
    -
);

method_cl[0] -> cnt_post::Counter -> q3
method_cl[2] -> cnt_blocked::Counter -> q2

method_cl[1] -> cnt_put::Counter -> payload_cl::Classifier(
    54/636174202f6574632f706173737764,
    54/636174202f7661722f6c6f672f,
    54/494e53455254,
    54/555044415445,
    54/44454c455445,
    -
);

payload_cl[0] -> cnt_mal_passwd::Counter -> q2
payload_cl[1] -> cnt_mal_varlog::Counter -> q2
payload_cl[2] -> cnt_mal_insert::Counter -> q2
payload_cl[3] -> cnt_mal_update::Counter -> q2
payload_cl[4] -> cnt_mal_delete::Counter -> q2
payload_cl[5] -> cnt_put_clean::Counter -> q3

DriverManager(
    print "IDS starting",
    pause,
    print "=== IDS Report ===",
    print "ARP: $(cnt_arp.count)",
    print "ICMP: $(cnt_icmp.count)",
    print "TCP signaling: $(cnt_tcpsig.count)",
    print "HTTP responses: $(cnt_resp.count)",
    print "HTTP POST allowed: $(cnt_post.count)",
    print "HTTP PUT clean: $(cnt_put_clean.count)",
    print "HTTP PUT malicious: $(cnt_mal_passwd.count) + $(cnt_mal_varlog.count) + $(cnt_mal_insert.count) + $(cnt_mal_update.count) + $(cnt_mal_delete.count)",
    print "HTTP blocked methods: $(cnt_blocked.count)",
    print "Dropped: $(cnt_drop.count)",
)
