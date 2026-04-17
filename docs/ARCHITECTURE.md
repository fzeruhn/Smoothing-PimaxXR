# Runtime Motion-Smoothing Architecture

## Project Context

This fork adds runtime-integrated motion smoothing to `pimax-openxr`. The runtime already owns the frame pacing and compositor submission path, so the architecture is built around extending existing runtime responsibilities instead of intercepting another runtime from the outside.

## Current Runtime Reality

Today, the runtime already does the following:

- accepts application frames through OpenXR swapchains
- tracks frame cadence in `xrWaitFrame`, `xrBeginFrame`, and `xrEndFrame`
- translates OpenXR projection and quad layers into PVR compositor layers
- forwards application depth when `XR_KHR_composition_layer_depth` is present
- performs graphics API interop for Vulkan, D3D11, D3D12, and OpenGL sessions
- already translates multiple app graphics APIs into the runtime submission path:
  - D3D11 input is used directly
  - D3D12 input is imported from shared handles and synchronized into D3D11-backed submission
  - Vulkan input is imported as `VkImage` resources from shared runtime textures and synchronized into D3D11-backed submission
- optionally submits on an async runtime thread before `pvr_endFrame`

That means the runtime already has the authority needed to implement motion smoothing. What it does not have yet is a dedicated synthesis pipeline and a scheduler that can emit headset-rate output from an arbitrary app frame cadence.

## Scope: Motion Smoothing vs. Late-Stage Reprojection

It is crucial to understand that motion smoothing and Late-Stage Reprojection (LSR) are two completely different systems that run sequentially.

- **Motion Smoothing (Our Job):** Fixes animation and translation. If a spaceship is flying past the user, or they are waving their hands, motion smoothing synthesizes the missing frames so objects move fluidly across the screen.
- **Late-Stage Reprojection (Not Our Job):** Fixes head rotation (3-DOF). This is an always-on spatial reprojection process handled by the headset and PVR SDK at display refresh rate.

When the app drops to very low FPS (e.g. 10 FPS), our motion smoothing will likely fail because motion vectors between frames are too large to synthesize a clean image. In this scenario, our system passes the stale frames to the headset. LSR will still run at 90Hz, taking the stale frame and spatially rotating it to match the user's head movement at the millisecond of display. The result: objects will look like a slideshow, but looking around will feel smooth and the user won't get motion sick.

LSR is a safety net that is always active underneath us.

Our entire focus is isolated to: take two images, generate motion vectors, synthesize (a) middle image(s), and hand it to the existing compositor.

## Target Direction

### High-Level Pipeline

1. The app renders into runtime-visible swapchains using D3D11, D3D12, or Vulkan.
2. At `xrEndFrame`, the runtime captures:
   - color
   - depth when available
   - render pose / view state
   - timestamps and frame identifiers
   - app-provided motion vectors and depth via `XrCompositionLayerSpaceWarpInfoFB`, when the app attaches this struct to its projection layers
3. The runtime translates the incoming API-specific resources into Vulkan-backed smoothing resources, then copies or aliases them into runtime-owned history resources.
4. On the first `xrEndFrame`, the runtime checks the composition-layer chain for both `XrCompositionLayerDepthInfoKHR` and `XrCompositionLayerSpaceWarpInfoFB`. If either is absent, the missing extension is logged by name and smoothing is disabled for the session. There is no estimation fallback.
5. When both are present, the runtime ingests app-provided scene-motion vectors (already excluding head rotation) and depth into Vulkan-backed resources.
6. The synthesis pipeline generates an intermediate frame for the target display time using a three-pass approach: velocity dilation → backward warp (3D reprojection using depth + scene-motion vectors + fresh IMU pose at the target display time) → depth-weighted hole-fill.
7. A submission scheduler decides whether to submit:
   - a fresh real frame
   - a synthesized frame
   When synthesis is unavailable, the scheduler passes the most recent real frame. The headset's LSR handles rotational correction.
8. The runtime packages the chosen result into the compositor submission path and completes `pvr_endFrame`.

## Subsystems

### Frame Capture And History

Responsibilities:

- capture the app-submitted frame at `xrEndFrame`
- retain color, depth, pose, and timestamps in runtime-owned history slots
- detect `XrCompositionLayerSpaceWarpInfoFB` in the composition-layer chain and capture app-provided motion-vector and depth images when present
- keep history lifetime independent from app swapchain reuse
- provide bounded buffering and explicit overload behavior
- normalize D3D11, D3D12, and Vulkan input into a Vulkan-backed representation immediately or at a clearly defined capture boundary
- use a fixed-capacity pooled allocation model for steady-state history images and intermediate buffers
- enforce a VRAM budget per eye, format class, and buffering stage so history growth cannot become unbounded under load

Primary integration points:

- `frame.cpp` for capture timing and layer traversal
- `swapchain.cpp` for image selection and lifecycle state
- `runtime.h` for shared ownership and history metadata

### Depth Handling And Normalization

Responsibilities:

- ingest `XR_KHR_composition_layer_depth` when available
- normalize depth range and convention before synthesis
- preserve enough metadata to support reprojection and occlusion decisions
- keep depth handling compatible with D3D11, D3D12, and Vulkan input paths before normalization into the Vulkan smoothing path

Primary integration points:

- `frame.cpp` for composition-layer chain parsing
- interop files for API-specific image access and transitions

### Motion-Vector Sourcing

Motion vectors are provided exclusively by the application via `XR_FB_space_warp`. There is no runtime estimation fallback.

#### Application SpaceWarp (`XR_FB_space_warp`)

1. During session creation, the application queries the runtime for `XR_FB_space_warp` support. The runtime advertises the extension.
2. The application creates dedicated swapchains for motion vectors (typically `R16G16B16A16_SFLOAT`) and depth.
3. At `xrEndFrame`, the application attaches an `XrCompositionLayerSpaceWarpInfoFB` struct to each projection layer. This struct references the motion-vector image, the depth image, and associated near/far plane metadata.
4. On the **first** `xrEndFrame`, the runtime verifies that both `XrCompositionLayerDepthInfoKHR` and `XrCompositionLayerSpaceWarpInfoFB` are present. If either is absent, the runtime logs the missing extension by name and sets a session-scoped flag that disables all smoothing for the remainder of the session, restoring `xrWaitFrame` to 1× pacing.
5. When both are present, the runtime ingests the app-provided vectors and depth into Vulkan-backed resources for use by the synthesis pipeline.

App-provided vectors represent scene motion only — they do not include head rotation. The synthesis pipeline uses a fresh IMU pose at the target display time to account for head movement during the 3D reprojection step, keeping these two concerns cleanly separated.

#### Vector Format And Coordinate Mapping

The coordinate-space and format mapping from `XrCompositionLayerSpaceWarpInfoFB` into the internal representation used by synthesis must be defined explicitly before synthesis work begins. This mapping covers:

- screen-space coordinate convention and scale
- relationship between app-provided depth and the depth normalization convention from the Depth Handling subsystem
- near/far metadata attached to the SpaceWarp struct


### Frame Synthesis And Hole Filling

Responsibilities:

- synthesize an intermediate image by warping the most recent real frame forward to the target fractional display time `f`
- produce runtime-owned submission-ready images rather than patching app-owned swapchain images in place

The pipeline is three passes:

1. **Velocity dilation:** Expand the app motion-vector field outward using the maximum-magnitude vector in a 3×3 pixel neighborhood. This ensures fast-moving foreground objects correctly claim their destination pixels during the backward warp, preventing the background vector at the destination from being used instead.

2. **Backward warp (3D reprojection):** For each output pixel:
   - Sample the dilated motion vector at the destination position.
   - Unproject the source pixel using depth and the render camera matrix to a 3D world-space point.
   - Apply `f × scene_velocity` (from the app motion vector, converted to world-space displacement) to move the point.
   - Reproject with the camera matrix built from the fresh IMU pose at the target display time to find the source sample position.
   - Sample color from the previous real frame at that position.
   - Mark pixels with a large depth discontinuity between neighbors as disocclusion holes.

3. **Depth-weighted hole-fill:** Inpaint only the marked disocclusion regions. Weight neighbor contributions by depth similarity to prevent foreground content from bleeding into newly exposed background gaps. Holes are always background by definition (they were occluded in the previous frame), so filling them with neighboring background pixels is correct.

The synthesized frame is submitted with the interpolated pose at the target display time. The headset's LSR corrects for the small residual between the predicted and actual display-time pose.

### Runtime Pacing And Scheduling

Responsibilities:

- lock the app to a fractional headset framerate by returning predicted display times spaced at `divisor × idealFrameDuration` from `xrWaitFrame`, blocking the app thread accordingly; the existing `dbg_force_framerate_divide_by` / `m_lockFramerate` mechanism in `session.cpp` is the foundation for this
- decide whether the next output should be a real frame or a synthesized frame (when neither is available, pass the most recent real frame and rely on the headset's LSR for rotational correction)
- preserve valid OpenXR and PVR frame ordering
- avoid stalling the app thread where possible
- keep application prediction, simulation timing, and headset submission timing internally coherent

**Rate divisor:** `smoothing_rate_divisor` registry key selects between 2 (1/2 rate, one synthesized frame per real frame) and 3 (1/3 rate, two synthesized frames per real frame). The 1/3 rate mode is deferred until 1/2 rate is validated end-to-end.

Primary integration points:

- `frame.cpp` as the pacing and composition entrypoint
- `session.cpp` for mode gating, tunables, and rollout toggles
- `runtime.h` for frame counters, state, and cross-thread signaling

### GPU Interop And Synchronization

Responsibilities:

- keep runtime-owned history and output images synchronized across the chosen graphics path
- make ownership transfers and queue usage explicit
- support capture, synthesis, and submission without corrupting app-visible resources
- define how D3D11, D3D12, and Vulkan inputs are translated into Vulkan-backed smoothing resources
- define how synthesized Vulkan output re-enters the runtime submission backend used for headset submission
- define where smoothing compute executes and what happens when a dedicated compute queue is unavailable

Primary integration points:

- `vulkan_interop.cpp`
- `d3d11_native.cpp`

### Diagnostics And Validation

Responsibilities:

- trace capture timestamps, history depth, scheduling decisions, and synthesis latency
- expose enough logging to separate pacing problems from synthesis problems
- keep validation usable during headset and game testing

### Companion App And Debug Overlay

Responsibilities:

- extend the existing companion app (`companion/`) with motion-smoothing controls:
  - master enable/disable toggle for the added motion smoothing
  - rate divisor selection (1/2 rate or 1/3 rate); persisted as `smoothing_rate_divisor`; takes effect on next session start
  - debug overlay enable/disable
- implement a runtime debug overlay rendered into the compositor output:
  - smoothing active or disabled, with reason if disabled (missing depth, missing motion vectors, or user-disabled)
  - synthesis latency per frame (ms)
  - app cadence vs. headset cadence and percent of target achieved
  - frame history depth and drop counts
  - current rate divisor in use
- companion app settings are persisted through the existing registry-based settings mechanism (`MainForm.WriteSetting` / `MainForm.RegPrefix`)
- the runtime reads smoothing settings from the registry at session initialization and respects live changes where safe
- the debug overlay is rendered using existing runtime text/drawing infrastructure or a minimal addition (e.g. `FW1FontWrapper` already present in the repo)

Primary integration points:

- `companion/MainForm.cs` and `companion/ExperimentalSettings.cs` for GUI controls
- `session.cpp` for reading smoothing settings from registry
- `frame.cpp` or a new `debug_overlay.cpp` for overlay rendering
- `runtime.h` for overlay state and configuration

## Constraints And Invariants

- The final compositor submission path remains inside the runtime.
- `frame.cpp` stays the orchestration point for pacing and submission decisions, not the home for every smoothing algorithm.
- Runtime-owned history is required. App-owned swapchain images are not a safe long-term history source.
- D3D11, D3D12, and Vulkan app input are all in scope. The architecture must not assume a Vulkan-only application world.
- App-provided depth (`XR_KHR_composition_layer_depth`) and scene-motion vectors (`XR_FB_space_warp`) are both required. If either is absent at the first `xrEndFrame`, the missing extension is logged by name and smoothing is disabled for the session. There is no estimation fallback and no degraded-quality mode.
- Eye tracking and foveated estimation are not part of this project. No smoothing code should depend on `XR_EXT_eye_gaze_interaction`.
- The scheduler must preserve valid timing semantics even when synthesis misses its deadline.
- The smoothing pipeline should have one execution backend: Vulkan.
- The runtime already translates multiple app APIs into a common submission backend. Motion smoothing should reuse or extend that translation model so all three input APIs converge into Vulkan for smoothing, then return to the headset submission path.
- Steady-state smoothing operation must not depend on unbounded Vulkan image allocation. History and intermediate resources need a pooled lifetime model and an explicit VRAM budget.
- `xrWaitFrame` is part of the scheduling contract, not just an input to it. Once runtime cadence diverges from direct headset cadence, predicted display times exposed to the app must be defined intentionally. The existing `dbg_force_framerate_divide_by` mechanism is the foundation; extend it rather than replacing it.

## Architecture Gates

These are explicit decisions that must be resolved during implementation:

### Gate A: Input-To-Vulkan Normalization Strategy

- Option 1: normalize D3D11 and D3D12 input into Vulkan-backed resources immediately at capture time
- Option 2: retain API-specific history briefly and normalize into Vulkan at the motion-estimation boundary

Recommended initial choice: converge toward Vulkan-backed smoothing resources as early as practical, because the repo already uses shared-resource translation and the synthesis stack should not be triplicated.

### Gate B: Submission Backend Strategy

- Option 1: keep runtime submission D3D11-backed initially and bridge synthesized output into that path
- Option 2: move toward a cleaner Vulkan-owned submission path for the smoothing pipeline

This is the most important structural decision because it determines synchronization design and the shape of history/output resources.

### Gate C: `xrWaitFrame` And Pacing Contract

- Define what predicted display time the application receives once synthetic cadence exists
- Define whether the app continues to see native runtime cadence, a scheduler-adjusted cadence, or another explicit pacing model
- Define how that choice interacts with simulation timing, pose prediction, and runtime frame scheduling

This must be explicit before scheduler work is considered complete.

### Gate D: Depth Normalization Policy

- Define how near/far, reversed-Z, and submitted depth ranges are normalized before reprojection and synthesis
- This must be explicit before motion-estimation quality work begins

### Gate E: Frame-History Bounding, Pooling, And Drop Policy

- Define history size
- Define pooled allocation strategy for history and intermediate Vulkan resources
- Define VRAM budget and reuse rules
- Define what gets dropped first under overload
- Define which timestamps are authoritative for synthesis targets

Without this, cadence behavior will become unstable under real game load.

### Gate F: Queue And Compute Execution Strategy

- Prefer a dedicated Vulkan compute queue when the device and runtime path expose one safely
- Define fallback behavior when smoothing must share an existing queue with other work
- Measure whether queue contention, normalization cost, or synthesis cost is the real deadline bottleneck

Do not assume that a separate high-priority queue is always available. The architecture must remain valid without that guarantee.

### Gate G: Application SpaceWarp Vector Format And Coordinate Normalization

- Define how `XrCompositionLayerSpaceWarpInfoFB` motion-vector images are interpreted: coordinate space, scale, and handedness
- Define the mapping from app-provided vector format into the internal representation consumed by synthesis
- Define how app-provided depth from the SpaceWarp struct relates to the depth normalization policy from Gate D
- Define how app-provided vectors (scene motion only, no head rotation) combine with the fresh IMU pose in the 3D reprojection step of synthesis; the head pose accounts for head movement independently of the scene-motion vectors

## Completion Path

The architecture should be implemented in this order:

1. Establish history ownership and capture boundaries.
2. Define the input normalization path that converts D3D11, D3D12, and Vulkan input into Vulkan-backed smoothing resources.
3. Define pooled allocation, VRAM budgeting, and overload policy for Vulkan-backed history.
4. Normalize depth and timestamp handling.
5. Advertise `XR_FB_space_warp` and implement detection at `xrEndFrame`. On the first frame, verify both `XrCompositionLayerDepthInfoKHR` and `XrCompositionLayerSpaceWarpInfoFB` are present; if either is absent, log the missing extension and disable smoothing for the session.
6. Define the vector format and coordinate mapping from `XrCompositionLayerSpaceWarpInfoFB` into the internal representation (Gate G).
7. Add synthesis and hole filling in Vulkan: velocity dilation → backward warp (3D reprojection with depth + scene-motion vectors + fresh IMU pose) → depth-weighted hole-fill.
8. Define how synthesized Vulkan output is handed back to the headset submission backend.
9. Extend the `xrWaitFrame` pacing contract to support `smoothing_rate_divisor` (2 or 3), building on the existing `dbg_force_framerate_divide_by` mechanism. Add scheduler decisions at headset cadence. Validate 1/2 rate before enabling 1/3 rate.
10. Tune performance, queue strategy, fallback behavior, and diagnostics.
11. Add motion-smoothing controls to the companion app and implement a runtime debug overlay for performance monitoring.

See `docs/ROADMAP.md` for the execution phases.
