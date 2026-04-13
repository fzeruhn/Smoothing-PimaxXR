# Runtime Motion-Smoothing Fork - Engineer Context

## Project Context

This repository is a fork of the PimaxXR runtime. The motion-smoothing goal for this fork is no longer to inject frames from an external OpenXR API layer. The runtime itself already owns the frame lifecycle that matters:

- `xrWaitFrame`
- `xrBeginFrame`
- `xrEndFrame`
- swapchain creation and image enumeration
- graphics API interop
- final `pvr_beginFrame` / `pvr_endFrame` submission to the Pimax compositor

That means motion smoothing must be implemented as a runtime-integrated frame capture, synthesis, translation, and scheduling system inside `pimax-openxr`.

## Session Start Checklist

At the start of every session:

1. Run `git submodule status`.
2. If any line begins with `-`, initialize submodules before doing anything else:
   `git submodule update --init --recursive`

This repo depends on submodules for successful builds and for the external SDK code used by the solution.

## Current Runtime Reality

The runtime already has important pieces that change the implementation strategy:

- `pimax-openxr/frame.cpp`
  - owns `xrWaitFrame`, `xrBeginFrame`, `xrEndFrame`
  - builds PVR layer lists from OpenXR composition layers
  - forwards projection depth when the app provides `XR_KHR_composition_layer_depth`
  - already contains an asynchronous submission thread path
  - will be the detection point for `XrCompositionLayerSpaceWarpInfoFB` structs attached to composition layers at `xrEndFrame`
- `pimax-openxr/session.cpp`
  - controls mode gating and runtime settings
  - toggles `async_submission`, `defer_frame_wait`, `lock_framerate`, and related timing behavior
- `pimax-openxr/runtime.h`
  - holds shared runtime state, swapchain bookkeeping, frame counters, async thread state, and graphics API handles
- `pimax-openxr/swapchain.cpp`
  - owns OpenXR swapchain objects and image lifecycle bookkeeping
- `pimax-openxr/vulkan_interop.cpp`
  - owns Vulkan session initialization, Vulkan swapchain image import, queue usage, synchronization, and timing support
  - currently relies on timeline semaphore assumptions in the Vulkan interop path
- `pimax-openxr/d3d11_native.cpp`
  - owns the D3D11 submission path and intermediate copy / conversion resources used by the runtime

Input support for smoothing should cover all three app graphics APIs already exposed by the runtime:

- D3D11 input
  - the runtime exposes D3D11 swapchain images directly to the app
  - submission is already D3D11-native
- D3D12 input
  - the runtime opens shared resources on the D3D12 device
  - synchronization already bridges the D3D12 queue to the D3D11 submission path
- Vulkan input
  - the runtime imports shared swapchain resources as `VkImage` objects
  - synchronization already bridges the Vulkan queue to the D3D11 submission path

So the correct design is not "Vulkan only exists" and not "three fully separate runtimes." The repo already has translation machinery that feeds multiple app APIs into a common runtime submission path. Motion smoothing must account for all three inputs, but the smoothing work itself should converge into a Vulkan-backed pipeline before final headset submission.

## Implementation Status For This Fork

### Already Present

- Runtime-owned frame pacing through `xrWaitFrame -> xrBeginFrame -> xrEndFrame`
- Existing async submission thread in `frame.cpp`
- Existing Vulkan, D3D11, D3D12, and OpenGL interop/session paths
- Existing cross-API translation into the runtime submission path:
  - D3D11 direct submission
  - D3D12 shared-resource import plus D3D11-backed submission
  - Vulkan imported images plus D3D11-backed submission
- Existing building blocks for a Vulkan-backed smoothing path on top of the current runtime translation model
- Existing projection-layer depth forwarding from `XR_KHR_composition_layer_depth`
- Existing frame timing, running-start, deferred frame wait, and lock-framerate behavior
- Existing GPU timing and tracing hooks useful for observability

### Planned: Application SpaceWarp (`XR_FB_space_warp`)

The runtime will advertise the `XR_FB_space_warp` extension. When an application supports it, the app creates dedicated motion-vector and depth swapchains and attaches an `XrCompositionLayerSpaceWarpInfoFB` struct to its projection layers at `xrEndFrame`. The runtime detects this struct and uses the app-provided motion vectors directly, bypassing OFA-based motion estimation entirely.

When the extension is not used by the app (the common case for most PCVR titles today), the system falls back to OFA-based motion estimation as designed. This is a per-frame check: if the struct is present, use app vectors; if absent, run OFA. Both paths feed into the same downstream synthesis and scheduling pipeline.

### Provided By Hardware And PVR SDK (Not Our Job)

- **Late-Stage Reprojection (LSR):** The headset and PVR SDK perform always-on 3-DOF rotational reprojection at display refresh rate. If the app or our motion smoothing fails to deliver a frame (either due to failed smoothing or the incoming app fps being too low to smooth), LSR still corrects for head rotation so the user does not get motion sick. This is a safety net that runs underneath our code at all times.

Our focus is exclusively: take two frames, generate motion vectors, synthesize a middle frame, and hand it to the existing compositor. When synthesis is unavailable or fails, we pass the most recent real frame and let the headset's LSR handle rotational correction.

### Missing For Motion Smoothing

- A runtime-owned frame-history ring for color, depth, pose, and timestamps
- Deterministic ownership rules for history images independent of app swapchain lifetime
- A defined normalization step that converts D3D11, D3D12, and Vulkan inputs into Vulkan-backed smoothing resources
- A Vulkan-backed history representation for color, depth, pose, and timestamps after normalization
- Optical-flow / motion-estimation integration such as NVIDIA OFA
- `XR_FB_space_warp` extension advertisement, struct detection, and app-provided motion-vector ingestion as an alternative to OFA
- A dual-path motion-vector source abstraction that selects between app-provided vectors (Application SpaceWarp) and runtime-estimated vectors (OFA) per frame
- Depth normalization policy across app conventions
- Pose reprojection and head-motion removal before motion estimation (OFA path only; app-provided vectors already account for scene motion)
- Stereo vector adaptation strategy
- Frame synthesis and hole-filling stages
- A scheduler that chooses real frame vs synthesized frame at headset cadence
- A production-safe synchronization model for the chosen graphics path

## Constraints And Invariants

- OpenXR pacing must remain valid. Keep the `xrWaitFrame -> xrBeginFrame -> xrEndFrame` contract intact.
- `pvr_beginFrame` / `pvr_endFrame` ownership stays inside the runtime. Do not move final submission authority back out into an external layer.
- The existing async submission path is a base to evolve, not something to discard without replacing its timing guarantees.
- D3D11, D3D12, and Vulkan app input are all in scope for this fork. The docs and implementation should assume all three may need smoothing support.
- The smoothing pipeline itself should run in Vulkan. Non-Vulkan app input must be normalized into Vulkan-backed resources before motion estimation and synthesis.
- The runtime already performs API translation into its submission path. Reuse that where practical instead of designing a brand-new per-API submission stack without justification.
- Vulkan interop currently uses timeline semaphores. Treat that as an implementation constraint that may need redesign for the final smoothing path.
- Motion smoothing must not depend on reviving the abandoned API-layer architecture.
- Runtime behavior must remain debuggable through existing logs, traces, and frame timing instrumentation.

## Main Files For Motion-Smoothing Work

- `pimax-openxr/frame.cpp` — also the detection point for `XrCompositionLayerSpaceWarpInfoFB`
- `pimax-openxr/session.cpp` — extension advertisement and negotiation for `XR_FB_space_warp`
- `pimax-openxr/swapchain.cpp`
- `pimax-openxr/runtime.h`
- `pimax-openxr/vulkan_interop.cpp`
- `pimax-openxr/d3d11_native.cpp`

New smoothing subsystems should be added as dedicated runtime components instead of bloating `frame.cpp`. `frame.cpp` should remain the orchestration point for pacing, composition capture, and final submission decisions.

## Working Direction

The intended completion path for this fork is:

1. Stabilize frame ownership, capture points, and observability in the current runtime.
2. Add runtime-owned normalization and history resources that convert D3D11, D3D12, and Vulkan input into Vulkan-backed smoothing data.
3. Advertise `XR_FB_space_warp` and implement detection of `XrCompositionLayerSpaceWarpInfoFB` at `xrEndFrame`. When present, ingest app-provided motion vectors and depth directly, bypassing OFA.
4. Integrate OFA-based motion estimation and pose reprojection for apps that do not provide vectors.
5. Add synthesis and hole-filling stages in the Vulkan pipeline (shared by both vector sources).
6. Bridge the synthesized Vulkan result back into the runtime headset submission path.
7. Upgrade the runtime scheduler so output cadence tracks the headset refresh rate even when app cadence does not.

See `docs/ARCHITECTURE.md` for the target design and `docs/ROADMAP.md` for the phased execution plan.
