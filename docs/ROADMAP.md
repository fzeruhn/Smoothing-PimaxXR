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
- define fallback behavior when depth is missing or unreliable
- ensure depth metadata stays attached to history entries
- verify depth behavior for D3D11, D3D12, and Vulkan application inputs

### Exit Criteria

- depth is normalized into one internal convention
- runtime can distinguish valid, missing, and suspect depth inputs
- history entries carry enough depth state for later processing

### Risks / Blockers

- some target applications may not submit depth consistently
- depth conventions may vary across engines and renderers

## Phase 3 - Motion-Vector Sourcing: Application SpaceWarp, OFA, And Compute-Shader Fallback

### Objective

Establish all motion-vector sources and a common vector interface that feeds synthesis. Application SpaceWarp (`XR_FB_space_warp`) provides app-engine vectors when available; OFA provides hardware-accelerated runtime-estimated vectors on supported NVIDIA GPUs; a Vulkan compute-shader optical-flow implementation provides a universal fallback for all other hardware.

### Main Implementation Areas

#### 3A - Application SpaceWarp Extension Support

- advertise `XR_FB_space_warp` in the runtime's extension list during `xrEnumerateInstanceExtensionProperties`
- handle app creation of motion-vector swapchains (typically `R16G16B16A16_SFLOAT`) and associated depth swapchains
- detect `XrCompositionLayerSpaceWarpInfoFB` structs attached to projection layers at `xrEndFrame`
- ingest app-provided motion-vector and depth images into Vulkan-backed resources alongside the color history
- validate incoming vectors (range checks, NaN handling, coverage) and fall back to runtime estimation if vectors appear malformed
- define the coordinate-space and format mapping from the `XR_FB_space_warp` specification into the common internal vector format

#### 3B - OFA Motion Estimation (Primary Runtime Fallback)

- detect OFA hardware availability at session initialization (Vulkan extension query, NVAPI, or CUDA capability check)
- define the Vulkan motion-estimation path using OFA
- land the non-Vulkan to Vulkan normalization required to feed that estimator
- define the queue strategy for motion-estimation work
- remove or compensate for head motion before vector estimation
- produce vectors, validity, and confidence data for downstream use
- determine whether stereo uses dual estimation or adapted vectors

#### 3C - Compute-Shader Optical Flow (Universal Fallback)

- implement a Vulkan compute-shader optical-flow algorithm (block-matching or hierarchical Lucas-Kanade) suitable for real-time VR workloads
- use the same Vulkan-backed input pipeline and pose-reprojection logic as the OFA path
- produce vectors in the same common format with confidence metadata
- target acceptable quality at higher GPU cost than OFA; this path trades estimation speed for hardware universality
- backend selection (OFA vs. compute-shader) is a session-initialization decision based on device capability detection

#### 3D - Common Motion-Vector Interface

- define a single internal motion-vector representation consumed by synthesis
- Application SpaceWarp, OFA, and compute-shader paths all produce output in this format — though maybe with different resolutions
- include per-pixel confidence metadata (high-confidence for app vectors, OFA-reported for estimated vectors, compute-shader-reported for fallback vectors)
- include a source tag for diagnostics and telemetry

### Exit Criteria

- runtime advertises `XR_FB_space_warp` and apps that support it can provide vectors
- when app vectors are present, runtime estimation is skipped entirely for that frame
- when app vectors are absent and OFA hardware is available, OFA produces usable motion vectors from adjacent history frames
- when app vectors are absent and OFA hardware is unavailable, compute-shader flow produces usable motion vectors
- all three paths produce output in the common vector format
- motion-estimation latency is measurable and stable (both OFA and compute-shader paths)
- estimation backend is selected at session initialization and logged for diagnostics
- compute execution strategy is defined for both dedicated-queue and shared-queue cases
- vector output from any path is suitable for synthesis input
- diagnostics distinguish app-provided, OFA-estimated, and compute-shader-estimated frames

### Risks / Blockers

- very few PCVR titles currently implement `XR_FB_space_warp`; initial testing may require a custom test harness or a game mod (e.g. UEVR) that exports vectors
- `XR_FB_space_warp` vector format and coordinate conventions may differ from runtime estimation output and require non-trivial normalization
- Vulkan interop may need redesign because of current timeline-semaphore assumptions
- cross-API translation may become the real bottleneck instead of estimation itself
- a dedicated compute queue may not be available or may not be safely usable in the bound runtime device path
- stereo consistency may require extra work beyond a simple single-eye estimate
- compute-shader optical flow will be significantly slower than OFA and may not meet frame-time budget on lower-end GPUs without aggressive foveation or resolution reduction
- compute-shader flow quality may be lower than OFA; acceptable quality thresholds must be defined and tested

## Phase 3B - Foveated Motion-Vector Estimation

### Objective

Add foveated estimation to the runtime estimation paths (OFA and compute-shader) to reduce optical-flow cost by running full-resolution flow only in the user's gaze region and downsampled flow everywhere else. This process is skipped either when no eye tracking data is available, or when disabled from config.

### Main Implementation Areas

- integrate `XR_EXT_eye_gaze_interaction` to acquire per-eye gaze coordinates at `xrEndFrame`
- implement fovea region calculation: a bounding box centered on the gaze point, sized in pixels or degrees of visual angle (tunable)
- implement peripheral downsample pass using fast Vulkan hardware blit (bilinear `vkCmdBlitImage` or lightweight compute dispatch)
- modify the estimation dispatch to process two inputs per eye: full-resolution fovea crop and downsampled periphery
- implement vector rescale: multiply peripheral motion vectors by the downsample ratio to restore correct screen-space magnitude
- implement vector composite: merge fovea and rescaled periphery vectors into a single per-eye motion-vector buffer for downstream synthesis
- expose foveated estimation parameters as runtime settings (fovea size, downsample ratio, enable/disable toggle)
- ensure the downsample cost is less than the flow savings; add telemetry to measure both independently

### Exit Criteria

- foveated estimation is functional with both OFA and compute-shader backends
- peripheral vectors are correctly rescaled; no visible motion-magnitude discontinuity at the fovea/periphery boundary
- total estimation time (downsample + dual flow + rescale) is measurably lower than full-resolution single-pass flow
- foveated estimation disables gracefully when eye tracking is unavailable
- fovea size and downsample ratio are adjustable at runtime through registry settings
- diagnostics can visualize the fovea region and report per-region flow timing

### Risks / Blockers

- downsample cost may exceed flow savings at small peripheral areas or low downsample ratios
- fovea/periphery boundary may produce visible seam artifacts in synthesized output if regions overlap poorly
- eye-tracking latency or jitter may cause the fovea to lag behind actual gaze, reducing quality in the region the user is currently looking at
- some Pimax headset models may not support `XR_EXT_eye_gaze_interaction`

## Phase 4 - Synthesis And Hole Filling

### Objective

Generate submission-ready intermediate frames for arbitrary fractional display times.

### Main Implementation Areas

- implement bi-directional interpolation strategy
- resolve occlusions with depth and confidence inputs
- add a deterministic hole-filling stage
- produce runtime-owned synthesized output images ready for scheduler consumption
- ensure synthesized Vulkan output can be handed back to the current headset submission backend regardless of input API
- synthesis consumes the common motion-vector interface and must not depend on vector source (Application SpaceWarp, OFA, or compute-shader)

### Exit Criteria

- synthesized frames can be generated from runtime history
- output quality is stable enough for headset validation
- synthesis output is independent from app swapchain lifetime

### Risks / Blockers

- visual artifacts may expose weaknesses in earlier depth or vector stages
- synthesis latency may exceed the usable scheduling budget

## Phase 5 - Runtime Scheduler At Headset Cadence

### Objective

Choose the correct output path at headset cadence even when the app cadence is lower or uneven.

### Main Implementation Areas

- compare app frame availability against headset timing targets
- select between fresh real frame or synthesized frame (if neither is ready, pass the most recent real frame and rely on the headset's LSR for rotational correction)
- redefine the `xrWaitFrame` contract once synthetic cadence is active
- integrate scheduling decisions into the runtime submission path before `pvr_endFrame`
- preserve valid OpenXR and PVR timing semantics

### Exit Criteria

- runtime output cadence tracks headset cadence
- scheduler decisions are observable and repeatable
- app frame drops do not automatically collapse runtime output cadence
- the predicted display times exposed through `xrWaitFrame` are intentionally defined and consistent with the scheduler model

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
- validate compute-shader fallback
- validate foveated estimation quality and performance across different fovea sizes and downsample ratios
- add operational toggles for baseline, capture-only, synthesis, and full scheduler modes
- document repeatable test and rollback procedures

### Exit Criteria

- the runtime can fall back gracefully when synthesis misses deadline or inputs are invalid
- compute-shader fallback produces acceptable quality on non-OFA hardware
- foveated estimation produces measurable performance improvement without perceptible quality loss in the periphery
- performance and quality are measurable on target hardware
- engineers have a repeatable install, test, and triage loop

### Risks / Blockers

- target-game behavior may expose assumptions that do not appear in synthetic tests
- fallback rules may be too slow or too visually disruptive without explicit tuning
- compute-shader flow quality may require per-game tuning on lower-end hardware

## Phase 7 - Companion App Controls And Debug Overlay

### Objective

Add motion-smoothing controls to the existing companion app and implement a runtime debug overlay so smoothing performance can be monitored in real time during headset use.

### Main Implementation Areas

#### 7A - Companion App GUI Extensions

- add a new motion-smoothing settings panel in the companion app
- implement the following controls, persisted through the existing registry mechanism:
  - master enable/disable toggle for motion smoothing
  - estimation backend selector (Auto / OFA / Compute-Shader) — Auto uses OFA when available, compute-shader otherwise
  - foveated estimation toggle (on/off) with sliders for fovea size and peripheral downsample ratio
  - debug overlay enable/disable toggle
  - debug overlay detail level (minimal / verbose)
- add a restore-defaults action that resets all smoothing settings
- ensure new settings follow the existing pattern: `MainForm.WriteSetting` for persistence, `LoadSettings` for hydration

#### 7B - Runtime Debug Overlay

- implement a lightweight in-headset overlay rendered into the compositor output before `pvr_endFrame`
- the overlay displays:
  - current motion-vector source per frame (App / OFA / Compute-Shader / None)
  - synthesis latency (ms) — time from frame intercepted to synthesized image sent to headset
  - app cadence (FPS) vs. headset cadence (FPS) & percent of target fps achieved
  - frame history ring depth and recent drop count
  - fovea region visualization: an optional wireframe rectangle showing where the fovea box is positioned on each eye
  - estimation backend in use and whether foveated estimation is active
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
3. Validate and normalize depth and motion-estimation inputs.
4. Advertise `XR_FB_space_warp` and implement app-provided vector ingestion. Add OFA estimation as the primary fallback. Add compute-shader optical flow as the universal fallback. Define the common vector interface.
5. Add foveated motion-vector estimation to the runtime estimation paths.
6. Add synthesis and hole filling in Vulkan (consuming the common vector interface).
7. Bridge synthesized Vulkan output back into headset submission.
8. Only after that, enable aggressive cadence conversion and production tuning.
9. Add companion-app controls and debug overlay as a final integration and polish phase.

This order is mandatory.

- The scheduler should not be treated as the first major milestone, because it depends on reliable ownership and valid synthesis inputs.
- Application SpaceWarp support is addressed alongside OFA and the compute-shader fallback (not after) because the common vector interface must be designed to accommodate all three sources from the start.
- Foveated estimation is added immediately after the estimation backends because it is a performance multiplier for the compute-shader path especially.
- The companion-app and overlay work comes last because it depends on stable runtime settings and a functioning pipeline to observe.

## Validation Path

For every phase, verify:

- no design step assumes the abandoned API-layer architecture
- the implementation path maps back to actual runtime entrypoints in `pimax-openxr`
- new runtime behavior remains observable through logs and traces
- the repo can still be reasoned about without depending on uninitialized submodule contents
