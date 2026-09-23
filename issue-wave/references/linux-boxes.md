# Native Linux boxes

Use this note when a placement's `kind_of` is `linux`; for `wsl`, see
[wsl-boxes.md](wsl-boxes.md). The boxes run Ubuntu 26.04.1, kernel 7.0.0-31, set up by
`~/self-improve/scripts/install-linux.md`. Each trap below gives its symptom, the check to run,
and its evidence. Every claim was checked by read-only probes on rog-nv-linux,
minix-amd-linux and tuf-amd-linux on 2026-09-23, except where a line says otherwise.

**The environment comes from bash startup, which only some processes run.** Line 1 of
`~/.bashrc`, before Ubuntu's interactive guard, sources `~/.config/fleet/env.sh`. That file
adds the CUDA and tool dirs to `PATH`, then sources `gpu.sh` and opam's `init.sh`. So a
non-login `ssh <box> cmd` resolves what `bash -lc` resolves: `nvcc` on rog
(`/usr/local/cuda/bin`, CUDA 13.4), `hipcc` on minix and tuf (`/usr/bin`), and `ocaml`/`dune`
from the `fleet-5.5.1` switch (OCaml 5.5.1, the Mac's version too). A process not started by
bash on the box gets only its parent's environment. Symptom: `nvcc: not found`, or
`hipcc: not found`, or another OCaml. Check:
`ssh <box> 'command -v nvcc hipcc dune; ocaml -version; echo "ROCM_PATH=${ROCM_PATH-unset} HIP_PATH=${HIP_PATH-unset}"'`.

**HIP: `HIP_PATH=/usr` and `ROCM_PATH` unset.** Ubuntu's HIP 7.1 (`hipcc` over Ubuntu clang 21)
installs under `/usr`, with its device-library bitcode in `/usr/lib/llvm-21/lib/clang/21/amdgcn`.
`/opt/rocm` does not exist on any box. `gpu.sh` sets `HIP_PATH=/usr`, which OCANNL's HIP include
lookup reads (`arrayjit/lib/hip_backend.ml`), and it leaves `ROCM_PATH` unset. Setting
`ROCM_PATH=/usr` stopped `hipcc` finding the bitcode on minix gfx1151, so never export it in a
brief, run script or ssh leg. Check: the probe above prints `ROCM_PATH=unset`, and a sweep log
records a `discovery input: ROCM_PATH=... HIP_PATH=...` line. Evidence: `~/self-improve`
4e9f26906 and the `gpu.sh.before-rocm-path-fix` left on minix and tuf. The failure itself was
not re-run here.

**A HIP result on one AMD box does not stand for the other.** minix is a Radeon 8060S, gfx1151,
an APU whose VRAM is carved out of system memory (amdgpu reports 64 GiB). tuf is a discrete RX
7700S, gfx1102, with 8 GiB of VRAM. rog is an RTX 5070 Ti Laptop GPU with 12 GiB. Each box's role
is under *Inputs* in `issue-wave/SKILL.md`. Take the device from the run log, not from the box's
name. Check: `rocminfo | grep -E "Marketing|gfx"`, or `nvidia-smi -L` on rog.

**Nothing holds a box awake under a run.** GNOME's idle suspend on AC is off (timeout 0) on all
three boxes. On battery, the laptops rog and tuf suspend after 900 s idle, and ssh traffic is
not user input. No process holds a sleep or idle block inhibitor, so an explicit sleep or power
verb also lands mid-run. Check: `systemd-inhibit --list --no-pager`, and `wake-lab.sh status
<box>` when a run's log stops. The fix belongs to lukstafi/ludics-lite#317.

**`tools/sweep.sh` still targets the WSL boots.** Its GPU destinations are `rog-nv-wsl` and
`minix-amd-wsl` (ahrefs/ocannl master da72fac4). On a native boot a sweep therefore records
those units as skipped (unreachable), not as results; ahrefs/ocannl#1030 reports and fixes
that. Its CUDA `PATH` prefix (`/usr/local/cuda/bin:/usr/lib/wsl/lib`) adds nothing on native:
`env.sh` already provides the first, and the second does not exist.
