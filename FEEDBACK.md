# FLOP devnet: five policy choices with unintended consequences for home miners

Feedback for Flop Labs' call for criticism ahead of the testnet (20 Nov 2026), from running a home miner (RTX 5080, Windows + WSL, official images only) from 7 Nov 2026 until I paused it this week. I wrote and maintain this repo, a public guide for mining FLOP devnet on a gaming PC. My post about mining FLOP on a home RTX 5080 was quote-posted by Arthur Hayes, and people now follow the guide, so these issues hit more than one machine.

Miner: `5ECEvG31hJ6jprGcAYRHMchj98k4c4A3RAGvNqGynx4ffKvW` (Soft tier, 28 GFLOP/s). All times UTC. Channel and reliability data come from the public indexer (`mcp.flop.network`); everything else comes from the worker's own logs.

---

## 1. Timeouts during a network-wide upgrade count against the miner, and routing never recovers

**What happened**
- The last settled channel opened on 11 Nov at 16:41. The chain moved to runtime `1014020` around then.
- From 11 Nov 16:49 to 12 Nov 15:54, all **50** channels opened to me timed out, while my worker was still on the previous release.
- I moved to worker v0.1.336 on 12 Nov at about 18:20. Between 12 Nov 15:54 and when I paused the miner this week, the gateway opened **one** channel to me (14 Nov 04:04). On 20 Nov that channel was still `open` with `evidenceStatus: NONE`.
- Through that whole period the miner was registered, staked, reachable from the internet, not fenced, and completing 100% of its test jobs.

**Unintended consequence:** one late update during an upgrade benches a miner indefinitely. The miner can't see that it's benched (the dashboard is green and every check passes), and there's no visible way back. From the outside it looks exactly like "the network doesn't want my GPU".

**Suggestions**
- Don't count timeouts that happen while the miner's image is older than the runtime (or during a declared upgrade window), or weight them far less.
- Let the penalty decay, or let a passing probe or test job restore eligibility.
- Expose routing state per miner (eligible, or backoff until X, and why) in the indexer or API.

## 2. The chain runtime moves ahead of releases.json

**What happened**
- **7 Nov:** the chain went to runtime `1014014` while `releases.json` still listed CLI v0.1.220, which supports up to `1014003`. Model verification failed for anyone following the manifest.
- **11 Nov:** the chain went to `1014020` while `releases.json` listed CLI v0.1.321, which stops at `1014014` (`RUNTIME_INCOMPATIBLE`). The first CLI that worked, v0.1.342, was published to ghcr but not listed.
- An older worker kept running, kept its endpoint ad live and kept getting channels, and every one timed out. That fed straight into #1.
- Today the chain is on `1014031` and `releases.json` lists v0.1.418, so the manifest has caught up this time.

**Unintended consequence:** operators who do the right thing (official images, pinned digests from the manifest) are the ones who break, and the breakage turns into reputation damage.

**Suggestions**
- Publish compatible images in `releases.json` before enacting a runtime upgrade.
- When the worker sees an unsupported spec version, it should withdraw its endpoint ad and log loudly, instead of accepting sessions it can't settle.

## 3. The worker doesn't recover from an RPC websocket drop

**What happened**
- On 12 Nov at 16:01 and 19:20, the worker logged `API-WS: disconnected … 1006 Abnormal Closure`, then `WebSocket is not connected`. After that it logged nothing for hours (2 h the second time) and served nothing until restarted by hand. The container stayed `Up`.
- I now run a small external watchdog that restarts the worker 3 minutes after a drop if it has stayed silent since. It has had to act 7 times in 2 days: 13 Nov 02:43, 03:04, 08:37, 09:08, 21:00; 14 Nov 13:55, 14:33.
- The connection is Ethernet, and Windows logged no adapter disconnects at those times.

**Unintended consequence:** a transient network blip turns into hours of a dead worker whose endpoint is still advertised. Sessions sent to it time out, and that's #1 again.

**Suggestions**
- Reconnect with backoff (the API provider's auto-reconnect), or exit non-zero so Docker's restart policy recovers it.
- Report chain-connection state in the worker's health and readiness, and withdraw the ad while disconnected.

## 4. Clearing a signer fence needs a third-party tool

**What happened**
- An RPC drop while a transaction is in flight fences the signer. The worker answers `503`, and restarts and updates don't clear it.
- On 10 Nov that cost about 6 hours with no sessions. On 12 Nov the worker was fenced again, and the community guard ([UfukNode/flop-miner-setup](https://github.com/UfukNode/flop-miner-setup), fence-guard) had already used its 3 safe unlocks in 6 hours.

**Unintended consequence:** recovery depends on a community script or on manual work, and each fenced hour also looks like unreliability.

**Suggestion:** have the worker reconcile the fence itself once the stuck transaction provably can't be included (mortality expired, nothing pending, no open session).

## 5. The CLI's 10-second connect timeout vs. 1 MB of chain metadata

**What happened**
- `state_getMetadata` is about 974 KB. On 17 Nov it took 6–11 seconds over a normal connection (measured 5 times).
- A new user following my guide failed setup three times in a row with `MODEL_VERIFICATION_FAILED: RPC unreachable … timed out after 10 seconds`.

**Unintended consequence:** onboarding fails for slower or more distant connections, which are exactly the home miners a consumer-GPU network wants.

**Suggestion:** raise the init timeout (30–60 s), retry with backoff, or ship the metadata for known spec versions with the CLI.

---

Happy to share raw logs or test fixes. This guide's `update` command, chain watchdog and `RUNTIME_INCOMPATIBLE` detection exist because of #1–#3, and I'd much rather delete them than maintain them.
