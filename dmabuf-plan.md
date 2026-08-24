# Zero-copy client buffers under WSL/d3d12 — findings and plan

## Problem

Every Wayland client in the session delivers its pixels via `wl_shm`. Each commit
therefore costs a CPU copy from the client's shared memory into a GL texture, and
where the damage covers the whole surface it also costs a texture reallocation.

Observed with `MUTTER_DEBUG=wayland` on a single 300x300 `eglgears` window:

```
damage: shm buffer 300x300, 1 rect(s), 90000/90000 px (100%), full-surface rect  -- XdgToplevel
damage: shm buffer 300x37,  1 rect(s), 11100/11100 px (100%), full-surface rect  -- Subsurface (titlebar)
damage: shm buffer 348x385, 1 rect(s), 133980/133980 px (100%), full-surface rect -- Subsurface (shadow)
```

235,080 px ≈ 940 KB copied per frame, ~56 MB/s at 60fps, for one small window. 62%
of it is CSD chrome that never changes. The client is *not* rendering in software —
it alternates between two 10-bit `ABGR_2101010_PRE` buffers, which is a GL swapchain
being **read back** into shm because there is nothing else to hand over.

## Why there is nothing else to hand over

mutter logs the reason at startup:

```
WAYLAND: Not binding Wayland display, missing extension
WAYLAND: Wayland DMA buffer protocol support not enabled:
         Missing 'EGL_EXT_image_dma_buf_import_modifiers'
```

Both zero-copy routes are unavailable — the second line is the legacy
`wl_drm`/EGLImage path (`EGL_WL_bind_wayland_display`). So `wl_shm` is not a
fallback the clients chose; it is the only option.

The gate is four steps deep, and none of them is a d3d12 feature flag:

| # | Location | Condition |
|---|---|---|
| 1 | `mesa/src/gallium/auxiliary/util/u_screen.c:135` | `caps->dmabuf` is set **only** from `drmGetCap(fd, DRM_CAP_PRIME)` on the screen's DRM fd |
| 2 | `mesa/src/egl/drivers/dri2/egl_dri2.c:613` | `has_dmabuf_import = caps.dmabuf & DRM_PRIME_CAP_IMPORT` |
| 3 | `mesa/src/egl/drivers/dri2/egl_dri2.c:703` | advertises `EXT_image_dma_buf_import{,_modifiers}` only if the above |
| 4 | `mutter/src/wayland/meta-wayland-dma-buf.c:1913` | refuses to create the `zwp_linux_dmabuf_v1` global without that extension |

Step 1 is the root. The d3d12 driver reaches the host GPU through `/dev/dxg`
(dxcore), not a DRM render node, so there is no fd to issue `drmGetCap` against,
`caps->dmabuf` stays 0, and everything downstream unwinds. `EGL_ANDROID_native_fence_sync`
is missing for the same structural reason (`egl_dri2.c:690`, gated on
`__DRI_FENCE_CAP_NATIVE_FD`).

This is **not** a build option we are missing.

## The opening

The d3d12 driver already implements the full export/import round trip, using
something that is an fd on Linux:

`mesa/src/gallium/drivers/d3d12/d3d12_resource.cpp:833` — export:

```c
case WINSYS_HANDLE_TYPE_FD: {
   screen->dev->CreateSharedHandle(d3d12_resource_resource(res), nullptr,
                                   GENERIC_ALL, nullptr, &d3d_handle);
#else   /* non-Windows */
   handle->handle = (int)(intptr_t)d3d_handle;   /* truncated to int == fd */
```

`d3d12_resource.cpp:621` — import:

```c
screen->dev->OpenSharedHandle(d3d_handle, IID_PPV_ARGS(&d3d12_res));
```

The import recovers the true layout from the resource itself via `GetDesc()`, so
stride/offset/modifier carried alongside are irrelevant. There is even an existing
cross-device re-import path (`:578`).

`dri_query_dma_buf_formats` (`mesa/src/gallium/frontends/dri/dri_helpers.c:790`) is
generic — it probes `pscreen->is_format_supported` over the format table, which
d3d12 answers already. The format list comes for free.

## Approach: fake dmabuf (recommended)

Make the d3d12 gallium driver claim PRIME support and let the "dmabuf fd" carry a
D3D12 shared handle.

**Why this over a custom Wayland protocol.** Both approaches need the same Mesa
patch. A custom protocol *additionally* needs protocol XML, a new mutter buffer
type and import path, and a patch to Mesa's Wayland EGL platform to use a
non-standard protocol. Faking dmabuf needs **zero mutter changes and zero client
changes**, because everything already speaks `zwp_linux_dmabuf_v1`.

The abuse is safe here specifically because **client and compositor run the same
d3d12 Mesa**. Any private convention smuggled through the fd is interpreted by our
own code on both ends; no third party has to agree with it.

### Step 0 — settle the blocking unknown first

Everything depends on one property that cannot be established by reading Mesa:

> Does the fd from `CreateSharedHandle` survive being passed to **another process**
> over a unix socket via `SCM_RIGHTS`, such that `OpenSharedHandle` resolves it there?

"An fd valid in this process" and "an fd another process can open after receiving
it" are different guarantees. The `(int)(intptr_t)` cast strongly implies a real
Linux fd, and the cross-device re-import path is encouraging, but this is
inference.

**Write a standalone two-process test before touching Mesa.** Parent exports a
resource, passes the fd over a `socketpair` with `SCM_RIGHTS`, child calls
`OpenSharedHandle` and samples it. Roughly an hour of work.

If it fails, **both** approaches are dead in the same way — a custom protocol
depends on exactly the same primitive — and the detour is avoided entirely.

### Step 1 — advertise PRIME  ✅ done, verified

`d3d12_screen.cpp`, in `d3d12_init_screen_caps()` right after
`u_init_pipe_screen_caps()`, on non-Windows:

```c
caps->dmabuf = DRM_PRIME_CAP_IMPORT | DRM_PRIME_CAP_EXPORT;
```

overriding the `u_screen.c:135` default, plus an `#include "drm-uapi/drm.h"`.
This flips `has_dmabuf_import` and makes both EGL extensions appear.

**Verified:** mutter's startup warning is gone and it now exposes
`zwp_linux_dmabuf_v1`. (Note this whole mechanism is inside `#ifdef HAVE_LIBDRM`
at `dri_screen.c:668` — the build must link libdrm even though no DRM node is
ever opened.)

### Step 2 — stub the modifier query  ❌ not needed, do not add

`dri_query_dma_buf_modifiers` (`dri2.c:1366`) already handles a NULL
`query_dmabuf_modifiers` by returning success with `*count = 0`, and mutter's
`add_format` (`meta-wayland-dma-buf.c:1759`) appends a `DRM_FORMAT_MOD_INVALID`
fallback entry per format regardless of what EGL reports. So the format list is
advertised as implicit-modifier, which is the truth for us. A stub would have to
claim LINEAR — a lie about a tiled D3D12 resource — to add nothing.

### Step 3 — tolerate meaningless metadata  ✅ nothing to change

`d3d12_resource_from_handle` never reads `handle->stride/offset/modifier`; it
recovers everything from `GetDesc()`. `dri2_get_modifier_num_planes` maps
`MOD_INVALID` to the plain plane count, so import is not rejected.

Export works by a route worth recording: `resource_get_param` returns false for
`PIPE_RESOURCE_PARAM_HANDLE_TYPE_FD`, so `dri2_query_image` falls through to
`dri2_query_image_by_resource_handle`, which calls `d3d12_resource_get_handle`
with `WINSYS_HANDLE_TYPE_FD` — the `CreateSharedHandle` path. Allocation is
already correct too: `__DRI_IMAGE_USE_SHARE` → `PIPE_BIND_SHARED` →
`D3D12_HEAP_FLAG_SHARED` (`d3d12_resource.cpp:357`).

### Step 3b — the client side (the step this plan originally missed)

Step 1 fixes the *compositor*. Clients kept sending shm, because Mesa's own
client-side EGL never offers them anything else.

d3d12 is instantiated as a **software** target — `sw_helper.h:65` reaches it via
`d3d12_create_dxcore_screen` under the driver name `swrast`. So
`dri2_initialize_wayland` took `dri2_initialize_wayland_swrast`, which binds only
`wl_shm` and installs a `putImage`-into-shm vtbl. The dmabuf-capable path
(`dri2_initialize_wayland_drm`) was unreachable: it bails at `fd_render_gpu == -1`
because the compositor's `main_device` names a DRM node that does not exist here.

The claim "zero client changes" holds for Wayland clients as protocol peers, but
not for Mesa's EGL.

The fix keeps the whole existing dmabuf client path and only removes its
dependence on having a DRM fd. Three edits:

1. `egl/drivers/dri2/platform_wayland.c` — in
   `dri2_initialize_wayland_drm_extensions`, when there is no render node but
   `wl_dmabuf` is bound, return success instead of falling through to `wl_drm`.
   In `dri2_initialize_wayland_drm`, take `driver_name = "swrast"` and skip the
   fd-based device/driver probing. After `dri2_setup_screen`, bail if the driver
   turns out not to do dma-buf, so `eglInitialize`'s retry ladder
   (`eglapi.c:697`) still lands on the old shm path for drivers that need it.

   This works because the dma-buf feedback handlers are device-agnostic — the
   format table populates `formats` fine, and `default_dmabuf_feedback_main_device`
   simply returns when the node cannot be opened.

2. `gallium/frontends/dri/dri_drawable.c` — for `DRI_SCREEN_SWRAST`, use
   `dri2_init_drawable` (image-loader allocation) when the loader supplied an
   image loader, else `drisw_init_drawable` as before. This new path is the only
   way to reach that combination, so the test is unambiguous.

3. `gallium/frontends/dri/drisw.c` — `drisw_init_screen` must tolerate a NULL
   `swrast_loader`, since we now pass only the image loader extensions. Nothing
   presents through `drisw_lf` in that configuration.

`get_back_bo` and `create_wl_buffer` then work unmodified: `fd_render_gpu` and
`fd_display_gpu` are both -1, so every cross-GPU branch compares equal and is
skipped, and `create_wl_buffer` sends `DRM_FORMAT_MOD_INVALID`, which mutter
accepts via its fallback entry.

### Step 4 — verify end to end

Re-run with `MUTTER_DEBUG=wayland`. Success is the damage lines reading
`dma-buf buffer ...` instead of `shm buffer ...`. (The startup warning is already
gone as of step 1.)

## Scope — what this does and does not fix

It removes the per-client upload: readback, memcpy, and texture realloc.

It does **not** touch the RDP path. `cogl_framebuffer_read_pixels` into shared
memory stays exactly as it is. Decide which number is actually being optimised
before investing here — on the profile, both the client upload and the RDP
readback were significant, but they are independent.

Note also that step 3b removes the shm path *for clients on this display*. If a
client ends up on a driver that cannot export, `eglInitialize` retries and it
lands back on shm — but that retry is per-display, not per-surface.


---


All four Mesa edits are in the tree. Step 1 is verified in WSL; step 3b is
written but not yet run.
you wrote a tool to test server/tools/d3d12-share-test/main.cpp
It works:
```oliver@mb-LenovoThinkPad ~/d/w/t/d3d12-share-test (main)> ./poc
[child] adapter: NVIDIA GeForce 940MX
[parent] adapter: NVIDIA GeForce 940MX
[parent] created shared 256x128 texture
[parent] CreateSharedHandle -> 24
[parent] handle is a valid fd in this process
[parent] sent fd over SCM_RIGHTS, waiting for child
[child] received fd 24
[child] OpenSharedHandle -> 256x128 fmt=87
[child] PASS: shared handle survived the process boundary
```

So i guess we can continue with patching mesa.
