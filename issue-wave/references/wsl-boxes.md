# WSL boxes

Use this note only when a placement's `kind_of` is `wsl`. Native Ubuntu starts sshd at boot,
needs no Windows-side holder, and has no dxg bridge cap.

What follows are properties of WSL on these boxes that a worker lives with. A defect in the
fleet's own tooling is not one of them: it gates the wave items on its path ([Decision
gate](../SKILL.md#decision-gate-before-launch-batched-fatigue-aware)).

After WoL, the Windows host may answer while the WSL guest is absent. Start WSL just before
launching the worker: `wake-lab.sh --wait --wsl --hold <box>` (or use
`--restart-wsl` in place of `--wsl` when a fresh VM is required). The holder remains until
`wake-lab.sh unhold <box>`; an ssh session inside the guest does not keep the VM alive.
Check `wake-lab.sh status <box>` for the OS actually reached and the guest probe.

The WSL CUDA/HIP PATH prefix in `tools/sweep.sh` is needed for non-login shells. In the worker
brief, name the backend, require evidence that it ran on that backend, and keep one dune per
`_build`. A single-process GPU probe does not rule out dxg bridge refusal under concurrent
GPU processes. The per-box `FLEET_BOX_CORRECTNESS_SLOTS` value of one for WSL boxes is the
measured limit; a fresh VM alone does not raise it. See `scripts/wake-lab-wsl.sh` for the
Windows-side restart, holder, active-hours and dxg observations.
