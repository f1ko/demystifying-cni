#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

SEC("xdp")
int xdp_drop_ipv4(struct xdp_md *ctx) {
  // define variables that represent the packet
  void *packet_start = (void *)(long)ctx->data;
  void *packet_end = (void *)(long)ctx->data_end;
  struct ethhdr *eth = packet_start;

  // satisfy eBPF verifier
  if (packet_start + sizeof(*eth) > packet_end)
    return XDP_PASS;

  // find out the next protocol
  __u16 protocol = eth->h_proto;

  // drop all IPv4 packets
  if (protocol == bpf_htons(ETH_P_IP))
      return XDP_DROP;

  // pass all other packets
  return XDP_PASS;
}

char LICENSE[] SEC("license") = "GPL";
