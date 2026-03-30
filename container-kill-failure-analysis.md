# Container Kill Failure Analysis

## Summary

Container `a22675920bba` ("pause") in pod `e2e-dra-4030/dra-test-driver-55tcq` on node `ip-10-0-11-5` survived SIGKILL after 4 attempts. PID 45109 (`sh`, PID 1 in its PID namespace) was stuck in `zap_pid_ns_processes` with a pending SIGKILL (`ShdPnd: 0000000000000100`) that could not be delivered. A second container (`28e3383622ce` in `e2e-image-volume-256/image-volume-test`, PID 467947) exhibited the same symptoms.

## Root Cause: Loop Device I/O Errors

The dmesg on `ip-10-0-11-5` shows loop device I/O errors:

```
[ 3240.005478] I/O error, dev loop2, sector 0 op 0x0:(READ) flags 0x80700 phys_seg 1 prio class 0
[ 3240.008012] I/O error, dev loop2, sector 0 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 0
[ 3240.013258] Buffer I/O error on dev loop2, logical block 0, async page read
[ 3843.516540] I/O error, dev loop1, sector 1024 op 0x0:(READ) flags 0x80700 phys_seg 1 prio class 0
```

The `loop2` errors at dmesg timestamp `[3240]` correspond to ~18:04 UTC (boot at ~17:10:15 + 3240s), shortly after CRI-O's `StopContainer` timed out at 18:02:30.

## Timeline

### Container 1: e2e-dra-4030/dra-test-driver-55tcq/pause

| Time | Event |
|------|-------|
| 17:44:31 | Pod added, sandbox and container created |
| 17:44:32 | Container started, PID 45109 (`sh`), PID 1 in namespace |
| 17:44:33 | DRA plugin `e2e-dra-4030.k8s.io` registered |
| 17:45:59 | DRA plugin unregistered (test completed) |
| 18:00:00 | `StopContainer` issued (30s grace period) |
| 18:00:30 | SIGTERM timeout, SIGKILL sent. Systemd deactivates cgroup scope |
| 18:00:30 | PID 45109 survives kill -- stuck in `zap_pid_ns_processes`, cgroup `(deleted)` |
| 18:02:30 | `StopContainer` returns `DeadlineExceeded` |
| 18:02:39+ | CRI-O reports process blocked (159s, escalating to 8000+s) |

### Container 2: e2e-image-volume-256/image-volume-test/test-container

| Time | Event |
|------|-------|
| 20:04:14 | Pod added with `kubernetes.io/image` volume |
| 20:04:16 | Container started |
| 20:19:46 | `StopContainer` issued |
| 20:22:16 | First timeout (`RST_STREAM` / `CANCEL`) |
| 20:24:16+ | Repeated `DeadlineExceeded` on kill retries |

## How the D-state Occurs

Both containers used loop devices:

1. **DRA test driver ("pause")**: The `hostpathplugin` CSI driver creates loop-backed raw block volumes via `fallocate` + `losetup` (`hostpath.go:198-215`).
2. **Image volume test**: The `kubernetes.io/image` volume plugin mounts container image layers using loop devices.

When the backing file for a loop device is removed or its storage becomes unavailable while the loop device is still in use:

1. Any process doing I/O on the loop-backed filesystem enters **D-state** (`TASK_UNINTERRUPTIBLE`) waiting for I/O completion that will never arrive.
2. D-state processes cannot be killed -- SIGKILL is queued but never delivered.
3. When the container's PID 1 (`sh`) receives SIGKILL, the kernel enters `zap_pid_ns_processes()` which sends SIGKILL to all processes in the PID namespace and waits for them to exit.
4. The D-state process cannot exit, so `zap_pid_ns_processes()` blocks forever.
5. CRI-O's `StopContainer` hangs until its deadline expires, then retries endlessly.

## Relevant hostpathplugin Code Paths

The hostpathplugin code (`~/kubernetes-csi/csi-driver-host-path`) has several operations that can cause D-state, none with timeouts or context cancellation:

- **`mounter.Mount()`** (`nodeserver.go:144,189`): `mount()` syscall, blocks if device/path unavailable.
- **`mount.New("").Unmount()`** (`nodeserver.go:243`): `umount()` syscall, blocks if filesystem busy.
- **`mount.IsNotMountPoint()`** (`nodeserver.go:130,152,237`): `stat()` on mount point, blocks on hung mount.
- **`exec.Command("findmnt", "--json").CombinedOutput()`** (`healthcheck.go:86`): Traverses all mount points with no timeout. If any mount is hung, `findmnt` blocks in D-state.
- **`os.RemoveAll()`** (`nodeserver.go:250`): `unlink()`/`rmdir()` can block on hung filesystem.
- **`AttachFileDevice()` / `DetachFileDevice()`** (`hostpath.go:215,257`): Loop device setup/teardown via `losetup`.

## Evidence from /proc/45109/status

```
Name:       sh
State:      S (sleeping)          # Sleeping in zap_pid_ns_processes, waiting for D-state child
NSpid:      45109  1              # PID 1 in container PID namespace
ShdPnd:     0000000000000100      # SIGKILL (signal 9) pending, cannot be delivered
SigBlk:     0000000000000000      # No signals blocked
FDSize:     0                     # All FDs closed (already in teardown)
Threads:    1
```

The cgroup was marked `(deleted)` -- systemd removed it, but the process persists because `zap_pid_ns_processes` cannot complete.

## Why runc Hangs but crun Does Not

The D-state itself is a kernel-level problem -- both runtimes trigger it equally. The difference is in how each runtime **waits for the container to be "dead"** after sending SIGKILL.

### runc (blocks)

runc's stop path is PID-centric:

1. Sends SIGKILL to PID 1 in the container.
2. PID 1 receives SIGKILL -- the kernel enters `zap_pid_ns_processes()`, which sends SIGKILL to all processes in the PID namespace and **waits for all of them to exit**.
3. A D-state child can never exit, so `zap_pid_ns_processes()` blocks forever and PID 1 never exits.
4. runc's `waitpid()` on PID 1 blocks forever.
5. `runc delete` cannot proceed because the init process is still "alive".
6. CRI-O's `StopContainer` hangs until its deadline, then retries in a loop.

The fundamental problem: runc ties container death to PID 1 exit, and the kernel ties PID 1 exit (in a PID namespace) to **all** processes in that namespace exiting.

### crun (does not block)

crun takes a cgroup-centric approach on cgroups v2:

1. Sends SIGKILL via **`cgroup.kill`** (writes `1` to the cgroup's `cgroup.kill` file), which delivers SIGKILL to every process in the cgroup individually -- it does not go through `zap_pid_ns_processes()`.
2. Uses **`cgroup.freeze`** to freeze the cgroup before killing, preventing new I/O or forks.
3. On `delete --force`, crun **destroys the cgroup** and proceeds with cleanup without blocking on `waitpid()` for PID 1. It checks container state via `cgroup.events` (`populated 0`) rather than relying on PID 1's exit.
4. The D-state processes still exist as zombies/orphans in the kernel, but crun has already released the container and reported success to CRI-O.

crun sidesteps the deadlock by:

- Not funneling all kills through PID 1 (avoids triggering `zap_pid_ns_processes`).
- Not blocking on PID 1 exit as the definition of "container stopped".
- Using cgroup lifecycle (destroy + check `populated`) instead of process lifecycle.

### Caveat

crun does not *fix* the D-state -- those processes are still stuck in the kernel until the loop device I/O resolves or the node reboots. But crun does not **block on them**, so CRI-O gets a timely response and the container teardown completes. The leaked kernel processes are invisible to the container runtime at that point.

This only applies on **cgroups v2**. The `cgroup.kill` and `cgroup.freeze` interfaces do not exist in v1. On a cgroups v1 system, crun falls back to a PID-based approach similar to runc.

## runc 1.2+ `cgroup.kill` Does Not Help Here

runc added `cgroup.kill` support in v1.2.0 ([PR #3825](https://github.com/opencontainers/runc/pull/3825), [Issue #3135](https://github.com/opencontainers/runc/issues/3135)). However, it only uses `cgroup.kill` for containers with a **shared PID namespace**. For standard containers with their own private PID namespace (the normal Kubernetes case), runc still sends SIGKILL directly to PID 1:

```go
// container_linux.go — identical in runc 1.2.0 through 1.4.0
func (c *Container) Signal(s os.Signal) error {
    if s == unix.SIGKILL && !c.config.Namespaces.IsPrivate(configs.NEWPID) {
        // Shared PID namespace: uses signalAllProcesses -> cgroup.kill
        return signalAllProcesses(c.cgroupManager, unix.SIGKILL)
    }
    return c.signal(s)  // Private PID namespace: kills PID 1 directly
}
```

This code path is **unchanged from runc 1.2.0 through 1.4.0**. The D-state hang affects all runc versions equally for standard Kubernetes pods.

## Why This Only Happens in OpenShift CI, Not Upstream

### Different test infrastructure

| | Upstream Kubernetes CI | OpenShift CI |
|---|---|---|
| CRI runtime | containerd | CRI-O 1.35.1 |
| Test infra | KinD (single node in Docker) | Multi-node AWS cluster (3 masters + 3 workers, m6a.xlarge) |
| Kernel | Host kernel (typically 6.x) | RHEL 9 kernel 5.14.0-687 |
| Test density | Sequential or lightly parallel | **229 test namespaces, 1382 pods on one node, 74 CSI/volume tests concurrently** |
| Loop devices | Varies | loop0-loop5 (6 total, loop0 reserved for RHCOS boot) |

### Root cause: loop device reuse under extreme contention

74 concurrent CSI/volume test namespaces compete for 5 usable loop devices (loop1-loop5). The hostpath CSI driver creates and destroys loop-backed block volumes in rapid cycles -- dmesg shows loop1 recycled through 6+ different ext4 filesystems in under 2 minutes.

The dmesg captures the race:

```
[ 3231.573386] loop2: detected capacity change from 0 to 2048   # Test A attaches backing file
[ 3240.002605] loop2: detected capacity change from 0 to 2048   # Test B reuses loop2 with new file
[ 3240.005478] I/O error, dev loop2, sector 0 op 0x0:(READ)     # Immediate I/O failure
```

When one test's `DetachFileDevice` + `os.RemoveAll` races with another test's `AttachFileDevice` on the same `/dev/loopN`, the backing file can be removed before the new loop setup completes its first read.

### Why upstream does not trigger this

1. **Lower test density**: upstream CI jobs (typically KinD-based) run focused test suites, not the full OpenShift conformance + CSI + DRA + ephemeral volume matrix simultaneously on one node.
2. **CSI block volume tests were limited in KinD**: upstream had persistent loop device issues in KinD ([kind#1248](https://github.com/kubernetes-sigs/kind/issues/1248), [kubernetes#101913](https://github.com/kubernetes/kubernetes/issues/101913)). The `/dev` sharing fix ([kubernetes#84501](https://github.com/kubernetes/kubernetes/pull/84501)) addressed device visibility, but these tests are not run with the same parallelism as OpenShift CI.
3. **Newer kernels**: upstream typically runs kernel 6.x, which has improved loop device handling and may not exhibit the same I/O error on rapid reuse as RHEL 9's backported 5.14.

The issue is not a CRI-O vs containerd difference at the runtime level -- it is a **test density problem** unique to OpenShift CI's environment.

## Resolution

This is a kernel-level issue. Once a process enters D-state due to a failing loop device, only a node reboot clears it. To prevent recurrence:

- Detach loop devices (`losetup -d`) before removing their backing files.
- Use `exec.CommandContext()` with deadlines for subprocess invocations (`findmnt`, `fallocate`, etc.).
- Add timeouts to mount/unmount operations via context-aware wrappers.
