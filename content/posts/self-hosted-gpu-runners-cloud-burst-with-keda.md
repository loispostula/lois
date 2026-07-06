+++
title = "Self-hosted GPU runners that burst to the cloud with KEDA"
author = ["Loïs Postula"]
publishDate = 2026-07-06T00:00:00+02:00
draft = false
tags = ["kubernetes", "keda", "gpu", "nixos", "k3s"]
+++

GPU compute is expensive to rent and awkward to own. Simulation work makes it
worse: the queue is empty for hours, then a batch of jobs lands and everything
is needed at once. Paying cloud GPU prices around the clock for a workload that
is bursty by nature is hard to justify. Sizing an on-premise fleet for the peak
means most of the cards sit idle most of the time.

The setup below splits the difference: own the baseline, rent the peaks — and
fail over to the cloud when the owned hardware misbehaves. A small pool of
self-hosted GPU nodes in a [k3s](https://k3s.io/) cluster carries the
steady-state load. When the pool cannot keep up, or goes down entirely,
[KEDA](https://keda.sh/) scales extra GPU jobs into a cloud Kubernetes cluster,
then scales them back to zero once the primary recovers. You pay cloud rates
only for the peaks and outages you actually hit.


## Why not just pick one {#why-not-just-pick-one}

-   **Pure cloud GPU.** Simple to operate, but you pay a premium 24/7 for
    capacity you use in bursts, and you inherit quota and availability limits on
    the exact instance types you need.
-   **Pure on-premise.** Cheap per hour once bought, but capacity is fixed. The
    moment demand exceeds the cards you own, jobs queue behind them and there is
    no relief valve.

The hybrid keeps the cheap, always-on baseline on hardware you control and
treats the cloud as an overflow buffer that costs nothing when idle.


## The hard part: GPUs in containers on NixOS {#gpus-in-containers-on-nixos}

Scheduling GPU pods is easy. Making the GPU actually usable *inside* the
container on NixOS is where the time goes.

The nodes run NixOS and join k3s. GPU access is wired through the
[Container Device Interface (CDI)](https://github.com/cncf-tags/container-device-interface)
rather than the legacy runtime hook:

```nix
hardware.nvidia-container-toolkit = {
  enable = true;
  mount-nvidia-executables = true;
  # UUID device names so the k8s-device-plugin's CDI annotations match
  # the kind registered by the NixOS CDI generator (nixpkgs#288037).
  extraArgs = [ "--device-name-strategy=uuid" ];
};
```

The NVIDIA [k8s-device-plugin](https://github.com/NVIDIA/k8s-device-plugin) runs
as a DaemonSet and advertises `nvidia.com/gpu` on the GPU nodes.

The part that cost real debugging time: our workload renders through
Vulkan/`wgpu`, and NixOS's auto-generated CDI spec omits the Vulkan ICD, the EGL
vendor config, and the glvnd dispatcher libraries. Without them the driver
refuses to expose a Vulkan instance and the workload reports "no GPU adapter"
despite a healthy `nvidia-smi`. The fix is to bind-mount them into the container
at distro-standard paths (see nixpkgs#383085 for the upstream discussion):

```nix
hardware.nvidia-container-toolkit.mounts = [
  { hostPath = "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json";
    containerPath = "/etc/vulkan/icd.d/nvidia_icd.json"; }
  { hostPath = "/run/opengl-driver/lib/libEGL.so.1";
    containerPath = "/usr/lib/x86_64-linux-gnu/libEGL.so.1"; }
  # ... glvnd dispatchers (libGLX, libOpenGL, libGLdispatch) at the multiarch path
];
```

GPU nodes are tainted so only GPU work lands on them; the workload tolerates the
taint and selects the pool by label:

```yaml
nodeSelector:
  payload: task_runner
tolerations:
  - key: sku
    operator: Equal
    value: gpu
    effect: NoSchedule
```


## The fallback: burst and failover {#burst-and-failover}

The baseline runner is an ordinary workload pinned to the self-hosted GPU pool,
kept at a minimum of one replica so there is always something draining the
queue.

The cloud tier is not only for peaks. It covers two different failures, and the
same KEDA `ScaledJob` handles both with two triggers, scaling from zero:

1.  **Backlog.** The self-hosted pool is healthy but outpaced — more work
    arrived than the owned cards can drain in time. This is the "rent the peak"
    case.
2.  **Outage.** The self-hosted pool is down or erroring and draining nothing at
    all. This is the "keep running when the datacentre doesn't" case.

Queue depth alone only half-covers the outage: if the on-prem workers stop
consuming, the queue eventually grows and trips the backlog trigger. But a
growing queue is ambiguous — it could be a large batch or a dead cluster — and
waiting for the backlog to cross a threshold is slow when the pool is actually
down. So the fallback also watches a health signal: a Prometheus query for the
rate at which the primary pool is consuming work. If that rate drops to zero
while jobs are pending, KEDA fails over to the cloud immediately, without waiting
for the backlog to build.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: sim-fallback
spec:
  jobTargetRef:
    template:
      spec:
        nodeSelector: { payload: task_runner }
        tolerations:
          - { key: sku, operator: Equal, value: gpu, effect: NoSchedule }
        containers:
          - name: worker
            image: registry.example.com/blast-sim:latest   # sanitized
  pollingInterval: 1
  maxReplicaCount: 10          # cost guardrail — cap the burst
  triggers:
    # 1. Backlog: on-prem healthy but outpaced
    - type: rabbitmq
      metadata:
        queueName: sim-jobs
        mode: QueueLength
        value: "1"
    # 2. Outage: on-prem down or not consuming while work is pending
    #    (illustrative PromQL — the real query lives in our metrics backend)
    - type: prometheus
      metadata:
        serverAddress: https://metrics.example.com/prometheus
        threshold: "1"
        query: |
          (sum(sim_jobs_ready) > 0)
          and (sum(rate(sim_jobs_processed_total{pool="self-hosted"}[2m])) == 0)
```

KEDA scales on whichever trigger is hotter, so a backlog and an outage both push
jobs to the cloud, and everything drains back to zero once the primary pool
recovers.

The same shape composes into tiers ordered by cost. The primary is the
self-hosted GPU pool; the cloud is the last-resort failover. A second
self-hosted site can sit between them as a cheaper failover before you reach for
cloud pricing — each tier is just another scale target with its own health
trigger.


## Cost guardrails and failure modes {#cost-guardrails-and-failure-modes}

Scaling to zero is only safe if the edges are handled:

-   **Cap the burst.** `maxReplicaCount` is a spend limit as much as a scaling
    limit — a runaway or poison-pill queue should not be able to spend the month
    in an afternoon.
-   **Cold starts are real.** A fresh cloud GPU node pulling a multi-gigabyte
    CUDA image adds minutes before the first job runs. Tune `pollingInterval`
    and cooldown against how long a job takes and how much queue latency is
    acceptable.
-   **Draining and stuck jobs.** GPU jobs do not preempt cleanly; set a
    `backoffLimit` and make jobs idempotent so a killed burst node re-queues
    rather than corrupts.
-   **Watch the right signals.** Queue depth, GPU utilization on the baseline
    pool, and cost-per-burst are the three graphs that tell you whether the
    split is tuned correctly.


## Closing {#closing}

Owning the baseline and renting only the peaks and outages turns GPU capacity
from a fixed, oversized bill into something that tracks real demand. The
self-hosted pool stays busy and cheap; the cloud exists for the moments it is
not enough, or not there. Underneath it is deliberately boring: a queue, a
health metric, and a fallback that scales to zero — which is exactly why it
holds up in production.
