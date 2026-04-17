# Runtime Motion-Smoothing Roadmap

## Project Context

This roadmap is for completing runtime-integrated motion smoothing inside `pimax-openxr`. The work is intentionally sequenced around the current runtime, not the old API-layer attempt.

## Current Runtime Reality

The repo already has:

- frame pacing and submission control in `frame.cpp`
- runtime settings and mode gating in `session.cpp`
- shared frame and swapchain state in `runtime.h`
- swapchain lifecycle handling in `swapchain.cpp`
- Vulkan interop and synchronization primitives in `vulkan_interop.cpp`
- D3D11-backed submission and conversion infrastructure in `d3d11_native.cpp`
- cross-API input translation already used by the runtime:
  - D3D11 direct path
  - D3D12 shared-resource import into the runtime path
  - Vulkan image import and synchronization into the runtime path
- depth forwarding when apps submit `XR_KHR_composition_layer_depth`
- an existing async submission thread

The missing work is the motion-smoothing-specific capture, history, estimation, synthesis, and scheduling pipeline.

## Phase 0 - Baseline And Observability

### Objective

Establish a trustworthy baseline for the current runtime path before adding synthesis logic.

### Main Implementation Areas

- inventory current timing and submission behavior in `frame.cpp`
- make scheduler-relevant trace points explicit
- document which settings already affect pacing, deferred wait, and framerate locking
- identify the real graphics-path constraints for D3D11, D3D12, and Vulkan input and for the current runtime submission backend
- identify where `xrWaitFrame` predictions come from today and what assumptions the app currently inherits from them

### Exit Criteria

- baseline runtime behavior is understood and reproducible
- capture points for color, depth, pose, and timestamps are identified
- current translation behavior across D3D11, D3D12, and Vulkan input is documented
- traces can distinguish app cadence, runtime cadence, and submission latency
- the current `xrWaitFrame` contract is documented well enough to redefine it later without guessing

### Risks / Blockers

- hidden coupling between current async submission and existing timing overrides
- insufficient trace coverage to debug scheduling failures later
- hidden coupling between current `xrWaitFrame` predictions and application simulation behavior

## Phase 1 - Input Normalization, Frame History, And Resource Ownership

### Objective

Introduce runtime-owned frame history with deterministic lifetime and bounded buffering across D3D11, D3D12, and Vulkan input, with normalization into Vulkan-backed smoothing resources.

### Main Implementation Areas

- add history slots for color, depth, pose, and timestamps
- decouple history resources from app swapchain reuse
- define how D3D11, D3D12, and Vulkan input normalize into Vulkan-backed smoothing resources
- define pooled allocation and reuse for Vulkan history images and intermediate smoothing resources
- define explicit VRAM budget limits and failure policy
- define slot allocation, reuse, and eviction policy
- ensure synchronization rules are explicit for capture and later reuse

### Exit Criteria

- the runtime can retain multiple recent frames without depending on app-owned lifetime
- the runtime has a defined normalization path from D3D11, D3D12, and Vulkan input into Vulkan-backed history resources
- Vulkan-backed history and intermediate resources are pooled and reused in steady state
- VRAM consumption is bounded by explicit policy rather than growth by demand
- history metadata is complete enough to drive synthesis later
- overload behavior is bounded and deterministic

### Risks / Blockers

- submission path may currently assume immediate consumption of app-owned resources
- normalization into Vulkan may add hidden copies or synchronization costs
- naive Vulkan image allocation can cause out-of-memory failures in heavy games
- poor ownership boundaries will make later synthesis race-prone

## Phase 2 - Depth Validation And Normalization

### Objective

Make depth input usable and predictable for reprojection and synthesis.

### Main Implementation Areas

- validate `XR_KHR_composition_layer_depth` ingestion on target apps
- normalize reversed-Z, near/far, and submitted depth ranges
- if depth is absent at the first `xrEndFrame`, log the missing extension and disable smoothing for the session (no fallback)
- ensure depth metadata stays attached to history entries
- verify depth behavior for D3D11, D3D12, and Vulkan application inputs

### Exit Criteria

- depth is normalized into one internal convention
- runtime correctly detects and logs absent depth at first frame and disables smoothing for the session
- history entries carry enough depth state for later processing

### Risks / Blockers

- depth conventions may vary across engines and renderers

## Phase 3 - Motion-Vector Sourcing: Application SpaceWarp

### Objective

Ingest app-provided motion vectors as the sole source for synthesis. App-provided vectors via `XR_FB_space_warp` are required; there is no runtime estimation fallback. If the app does not provide vectors (or depth), smoothing is disabled for the session.

### Main Implementation Areas

- advertise `XR_FB_space_warp` in the runtime's extension list during `xrEnumerateInstanceExtensionProperties`
- handle app creation of motion-vector swapchains (typically `R16G16B16A16_SFLOAT`) and associated depth swapchains
- detect `XrCompositionLayerSpaceWarpInfoFB` structs attached to projection layers at `xrEndFrame`
- on the first `xrEndFrame`, check that both `XrCompositionLayerDepthInfoKHR` and `XrCompositionLayerSpaceWarpInfoFB` are present; if either is absent, log the missing extension by name and set a session-scoped flag that disables all smoothing for the remainder of the session
- ingest app-provided motion-vector and depth images into Vulkan-backed resources alongside the color history
- define the coordinate-space and format mapping from the `XR_FB_space_warp` specification into the internal vector format consumed by synthesis

### Exit Criteria

- runtime advertises `XR_FB_space_warp` and apps that support it can provide motion-vector and depth swapchains
- on first `xrEndFrame`, runtime correctly detects missing depth or motion vectors, logs specifically which is absent, and disables smoothing for the session
- app-provided motion-vector and depth images are ingested into Vulkan-backed resources and available to the synthesis pipeline
- the coordinate-space and format mapping from `XrCompositionLayerSpaceWarpInfoFB` to the internal vector format is defined and validated

### Risks / Blockers

- very few PCVR titles currently implement `XR_FB_space_warp`; initial testing may require a custom test harness or a game mod (e.g. UEVR) that exports vectors
- `XR_FB_space_warp` vector format and coordinate conventions require non-trivial normalization
- Vulkan interop may need redesign because of current timeline-semaphore assumptions

## Phase 4 - Synthesis And Hole Filling

### Objective

Generate submission-ready intermediate frames by warping the most recent real frame forward to the target display time.

### Main Implementation Areas

- implement velocity dilation pre-pass: for each pixel, expand the motion-vector field outward using the maximum-magnitude vector in a 3×3 neighborhood, so fast-moving foreground objects correctly claim their destination pixels during the backward warp
- implement backward-warp pass: for each output pixel at fractional time `f`, sample the dilated motion vector, unproject the source pixel using depth and the render camera matrix, apply `f × scene_velocity` to the 3D point, then reproject using the fresh IMU pose at the target display time to find the source sample position; mark pixels with large depth discontinuity as disocclusion holes
- implement depth-weighted hole-fill pass: inpaint only the marked disocclusion regions using neighboring background pixels; weight contributions by depth similarity to prevent foreground content from bleeding into background holes
- produce runtime-owned synthesized output images ready for scheduler consumption
- ensure synthesized Vulkan output can be handed back to the current headset submission backend regardless of input API

### Exit Criteria

- synthesized frames can be generated from the most recent real frame using app-provided depth and motion vectors
- velocity dilation correctly places fast-moving foreground objects at their destination in the output
- hole-fill covers disocclusion regions without visibly smearing foreground content into background gaps
- output quality is stable enough for headset validation
- synthesis output is independent from app swapchain lifetime

### Risks / Blockers

- visual artifacts may expose weaknesses in earlier depth or vector stages
- synthesis latency may exceed the usable scheduling budget
- disocclusion hole quality degrades for large foreground objects moving across plain backgrounds

## Phase 5 - Runtime Scheduler At Headset Cadence

### Objective

Lock the app to a fractional headset framerate via `xrWaitFrame` pacing and choose the correct output at each headset display slot.

### Main Implementation Areas

- extend the existing `dbg_force_framerate_divide_by` / `m_lockFramerate` mechanism in `session.cpp` to support a configurable divisor (2 for half-rate, 3 for one-third-rate) read from the registry key `smoothing_rate_divisor`
- update `xrWaitFrame` to return predicted display times spaced at `divisor × idealFrameDuration`, blocking the app thread accordingly; this is already partially in place via the `lock_framerate` path
- select between fresh real frame or synthesized frame at each headset slot (if neither is ready, pass the most recent real frame and rely on the headset's LSR for rotational correction)
- integrate scheduling decisions into the runtime submission path before `pvr_endFrame`
- preserve valid OpenXR and PVR timing semantics

**One-third rate mode is optional and deferred until half-rate mode is validated end-to-end.** At one-third rate, two synthesized frames are produced per real frame (at `f = 1/3` and `f = 2/3`), each requiring its own synthesis pass. Document this in code but do not implement.

### Exit Criteria

- runtime output cadence tracks headset cadence at 1/2 rate
- `xrWaitFrame` pacing correctly spaces app frames using the configured divisor
- scheduler decisions are observable and repeatable
- app frame drops do not automatically collapse runtime output cadence
- the `smoothing_rate_divisor` registry key is read at session initialization and logged

### Risks / Blockers

- existing async submission behavior may need structural changes
- poor drop policy or history policy can create unstable cadence under load
- a mismatched `xrWaitFrame` policy can produce smooth images but unstable world simulation or pose prediction

## Phase 6 - Fallbacks, Tuning, Validation, And Packaging

### Objective

Harden the feature for repeated game testing and future iteration.

### Main Implementation Areas

- validate graceful degradation to stale frames when synthesis is unavailable due to app fps being too low (the headset's LSR handles rotational correction)
- tune latency, queue depth, and history policy
- validate in target games, especially Vulkan titles
- add operational toggles for baseline, capture-only, synthesis, and full scheduler modes
- document repeatable test and rollback procedures

### Exit Criteria

- the runtime falls back gracefully when synthesis misses deadline or inputs are invalid
- performance and quality are measurable on target hardware
- engineers have a repeatable install, test, and triage loop

### Risks / Blockers

- target-game behavior may expose assumptions that do not appear in synthetic tests
- fallback rules may be too slow or too visually disruptive without explicit tuning

## Phase 7 - Companion App Controls And Debug Overlay

### Objective

Add motion-smoothing controls to the existing companion app and implement a runtime debug overlay so smoothing performance can be monitored in real time during headset use.

### Main Implementation Areas

#### 7A - Companion App GUI Extensions

- add a new motion-smoothing settings panel in the companion app
- implement the following controls, persisted through the existing registry mechanism:
  - master enable/disable toggle for motion smoothing
  - rate divisor selector (1/2 rate or 1/3 rate) — note: 1/3 rate requires session restart; persisted as `smoothing_rate_divisor`
  - debug overlay enable/disable toggle
  - debug overlay detail level (minimal / verbose)
- add a restore-defaults action that resets all smoothing settings
- ensure new settings follow the existing pattern: `MainForm.WriteSetting` for persistence, `LoadSettings` for hydration

#### 7B - Runtime Debug Overlay

- implement a lightweight in-headset overlay rendered into the compositor output before `pvr_endFrame`
- the overlay displays:
  - smoothing active or disabled (and reason if disabled: missing depth, missing motion vectors, or user-disabled)
  - synthesis latency (ms) — time from frame intercepted to synthesized image sent to headset
  - app cadence (FPS) vs. headset cadence (FPS) and percent of target achieved
  - frame history ring depth and recent drop count
  - current rate divisor in use (1/2 or 1/3)
- overlay rendering uses existing runtime infrastructure (e.g. `FW1FontWrapper` for text, D3D11 draw calls for geometry) or a minimal Vulkan overlay path if the submission backend has moved to Vulkan by this phase
- overlay must have negligible performance impact (< 0.1 ms per frame)
- overlay visibility is controlled by the companion-app toggle and can be toggled at runtime without restarting the session

### Exit Criteria

- companion app exposes all smoothing settings and they take effect in the runtime
- debug overlay is visible in the headset and accurately reflects real-time smoothing state
- overlay has no measurable impact on smoothing or submission timing
- all settings survive app restart via registry persistence
- restore-defaults correctly resets all smoothing settings

### Risks / Blockers

- overlay rendering must not interfere with compositor submission timing or introduce additional frame latency
- registry-based live settings may cause race conditions if the runtime reads settings concurrently with companion-app writes; access must be synchronized or latched at safe points
- `FW1FontWrapper` may not be suitable if submission moves to Vulkan; a fallback text rendering approach may be needed

## Priority Order

Work in this order:

1. Stabilize ownership, capture points, and timing in the current runtime.
2. Define and validate normalization of D3D11, D3D12, and Vulkan input into Vulkan-backed smoothing resources.
3. Validate and normalize depth input.
4. Advertise `XR_FB_space_warp`, implement capability detection at first `xrEndFrame`, and ingest app-provided motion vectors and depth.
5. Add synthesis and hole filling in Vulkan: velocity dilation → backward warp → depth-weighted hole-fill.
6. Bridge synthesized Vulkan output back into headset submission.
7. Extend the `xrWaitFrame` pacing contract to lock the app at 1/2 rate (and optionally 1/3 rate once 1/2 is stable).
8. Add companion-app controls and debug overlay as a final integration and polish phase.

This order is mandatory.

- The scheduler should not be treated as the first major milestone, because it depends on reliable ownership and valid synthesis inputs.
- There is no runtime motion estimation fallback (no OFA, no compute-shader). If the app does not provide both depth and motion vectors, smoothing is disabled for the session.
- The companion-app and overlay work comes last because it depends on stable runtime settings and a functioning pipeline to observe.

## Validation Path

For every phase, verify:

- no design step assumes the abandoned API-layer architecture
- the implementation path maps back to actual runtime entrypoints in `pimax-openxr`
- new runtime behavior remains observable through logs and traces
- the repo can still be reasoned about without depending on uninitialized submodule contents
