#!/usr/bin/env python3
"""train.py: a real multi-node training job (ai-train.sh runs it as an Indexed Job).

PyTorch DistributedDataParallel on CPU, one rank per GPU node, gloo backend: every optimiser step ends with an all-reduce of the gradients
between all ranks over the interface named by GLOO_SOCKET_IFNAME (a backend rail). The dataset shards and the checkpoints live on a shared
volume (DATA_DIR, a ReadWriteMany PVC), so the job also produces the storage traffic of a training run: shard reads at the start, a
checkpoint write per epoch. Everything is small on purpose (2 vCPU nodes); the traffic pattern is the point, not the model.

env: RANK, WORLD_SIZE, MASTER_ADDR (rank 0's rail address), MASTER_PORT, GLOO_SOCKET_IFNAME, DATA_DIR, EPOCHS, STEPS, HIDDEN
"""
import hashlib, json, os, socket, sys, time
import torch, torch.distributed as dist, torch.nn as nn

RANK, WORLD = int(os.environ["RANK"]), int(os.environ["WORLD_SIZE"])
DATA = os.environ.get("DATA_DIR", "/data"); EPOCHS = int(os.environ.get("EPOCHS", 3)); STEPS = int(os.environ.get("STEPS", 10))
HIDDEN = int(os.environ.get("HIDDEN", 768)); IFN = os.environ.get("GLOO_SOCKET_IFNAME", "eth0"); BATCH = 64; FEAT, CLASSES, SHARD_N = 512, 10, 20000
torch.manual_seed(1234); torch.set_num_threads(2)

def log(msg): print(f"[rank {RANK} {socket.gethostname()} {time.strftime('%H:%M:%S')}] {msg}", flush=True)
def ifbytes():
    for l in open("/proc/net/dev"):
        if l.strip().startswith(IFN + ":"): f = l.split(":")[1].split(); return int(f[0]), int(f[8])
    return 0, 0

os.makedirs(f"{DATA}/dataset", exist_ok=True); os.makedirs(f"{DATA}/checkpoints", exist_ok=True)
shard = f"{DATA}/dataset/shard-{RANK}.pt"
if RANK == 0:      # rank 0 stages the dataset on the shared volume: one shard per rank (a fixed teacher network labels random features)
    t0 = time.time(); g = torch.Generator().manual_seed(7); teacher = torch.randn(FEAT, CLASSES, generator=g)
    for r in range(WORLD):
        p = f"{DATA}/dataset/shard-{r}.pt"
        if not os.path.exists(p):
            x = torch.randn(SHARD_N, FEAT, generator=g); y = (x @ teacher).argmax(1); torch.save({"x": x, "y": y}, p + ".tmp"); os.replace(p + ".tmp", p)
    log(f"dataset staged on {DATA}/dataset: {WORLD} shards x {os.path.getsize(shard) / 1e6:.1f} MB in {time.time() - t0:.1f} s")
for _ in range(120):
    if os.path.exists(shard): break
    time.sleep(1)
t0 = time.time(); d = torch.load(shard); X, Y = d["x"], d["y"]
log(f"shard loaded from the shared volume: {shard} ({os.path.getsize(shard) / 1e6:.1f} MB, {len(X)} samples) in {time.time() - t0:.2f} s")

rx0, tx0 = ifbytes(); t0 = time.time()
dist.init_process_group(backend="gloo", init_method=f"tcp://{os.environ['MASTER_ADDR']}:{os.environ.get('MASTER_PORT', '29500')}", rank=RANK, world_size=WORLD)
log(f"process group up: backend gloo over {IFN}, world size {WORLD}, rendezvous tcp://{os.environ['MASTER_ADDR']}:{os.environ.get('MASTER_PORT', '29500')} ({time.time() - t0:.1f} s)")
model = nn.Sequential(nn.Linear(FEAT, HIDDEN), nn.ReLU(), nn.Linear(HIDDEN, HIDDEN), nn.ReLU(), nn.Linear(HIDDEN, CLASSES))
nparam = sum(p.numel() for p in model.parameters())
ddp = nn.parallel.DistributedDataParallel(model); opt = torch.optim.SGD(ddp.parameters(), lr=0.05, momentum=0.9); lossf = nn.CrossEntropyLoss()
log(f"model: {nparam:,} parameters = {nparam * 4 / 1e6:.1f} MB of gradients all-reduced per step; {EPOCHS} epochs x {STEPS} steps, batch {BATCH} per rank")
first = last = None; step = 0
for ep in range(1, EPOCHS + 1):
    te = time.time(); perm = torch.randperm(len(X), generator=torch.Generator().manual_seed(ep * 100 + RANK)); el = 0.0
    for i in range(STEPS):
        idx = perm[i * BATCH:(i + 1) * BATCH]; ts = time.time()
        opt.zero_grad(); loss = lossf(ddp(X[idx]), Y[idx]); loss.backward()      # backward() runs the all-reduce of the gradients over the rail
        opt.step(); step += 1; v = loss.item(); el += v; first = v if first is None else first; last = v
        if i == 0 or i == STEPS - 1: log(f"epoch {ep} step {i + 1}/{STEPS}: loss {v:.4f}, step time {1000 * (time.time() - ts):.0f} ms")
    rx, tx = ifbytes()
    log(f"epoch {ep} done in {time.time() - te:.1f} s: mean loss {el / STEPS:.4f}; {IFN} so far rx {(rx - rx0) / 1e6:.1f} MB, tx {(tx - tx0) / 1e6:.1f} MB")
    if RANK == 0:
        tc = time.time(); p = f"{DATA}/checkpoints/epoch-{ep}.pt"; torch.save(model.state_dict(), p)
        log(f"checkpoint written to the shared volume: {p} ({os.path.getsize(p) / 1e6:.1f} MB) in {time.time() - tc:.2f} s")
dist.barrier()
h = hashlib.sha256(b"".join(p.detach().numpy().tobytes() for p in model.parameters())).hexdigest()[:16]
rx, tx = ifbytes()
res = dict(rank=RANK, host=socket.gethostname(), world=WORLD, steps=step, first_loss=round(first, 4), last_loss=round(last, 4), params=nparam, weights_sha=h,
           rail_if=IFN, rail_rx_mb=round((rx - rx0) / 1e6, 1), rail_tx_mb=round((tx - tx0) / 1e6, 1))
log("RESULT " + json.dumps(res))
dist.destroy_process_group()
