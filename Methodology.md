### SWE-agent shows that tool/interface design alone can materially change coding-agent quality:

*Note: these results use old models, so exact effect sizes may differ on current models...*

- A dedicated edit tool improved 10.3% -> 15.0%, adding lint feedback improved it to 18.0%.[^1]
- A bad search tool actually hurt (15.7% no-search -> 12.0%), while a summarized search reached 18.0%.[^1]
- Showing 100 lines of a file beat showing the whole file (18.0% vs 12.7%).[^1]

[^1]: SWE-agent — [arXiv](https://arxiv.org/abs/2405.15793) · [OpenReview](https://openreview.net/pdf?id=mXpq6ut8J3)

Crab shows that giving terminal agents an explicit checkpoint/rollback mechanism materially improves recovery: on shell/code-repair workloads it raised recovery correctness from 8% to 100% while keeping overhead within 1.9% of fault-free execution.

### Checkpoint / rollback

Checkpoint-and-rollback has measurable value beyond convenience: **Crab** reports recovery correctness improving from **8% with chat-only recovery to 100% with checkpoint/restore** on shell-intensive and code-repair workloads, while remaining within **1.9% of fault-free execution time**.[^crab]

[^crab]: *Crab: A Semantics-Aware Checkpoint/Restore Runtime for Agent Sandboxes* — [arXiv:2604.28138](https://arxiv.org/abs/2604.28138)
