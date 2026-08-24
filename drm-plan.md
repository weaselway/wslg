# A render node for d3d12 — what it would take

## Why

Chromium under `--ozone-platform=wayland` reports `Compositing: Software only`,
while the same build under `--ozone-platform=x11` reports
`Compositing: Hardware accelerated`. The X11 number is not a different GPU path:
Chromium renders into X drawables and **Xwayland** presents them as a Wayland
client, through the EGL path already fixed in `dmabuf-plan.md`. So the GPU works;
what is missing is the allocator Chromium's own Wayland path insists on.

That path allocates through **GBM**, not EGL. `gbm_create_device()` takes a file
descriptor, and Chromium gets that fd by looking for a DRM render node:

```
ERROR:ui/ozone/platform/wayland/common/drm_render_node_path_finder.cc:45]
  drmGetDevices2() has not found any devices: No such file or directory (2)
```

There is no `/dev/dri` on this system at all — only `/dev/dxg`. Same structural
gap as before, second place it surfaces. Fixing it fixes every GBM-based client
(Chromium, Firefox) at once.

## The surprise: probably no kernel work

The obvious reading is "we need a DRM driver". Two facts say otherwise.

**1. Chromium takes a path, not a device.** `drm_render_node_path_finder.cc:35`:

```c
if (base::CommandLine::ForCurrentProcess()->HasSwitch(switches::kRenderNodeOverride)) {
   drm_render_node_path_ = ...GetSwitchValuePath(switches::kRenderNodeOverride);
   return;                      /* returns before drmGetDevices2() is ever called */
}
```

`--render-node-override=/dev/dxg` skips enumeration, `drmGetVersion`, the vgem
filter and the preferred-driver list entirely. It is a **command-line switch, not
a patch** (`ui/ozone/public/ozone_switches.cc:38`).

**2. GBM only requires a character device.** `src/gbm/main/gbm.c:133`:

```c
if (fd < 0 || fstat(fd, &buf) < 0 || !S_ISCHR(buf.st_mode)) {
   errno = EINVAL;
   return NULL;
}
```

`/dev/dxg` is `crw-rw-rw- 10, 258`. It passes. Nothing below this point demands a
DRM node *by construction* — it demands it because the code then asks the fd
which driver to load, and that is our code to change.

So the target is: **make `gbm_create_device(/dev/dxg)` produce a d3d12 device**,
exactly parallel to what step 3b did for `dri2_initialize_wayland_drm`.

## What Chromium needs, in order

| # | Requirement | Where |
|---|---|---|
| 1 | a render node path | `drm_render_node_path_finder.cc:35` — supply via `--render-node-override` |
| 2 | `drmGetVersion()` on that path | `drm_render_node_handle.cc:36` — **LOG(FATAL) if it fails** |
| 3 | `gbm_create_device(fd)` succeeds | `wayland_buffer_manager_gpu.cc:476` — else `supports_dmabuf_ = false` |
| 4 | EGL display on that device | `wayland_buffer_manager_gpu.cc:483` — `EGL_PLATFORM_GBM_KHR` |
| 5 | `gbm_bo_create` for the format | `ozone_platform_wayland.cc:203` `IsNativePixmapConfigSupported` → `CanCreateBufferForFormat` |
| 6 | `gbm_bo_get_fd` → dmabuf | `gbm_pixmap_wayland.cc`, sent to the browser process over mojo |
| 7 | compositor imports it | already working — mutter accepts our smuggled handles |

Steps 6 and 7 are already proven: `tools/d3d12-share-test` showed a
`CreateSharedHandle` fd surviving `SCM_RIGHTS`, and mutter imports these today.

## What Mesa needs

Two of the three pieces already exist because of the dmabuf work.

**Already there.** `gbm_dri.c:902` decides how a bo is allocated:

```c
if (usage & GBM_BO_USE_WRITE || !dri->has_dmabuf_export)
   return create_dumb(gbm, width, height, format, usage);
```

`has_dmabuf_export` is set by step 1 (`caps->dmabuf` forced in
`d3d12_screen.cpp`), so allocation goes down the DRI image path — into d3d12 —
and never touches a dumb-buffer ioctl. `gbm_dri_bo_get_fd` (`gbm_dri.c:444`) is
just `dri2_query_image(__DRI_IMAGE_ATTRIB_FD)`, i.e. the `CreateSharedHandle`
route step 3 already documented. The GBM screen also already installs an **image
loader** (`gbm_dri.c:240` `gbm_dri_screen_extensions`), which is the precondition
the `dri_drawable.c` change in step 3b keys off.

**The one real gap.** `gbm_dri.c:283` `dri_screen_create()`:

```c
driver_name = loader_get_driver_for_fd(dri->base.v0.fd);   /* drmGetVersion */
if (!driver_name)
   return -1;                                              /* /dev/dxg dies here */
```

On `/dev/dxg` there is no `drmGetVersion`, so this returns NULL, and the fallback
at `:296` only retries with `zink`. This is the same shape as the
`fd_render_gpu == -1` bail in `platform_wayland.c`, and wants the same treatment.

### The changes

Measured with `tools/gbm-stride-test`, not inferred. Two of the three changes the
first draft of this plan called for turned out to be unnecessary.

**Change 1 (gbm_dri.c) — NOT NEEDED. `gbm_create_device("/dev/dxg")` already
works today.** `gbm_dri_device_create()` falls back to `dri_screen_create_sw()`
when `dri_screen_create()` fails, and that path calls
`dri_screen_create_for_driver(dri, NULL, ...)` — fd `-1`, pure swrast — which
reaches d3d12 through the `GALLIUM_DRIVER` dispatch in `sw_helper.h`. The
existing software fallback is doing exactly the job the proposed patch would
have. Confirmed: `backend: drm`, bos allocate, `gbm_bo_get_fd()` returns a valid
fd.

The one consequence to keep in view is that this path sets `dri->software = true`
(`gbm_dri.c:319`), which `platform_drm.c:668` reads to skip the render-fd
requirement — convenient here, but it means "software" is now load-bearing for a
hardware path, exactly the overload that made `swrast_dmabuf` necessary in step
3b.

**Change 2 (platform_drm.c) — NOT NEEDED, verified.** `EGL_PLATFORM_GBM_KHR` on
a `/dev/dxg` gbm device initializes as-is. The `if (!gbm_dri->software)` guard at
`:668` skips the render-fd bail on its own, and the rest of
`dri2_initialize_drm()` survives. Measured with `stride-test --egl-gbm`:

```
EGL 1.5 on gbm  vendor: Mesa Project
  dma_buf_import:           yes
  dma_buf_import_modifiers: yes
  window-capable configs:   yes
  renderer:                 D3D12 (Intel(R) HD Graphics 630)

ARGB8888     import=ok tex=ok fbo=complete readback=green OK
XRGB8888     import=ok tex=ok fbo=complete readback=green OK
ABGR8888     import=ok tex=ok fbo=complete readback=green OK
ABGR2101010  import=ok tex=ok fbo=complete readback=green OK
XBGR2101010  import=ok tex=ok fbo=complete readback=green OK
```

That is the full GPU-process round trip: allocate a bo, export the handle,
re-import it through `EGL_LINUX_DMA_BUF_EXT` using the metadata the exporter
claimed, attach it to an FBO, render, read back. The readback passing is what
proves the stride and offset actually *describe* the buffer rather than merely
being non-zero.

**Change 3 (d3d12) — REQUIRED, applied, verified.**
`d3d12_resource.cpp:326` mapped both flags to `D3D12_TEXTURE_LAYOUT_ROW_MAJOR`:

```c
if (templ->bind & (PIPE_BIND_SCANOUT | PIPE_BIND_LINEAR))
   desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
```

D3D12 permits `ROW_MAJOR` only for buffers and cross-adapter textures, so
`CreateCommittedResource` rejected every 2D texture that asked — and
`gfx::BufferUsage::SCANOUT` maps to `GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING`,
so this was Chromium's main path failing.

The flag is now ignored on non-Windows. There is no display engine to scan out
of; `PIPE_BIND_SCANOUT` exists to guarantee a layout KMS can read, and nothing in
this session ever will. The compositor imports through `OpenSharedHandle` and
recovers the true layout from `GetDesc()`, so tiling is invisible to it — the
same reasoning that makes the modifier meaningless.

`PIPE_BIND_LINEAR` deliberately still fails. It is a genuine request for a
CPU-readable layout that a shared handle cannot serve, and a clean allocation
failure beats a buffer that lies about its layout. Chromium only asks for
`LINEAR` on CPU-read usages, off the compositing path.

**Result after the change**, all five formats (ARGB8888, XRGB8888, ABGR8888,
ABGR2101010, XBGR2101010):

```
ARGB8888  0 (GPU_READ)       stride=1200 offset=0 planes=1 mod=INVALID fd=6
ARGB8888  RENDERING          stride=1200 offset=0 planes=1 mod=INVALID fd=6
ARGB8888  SCANOUT|RENDERING  stride=1200 offset=0 planes=1 mod=INVALID fd=6   <- was: create failed
ARGB8888  SCANOUT|LINEAR     create failed   (by design)
ARGB8888  LINEAR             create failed   (by design)
```

Every usage Chromium can produce for a compositing buffer now allocates and
exports. One cosmetic artifact to expect in logs, from the software fallback
described under change 1:

```
failed to get driver name for fd 3
MESA-LOADER: failed to retrieve device information
```

That is `loader_get_driver_for_fd()` failing on `/dev/dxg` before
`dri_screen_create_sw()` succeeds. Harmless, but it will appear in Chromium's
output and look like the cause of any later failure.

## Open questions — mostly answered now

1. **Stride/offset/modifier — ANSWERED, not a blocker.** Exports carry exact
   values: `stride == width * bpp` (1200 for 300px RGBA8, 7680 for 1920px),
   `offset == 0`, `planes == 1`, `modifier == DRM_FORMAT_MOD_INVALID`, and
   `gbm_bo_get_fd()` returns a valid fd. This was the most likely blocker and it
   is not one.

2. **Usage flags — ANSWERED.** `GBM_BO_USE_WRITE` is produced by neither
   `BufferUsageToGbmFlags()` nor `NativePixmapUsageToGbmFlags()`
   (`ui/gfx/linux/gbm_util.cc`), so `gbm_dri.c:902` never diverts Chromium into
   `create_dumb()`. Better still, `ui/gfx/linux/gbm_defines.h` masks `TEXTURING`,
   `CAMERA_WRITE`, `HW_VIDEO_*`, `PROTECTED`, `SW_READ_OFTEN` and
   `FRONT_RENDERING` to **0** under `#if !defined(MINIGBM)`, so against system
   libgbm only `SCANOUT`, `RENDERING` and `LINEAR` ever reach us. Of those,
   `RENDERING` and bare `0` work today; `SCANOUT` and `LINEAR` are change 3.

3. **Format coverage — ANSWERED for the RENDERING path.** ARGB8888, XRGB8888,
   ABGR8888, ABGR2101010 and XBGR2101010 all allocate and export. (XBGR2101010
   exists only because of the `MAP_FORMAT2(R10G10B10X2, ...)` fix from the
   Blender investigation — without it this list would have had a hole.)

4. **`DrmSyncobjIoctlWrapper` — still open.** `DRM_IOCTL_SYNCOBJ_*` on
   `/dev/dxg` will fail. Probably moot if mutter does not advertise
   `linux-drm-syncobj-v1`, which it should not, since `EGL_ANDROID_native_fence_sync`
   is missing for the same structural reason. Confirm rather than assume.

5. **Sandbox — CLOSED.** `/dev/dxg` is openable with the sandbox on.

### Step 0 — done

`tools/gbm-stride-test` implements it: an `--egl` half that exports a GL texture
through `EGL_MESA_image_dma_buf_export`, and a `--gbm` half that replays
Chromium's exact sequence against `/dev/dxg`. Run it with
`GALLIUM_DRIVER=d3d12 make run`.

One artifact to know about when reading its output: the `--egl` half reports
`fd=-1` while reporting correct strides. That is the test's own doing, not a
driver defect — a GL texture is not allocated with `__DRI_IMAGE_USE_SHARE`, so it
has no `D3D12_HEAP_FLAG_SHARED` and `CreateSharedHandle` has nothing to export.
GBM sets that flag explicitly (`gbm_dri.c:933`), which is why the `--gbm` half
returns real fds. The metadata numbers from both halves agree.

## The one gate that still needs a kernel node

With Mesa fixed, Chromium gets exactly one step further and then aborts:

```
FATAL:ui/ozone/platform/wayland/common/drm_render_node_handle.cc:36]
  Can't get version for device: '/dev/dxg'
```

`--render-node-override` bypasses *discovery*, but `DrmRenderNodeHandle::Initialize()`
independently calls `drmGetVersion()` on the node and treats failure as fatal.
`/dev/dxg` does not answer `DRM_IOCTL_VERSION`. There is no switch for this one.

**Validated around it with a shim.** `tools/dxg-drm-shim` is an `LD_PRELOAD` that
answers `drmGetVersion()` for `/dev/dxg` and forwards every other fd to the real
libdrm — Chromium links system `libdrm.so.2` dynamically, so no patch or rebuild
is involved. With it:

```
LD_PRELOAD=tools/dxg-drm-shim/libdxgdrmshim.so chromium-browser \
  --ozone-platform=wayland --gtk-version=3 --render-node-override=/dev/dxg
```

Chromium starts, the GPU process comes up, and the log shows **no gbm failures,
no native-pixmap failures, no GPU process loss** — only the cosmetic
`MESA-LOADER: failed to retrieve device information` / `kmsro: driver missing`
noise from the loader trying the named driver before falling back to swrast.

That shim run is worth more than a workaround: it puts Mesa through *exactly* the
sequence a real kernel node would produce. `loader_get_driver_for_fd()` now
returns a name, `dri_screen_create()` tries and fails to find a matching gallium
DRM driver, and `dri_screen_create_sw()` catches it and lands on d3d12 via
dxcore. So the Mesa side of the kernel-module scenario is already proven; only
the module itself is missing.

## Why nothing appeared on screen: rendering was never submitted

Getting Chromium to *allocate* through d3d12 is not the same as getting it to
*display*. The first working run rendered, but updates lagged or stuck: click a
link and nothing happens, then trigger the GNOME overview and the page is there,
fully drawn.

The obvious reading is a missing fence. A real dma-buf carries implicit fences in
its `dma_resv`, so a compositor sampling it waits on the producer automatically; a
D3D12 shared handle carries nothing, and mutter runs on a separate device and
queue. That reading was wrong, and it cost a patch before measurement corrected
it. Instrumenting the driver during 40s of continuous canvas animation:

| measurement | count |
|---|---|
| `d3d12_draw_vbo` calls | ~13,000 |
| `st_glFlush` calls | **1** |
| `d3d12_flush_cmdlist` (the only submission path) | **1** |
| wl_surface commits / damage / presented | 1423 / 1423 / 1422 |

The Wayland side was healthy the whole time — ~47fps, zero discards. The problem
was that **all ~13,000 draws sat in one command list that was never submitted**.
The compositor was not sampling a frame still being drawn; it was sampling a
frame whose commands had never reached the queue. That also explains the overview
trick: any action forcing a buffer reallocation or readback hits the one flush
path that exists, everything lands at once, and the page appears.

Two facts pinned it down: the GPU process has no ANGLE, dzn or SwiftShader
loaded — just `libEGL_mesa`, `libgallium` and WSL's `libd3d12` — and
`d3d12_end_batch()` has exactly two callers, `d3d12_flush_cmdlist()` and context
teardown.

### Why Chromium never flushed

Chromium does its frame-end synchronization through EGL fences, not
`eglSwapBuffers` (it is surfaceless). `GbmSurfacelessWayland` creates a fence per
frame and waits on it before submitting the buffer. Creating that fence is what
flushes: `dri_create_fence_fd(ctx, -1)` calls
`st_context_flush(st, ST_FLUSH_FENCE_FD, ...)`.

Fence creation needs `EGL_ANDROID_native_fence_sync`, which d3d12 did not expose
(`egl_dri2.c:690`, gated on `__DRI_FENCE_CAP_NATIVE_FD`). With no fence to
create, Chromium had nothing to wait on *and* nothing ever triggered a flush. The
missing extension was not a nicety; it was the submission trigger.

### The fix: expose native fence fds

No kernel work was needed, because the primitive already existed. On non-Windows,
d3d12 fences are already backed by an eventfd that `SetEventOnCompletion()`
signals, and d3d12 already waits on them with `sync_wait()`:

```c
inline HANDLE d3d12_fence_create_event(int *fd) { *fd = eventfd(0, 0); ... }
inline bool d3d12_fence_wait_event(HANDLE e, int fd, uint64_t ns)
{ return sync_wait(fd, ms) == 0; }
```

That is exactly the contract `EGL_ANDROID_native_fence_sync` needs: a descriptor
`poll()` reports ready when the GPU is done.

| File | Change |
|---|---|
| `d3d12_screen.cpp` | `caps->native_fence_fd = true` on non-Windows, which flips `__DRI_FENCE_CAP_NATIVE_FD` |
| `d3d12_fence.cpp` | `fence_get_fd()` — register the event via `d3d12_fence_ensure_event_registered()`, return `os_dupfd_cloexec(fence->event_fd)`; `d3d12_import_fence_fd()` for the import direction |
| `d3d12_fence.cpp` | foreign (imported) fences carry only an fd: `d3d12_fence_finish()` waits on it with `sync_wait()`, `wait_impl`/`signal_impl` avoid dereferencing a NULL `ID3D12Fence` |
| `d3d12_context_common.cpp` | `ctx->base.create_fence_fd` hook |
| `util/libsync.h` | relax `sync_valid_fd()` — see caveat |

The consumer only polls and never reads, so the eventfd stays readable for every
waiter once signalled.

**Result**, same 40s animation:

| | before | after |
|---|---|---|
| draws | ~13,000 | ~14,400 |
| `st_glFlush` | 1 | **~2,400** |
| `d3d12_flush_cmdlist` | 1 | **~4,400** |
| GPU process crashes | — | 0 |

Confirmed working interactively.

### Caveat: these fds are not sync_files

Mesa's `sync_valid_fd()` demands a real sync_file:

```c
return ioctl(fd, SYNC_IOC_FILE_INFO, &info) >= 0;   /* an eventfd fails this */
```

An eventfd is poll-able but is not one, so this assert killed the GPU process
until `sync_valid_fd()` was relaxed to accept any live fd. That is honest for the
present use — everything here only polls — but the limits are real: the fd cannot
be imported by another driver, cannot be merged, and could not be handed to a
compositor as an acquire fence if mutter ever advertised
`linux-drm-syncobj-v1`.

This kernel has `CONFIG_SYNC_FILE=y` but **`CONFIG_SW_SYNC is not set`**, so
userspace has no way to mint a real sync_file. Two ways to close it properly:

1. **Enable `CONFIG_SW_SYNC`** in a custom WSL kernel — an existing debugfs
   facility for exactly this: create a timeline, hand out sync_files, signal by
   incrementing. No new code, but it is a testing feature and debugfs-gated.
2. **A small module** exposing an ioctl that returns a sync_file whose
   `dma_fence` userspace signals — sw_sync scoped to this use. Mesa would then
   run a helper that waits on the D3D12 eventfd and signals it.

Either restores `sync_valid_fd()` untouched and is a prerequisite for explicit
sync on the mutter side.

**Resolved by option 2, and the last sentence turned out to be wrong.**
`sync_valid_fd()` was *not* restored, deliberately — see "What step 2+3 changed"
below. The rest of this section stands as the reason the module grew an ioctl.

### The fence reaches Chromium, but not the compositor

Running Chromium against the finished driver produces two errors on a loop, and
they are worth separating because only one of them matters:

```
ui/gfx/gpu_fence.cc:72] sync_(file|fence)_info returned null for fd : 234
ui/ozone/.../wayland_buffer_manager_host.cc:473]
    Failed DMA_BUF_IOCTL_IMPORT_SYNC_FILE: Inappropriate ioctl for device (25)
```

The first is the `sync_valid_fd()` caveat above seen from the other side.
`GetStatusChangeTime()` cannot read an eventfd, so Chromium cannot tell that a
fence is already signalled and skip passing it (`wayland_surface.cc:229`). It
costs an optimisation, nothing more.

The second is the real gap. mutter advertises no explicit-sync protocol here, so
Chromium takes `UseImplicitSyncInterop()`: it pushes the acquire fence *into the
dma-buf* with `DMA_BUF_IOCTL_IMPORT_SYNC_FILE`, so the compositor's implicit sync
picks it up (`wayland_buffer_manager_host.cc:459`). Our buffer fd is a D3D12
shared handle, not a dma-buf, so the ioctl does not exist on it — `ENOTTY`. Note
that a *real* sync_file would not help: the ioctl fails on the buffer, not on the
fence.

And Chromium does not fall back. The `kDMAFence` case in
`WaylandSurface::ApplyPendingState()` logs the failure and commits anyway; only
the `kSyncobj` case has an early-out (`wayland_surface.cc:512-527`). There is no
CPU wait anywhere on that path.

So the fence is created, and stops at the process boundary. Every acquire fence
Chromium produces is dropped on the floor.

### Loose ends

- The "block when a submission wrote an exported resource" stall in
  `d3d12_flush_cmdlist()` **is not redundant** — an earlier draft of this
  document guessed that it was, on the assumption that Chromium waits on its own
  fence before committing. It does not (see above). With the acquire fence unable
  to cross to mutter, that stall is the only thing keeping a half-drawn frame off
  the screen. **Now resolved:** `linux-drm-syncobj-v1` works end to end, and the
  stall is conditional rather than gone — the reasoning is in "What step 2+3
  changed".
- Instrumentation removed: `d3d12_draw.cpp`, `sw_helper.h` and `st_cb_flush.c`
  are back to pristine; the `D3D12_SYNC_DEBUG` and `D3D12_ALWAYS_FINISH` knobs
  are gone from `d3d12_context_common.cpp` and `d3d12_resource.cpp`. What remains
  in `vendor/mesa` is functional change only.
- The `--egl` half of `tools/gbm-stride-test` still reports `fd=-1` from
  `EGL_MESA_image_dma_buf_export` on the *surfaceless* platform, where the GBM
  path returns a real fd. Chromium does not take that route, so it has not been
  chased.

## The kernel module, now required for a real deployment

The `drmGetVersion()` gate makes a node unavoidable outside of test runs. The
good news is that it needs to do almost nothing.

One practical note, since an earlier draft got this wrong: this kernel has
`CONFIG_DRM=y` and ships DRM modules, but there are **no build headers**
installed — `/lib/modules/6.18.33.2-microsoft-standard-WSL2/build` does not
exist, and this is Microsoft's stock kernel, not a local build. So an
out-of-tree module still means fetching and configuring the WSL2 kernel source
once. After that, module rebuilds are cheap.

Requirements, all of them now evidence-backed rather than guessed:

- `DRIVER_RENDER | DRIVER_GEM`, so DRM core creates `/dev/dri/renderD128`.
- Answer `DRM_IOCTL_VERSION` — the whole point.
- Do **not** name it `vgem`; `drm_render_node_path_finder.cc:75` skips that name
  explicitly. Any other name works, and Mesa never dlopens it successfully
  anyway.
- Do **not** implement dumb buffers. If `kms_swrast` can allocate through the
  node, `dri_screen_create_sw()` stops there and the session gets *software*
  rendering. It must fail so the pure-swrast path — the one that reaches d3d12 —
  is taken. The shim run confirms this ordering works.
- Allocate nothing else. Every buffer still comes from d3d12 via
  `CreateSharedHandle`; the node exists to be identified, not to allocate.

With it, `--render-node-override` and the preload both go away, `drmGetDevices2()`
enumerates normally, and every GBM client — Chromium, Firefox — is fixed at once
without per-app flags.

### Why the module rather than `CONFIG_SW_SYNC`

Both options cost the same kernel source tree, so the question is only what each
one buys. `CONFIG_SW_SYNC` is a single config flag and no new code, which is
genuinely attractive — but it solves the smaller half of one problem.

It mints real sync_files, so `sync_valid_fd()` goes back to pristine and
`sync_file_info()` stops returning null. It does **not** fix
`DMA_BUF_IOCTL_IMPORT_SYNC_FILE`, because that ioctl fails on the buffer — not a
real dma-buf — regardless of how good the fence is. The visible symptom stays.
It also does nothing for the `drmGetVersion()` gate, so the preload shim and
`--render-node-override` both stay. And sw_sync is debugfs-gated
(`/sys/kernel/debug/sync/sw_sync`, root-only, `CONFIG_DEBUG_FS=y` here), which
Mesa would have to open before Chromium's GPU sandbox closes — workable, since
`/dev/dxg` is opened the same way, but it is a facility the kernel explicitly
documents as a testing aid.

The module's advantage is that the expensive parts are free. `mutter` gates
`wp_linux_drm_syncobj_v1` on four things (`meta-wayland-linux-drm-syncobj.c:449`):

| # | Gate | Status |
|---|------|--------|
| 1 | `COGL_WINSYS_FEATURE_SYNC_FD` — `EGL_ANDROID_native_fence_sync` | **done**, verified on the surfaceless display |
| 2 | `EGL_EXT_device_drm_render_node` → a device path | needs the node + Mesa reporting it |
| 3 | `drmGetCap(DRM_CAP_SYNCOBJ_TIMELINE)` | free — `DRIVER_SYNCOBJ_TIMELINE` flag |
| 4 | `drmSyncobjEventfd()` present (must fail `ENOENT`, not `EINVAL`) | free — drm core ioctl |

Gates 3 and 4 are pure `driver_features` bits: `DRM_IOCTL_SYNCOBJ_*` live in
`drm_syncobj.c` in drm core with `DRM_RENDER_ALLOW`, so any driver that sets the
flags gets timeline syncobjs, sync_file import/export and eventfd signalling
without writing them. `CONFIG_SW_SYNC` supplies none of gates 2 through 4.

That matters because `linux-drm-syncobj-v1` is the route that actually fixes the
compositor gap: it carries the fence out of band, over the Wayland protocol,
instead of through an ioctl on a buffer that is not really a dma-buf. Chromium
already has that path (`SyncMethod::kSyncobj`, `DrmSyncobjIoctlWrapper`) and
mutter already implements it. It is the only thing that would let the
`d3d12_flush_cmdlist()` stall be removed and real pipelining come back.

So: **the module**, in three steps of increasing payoff.

1. **Render node only.** `DRIVER_RENDER | DRIVER_GEM`, answer `DRM_IOCTL_VERSION`,
   allocate nothing. Drops the preload shim and `--render-node-override`. Small,
   low-risk, immediately useful. **Done — see below.**
2. **Add `DRIVER_SYNCOBJ | DRIVER_SYNCOBJ_TIMELINE` and a way to mint
   `dma_fence`s** from the D3D12 eventfd. **Done — see below.**
3. **Wire `linux-drm-syncobj-v1` end to end** — Mesa exposing
   `EGL_EXT_device_drm_render_node`, then mutter's four gates pass and Chromium
   switches from `kDMAFence` to `kSyncobj` on its own. Then drop the stall.
   **Done, with one correction: the stall became conditional rather than
   removed.**

Step 1 is worth doing on its own merits even if 2 and 3 never happen.

### Step 1 as built

`kernel/dxgdrm` is ~130 lines and does nothing but exist. Measured with
`tools/drm-node-probe`, which replays Chromium's discovery sequence:

| Gate | Before | After |
|---|---|---|
| `drmGetDevices2()` | `no devices` | 1 device, `bustype=2` (platform) |
| `drmGetVersion()` | fatal, needed the preload shim | `name="dxgdrm" 1.0.0` |
| `gbm_create_device()` | needed `--render-node-override=/dev/dxg` | ok, backend `drm` |
| EGL/GBM round trip on the node | n/a | 5/5, `renderer: D3D12 (NVIDIA GeForce 940MX)` |

So `chrome.sh` loses both the `LD_PRELOAD` and the `--render-node-override`, and
`tools/dxg-drm-shim` is now dead weight.

Three things this turned up that the plan had guessed at:

- **Enumeration works.** The concern was that libdrm's `drmParsePlatformDeviceInfo`
  reads `OF_FULLNAME` out of uevent, which a platform device with no devicetree
  node has no reason to carry. It enumerates anyway.
- **The name must not be `d3d12`.** `gbm_dri.c` no longer dlopens `*_dri.so` --
  `dri_screen_create_for_driver()` calls `driCreateNewScreen3()` and picks a
  screen type from the name -- but `libdril_dri.so` is installed *as*
  `d3d12_dri.so` and exports `__driDriverGetExtensions_d3d12`, so an X11 DRI
  loader would find a stub screen through it. `dxgdrm` matches no gallium driver
  and no installed `*_dri.so`.
- **The zink fallback is now reachable and does not fire.** Answering
  `drmGetVersion()` means `dri_screen_create()` no longer bails early, so the
  `strdup("zink")` retry at `gbm_dri.c:294` runs for the first time. Zink matches
  a VkPhysicalDevice to the fd via `VK_EXT_physical_device_drm` and finds none, so
  it falls through to swrast and reaches d3d12. Worth re-checking if lavapipe or
  dzn ever start advertising DRM device ids -- the failure mode is silent
  software rendering, not an error.

Smaller things worth not rediscovering:

- `.fop_flags = FOP_UNSIGNED_OFFSET` is mandatory. `drm_open_helper()` returns
  `-EINVAL` without it (`drm_file.c:329`). `DRM_GEM_FOPS` sets it; a hand-rolled
  fops must say so.
- DRM core registers a primary node too, so `card0` appears alongside
  `renderD128` even for a `DRIVER_RENDER`-only driver. It has no modeset
  capability. Harmless for a headless mutter, which never probes DRM.
- The node comes up `root`-only until udev applies
  `50-udev-default.rules`; `udevadm trigger --subsystem-match=drm` sets the
  usual `0666 root:render`.

### Building it: no headers on WSL

There is no `/lib/modules/$(uname -r)/build`, and this is Microsoft's stock
kernel. The tree has to come from `microsoft/WSL2-Linux-Kernel` at the tag
matching `uname -r` (`linux-msft-wsl-6.18.33.2` here, which exists), configured
from `/proc/config.gz`.

- `make vmlinux` is not enough. It produces `vmlinux.symvers` but not
  `scripts/module.lds`, and the missing linker script shows up as
  `No rule to make target 'dxgdrm.ko'` rather than a missing-file error.
  `make modules_prepare` is the missing step; `cp vmlinux.symvers Module.symvers`
  covers the CRCs, since `CONFIG_DRM=y` means every symbol needed is built in.
- `LOCALVERSION=` must be passed, or `setlocalversion` appends `+` to vermagic
  for a shallow clone that is not on an annotated tag, and the module is rejected.
- **Do not trim the config to speed the build up.** Disabling
  `CONFIG_DEBUG_INFO_BTF_MODULES` removes four fields from `struct module` and
  the kernel refuses the module on size. The config has to stay as
  `/proc/config.gz` has it.
- **Unresolved: MODVERSIONS CRCs do not match.** The kernel was built with gcc
  13.2; Fedora 44 offers only gcc 15 and 16, so `module_layout`'s CRC differs and
  the module currently needs `modprobe --force-modversion`, which taints. The
  struct layouts do match (`CONFIG_RANDSTRUCT_NONE`, and the config diff is
  nothing but compiler-capability autodetects), so this is safe here, but it is
  not a deployment story. Two ways out: build with the kernel's own toolchain, or
  boot the kernel we just built from this tree via `kernel=` in `.wslconfig` --
  which would also be the moment to turn on anything else the plan wants.

## What step 2+3 changed

Steps 2 and 3 landed together, because they turned out not to be separable.

### They are one change, not two

The plan had step 2 (real sync_files) as a tidy-up worth doing on its own. It is
not: on its own it buys a reverted `libsync.h` hack and one less log line. And
step 3 cannot ship without it, for a reason worth stating plainly, because it is
the difference between "degraded" and "broken".

Chromium's explicit-sync path imports the acquire fence into a timeline syncobj
(`ImportSyncFdAtCurrentSyncPoint`, `wayland_surface.cc:444`). An eventfd is not a
sync_file, so that import fails — and the failure does not degrade. Once a sync
point exists, `SetExplicitSync()` returns `std::nullopt` and
`ApplyPendingState()` **discards the frame** (`wayland_surface.cc:512`). Turning
on the protocol without real sync_files would have been worse than leaving it
off.

### The fence: an eventfd is not a dma_fence, and cannot be made into one

D3D12 reports completion by signalling an eventfd, and there is no `dma_fence`
anywhere in the WSL GPU stack to borrow. The module bridges it:

```
DXGDRM_FENCE_FROM_EVENTFD:  eventfd in  ->  sync_file out
```

The mechanism is the one KVM's irqfd uses — `vfs_poll()` queues a wait entry on
the eventfd and the wakeup signals the fence. Two things are load-bearing:

- **It never reads the eventfd.** A read consumes the count that Mesa's own
  waiter (`d3d12_fence_wait_event`) is looking for.
- **It signals on `EPOLLHUP` too.** An eventfd closed without ever being
  signalled would otherwise leave a fence that never settles, and a fence that
  never signals hangs whoever waits on it.

`sync_wait()` is `poll(POLLIN)`, so the *import* direction needed no change at
all: `d3d12_create_fence_fd` polls a sync_file exactly as it polled an eventfd.

### `sync_valid_fd()` stays relaxed — the plan was wrong about this

Every earlier draft had step 2 restoring `sync_valid_fd()` to upstream. It should
not be, and the reason is the fallback. `fence_get_fd()` falls back to duping the
eventfd when the dxgdrm node is absent, and that fallback is what keeps a machine
without the module working at all — without a fence fd there is no submission
trigger, and rendering piles up unsubmitted (the original bug). Restoring the
assert would make the fallback path kill the GPU process. The tolerant version is
the correct one, not a leftover hack.

### mutter's gate 2 was the whole Mesa story

Gates 3 and 4 came free with two feature bits. Gate 1 was already done. Gate 2 —
`EGL_EXT_device_drm_render_node` returning a path — was the only real work, and
it is not d3d12 code at all: `/dev/dxg` is not a DRM device, so the d3d12 screen
comes up as EGL's *software* device, and `_eglQueryDeviceStringEXT()` returns
NULL for a software device by construction (`egldevice.c:358`).

So `egldevice.c` now reports the dxgdrm node for the software device, matched by
driver name rather than "the only DRM device around" so it cannot fire on a real
GPU. The lookup is lazy rather than folded into `_eglDeviceRefreshList()`,
because that only runs from `eglQueryDevicesEXT()`, which a client asking its own
display for a device path never calls.

This gate is shared with dmabuf feedback, so fixing it moved
`zwp_linux_dmabuf_v1` from **v3 to v5** as a side effect.

### The stall is conditional, not removed

The plan said step 3 would let the `d3d12_flush_cmdlist()` stall go. Removing it
outright would have been a bug. It protects *every* client holding an exported
buffer, and a client that does not speak `linux-drm-syncobj-v1` — GTK apps,
glmark2, anything relying on implicit sync — still has no fence on our fake
dma-buf. Deleting it would have traded Chromium's latency for their correctness.

It is now keyed on `screen->exports_fence_fds`, set the first time a screen hands
out a fence fd. Screens are per-process, so that flag means exactly "this client
synchronizes explicitly": Chromium skips the stall, everyone else keeps it.

### Measured

`tools/drm-node-probe` covers the module; the browser was traced under a canvas
animation.

| | Before | After |
|---|---|---|
| `DRM_CAP_SYNCOBJ_TIMELINE` | no | yes |
| `drmSyncobjEventfd` | `EOPNOTSUPP` (ioctl absent) | `ENOENT` (gate passes) |
| fence fd | eventfd, fails `SYNC_IOC_FILE_INFO` | sync_file, passes |
| `drmSyncobjImportSyncFile` | n/a | ok — Chromium's acquire path |
| `zwp_linux_dmabuf_v1` | v3 | **v5** |
| `wp_linux_drm_syncobj_manager_v1` | absent | advertised |

GPU process, 6 s of `strace -e trace=ioctl` under load:

```
DXGDRM_FENCE_FROM_EVENTFD   350      (~58/s, one per frame)
SYNC_IOC_FILE_INFO         1050      all = 0
failing ioctls                0
```

`strace` labels our ioctl `DRM_IOCTL_ARMADA_GEM_CREATE or DRM_IOCTL_QXL_ALLOC` —
it is `DRM_IOWR(DRM_COMMAND_BASE + 0x00)` with an 8-byte payload and strace has no
dxgdrm table. Same number, different driver.

The `DMA_BUF_IOCTL_IMPORT_SYNC_FILE` and `sync_(file|fence)_info returned null`
errors that fired every frame are gone — not silenced but unreachable, since that
path only runs when explicit sync is unavailable. Confirmed interactively:
Chrome "feels perfectly fine".

### Still owed

- The syncobj *import* is verified through `drm-node-probe`, which runs exactly
  the call Chromium makes, rather than by tracing the live browser. Those ioctls
  happen in the browser process, and repeated attempts to trace it kept matching
  the tracing shell's own command line instead. Same code path, but that hop is
  inference.
- The latency win from making the stall conditional is unmeasured — the
  instrumentation that would have shown it was removed earlier.
- `tools/dxg-drm-shim` is dead weight and still present, by choice.

## Xwayland is not the escape hatch

An earlier draft of this plan suggested running Chromium under Xwayland and
being done with it, on the grounds that chrome://gpu reports full hardware
acceleration there. That was wrong in the way that matters: **Xwayland commits
its surfaces with `wl_shm`, not dma-buf.** The rendering is accelerated, and then
the result is copied to the compositor exactly as `dmabuf-plan.md` describes — so
it reintroduces the per-frame upload this whole line of work exists to remove.
It buys a working browser, not a fast one.
