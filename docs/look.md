## What it looks like

`logcollector -n -s "2 hours ago"` on a desktop with a couple of failing units:

```
logcollector summary (since 2 hours ago)

err      1 lines
warning  44 lines

failed units:
  cachyos-iw-set-regdomain.service     loaded failed failed Set Wireless Regulatory Domain on Timezone Change
  systemd-networkd-wait-online.service loaded failed failed Wait for Network to be Online

most repeated errors:
  1   entries --

skipped:
  coredumps.txt: no output (needs privileges, or nothing logged)
```

`sniff -` on a few lines of `tcpdump -nn` output (sample, a synthetic capture):

```
9 packets, 3.2 KiB in 4.4s (749.318 B/s)

protocols
  icmp         1 packets        64 B
  udp          4 packets       240 B
  arp          1 packets        28 B
  tcp          3 packets     2.9 KiB

busiest conversations
     1.9 KiB  142.250.74.46 <-> 192.168.1.10
      1000 B  2001:db8::1 <-> 2001:db8::2

services
     2.9 KiB  tcp/https (443)
       74 B  udp/dns (53)

DNS names asked
           1  example.com.
```
