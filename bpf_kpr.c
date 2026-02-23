#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

SEC("cgroup/connect4")
int sock4_connect(struct bpf_sock_addr *ctx)
{
  const __be32 cluster_ip = 0x0A600064; // 10.96.0.100
  const __be32 pod_ip = 0x0AF40014;     // 10.244.0.20

  if (ctx->user_ip4 == __bpf_htonl(cluster_ip)) {
      ctx->user_ip4 = __bpf_htonl(pod_ip);
  }

  return 1;
}

char LICENSE[] SEC("license") = "GPL";
