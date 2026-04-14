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
4. Motion-vector sourcing follows a dual-path model:
   - **Application SpaceWarp path:** If the app provided motion vectors via `XR_FB_space_warp`, the runtime ingests them directly. No OFA estimation or pose-reprojection is needed because the app vectors already represent true scene motion. This path saves ~1–2.5 ms of GPU time per frame and eliminates estimation artifacts around UI elements, particle effects, and transparent surfaces.
   - **OFA estimation path:** If the app did not provide vectors, the runtime runs motion estimation (NVIDIA OFA) against adjacent history frames and removes head-motion bias via pose reprojection. This is the fallback for the majority of PCVR titles.
   - Both paths produce vectors in a common internal format and feed into the same downstream synthesis pipeline.
5. Pose reprojection removes head motion from the estimation path so motion vectors reflect scene motion only. (Skipped when using Application SpaceWarp vectors, which already represent scene motion.)
6. Frame synthesis generates an intermediate frame for the target display time.
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

Motion vectors can arrive from three different sources. The runtime must support all three and select between them on every frame.

#### Application SpaceWarp (`XR_FB_space_warp`)

When the application supports the `XR_FB_space_warp` extension:

1. During session creation, the application queries the runtime for `XR_FB_space_warp` support. The runtime advertises the extension.
2. The application creates dedicated swapchains for motion vectors (typically `R16G16B16A16_SFLOAT`) and depth.
3. At `xrEndFrame`, the application attaches an `XrCompositionLayerSpaceWarpInfoFB` struct to each projection layer. This struct references the motion-vector image, the depth image, and associated near/far plane metadata.
4. The runtime detects the struct in the composition-layer chain, ingests the app-provided vectors, and skips runtime estimation entirely for that frame.

App-provided vectors are superior in every measurable metric:

- **No GPU overhead for estimation:** OFA costs ~1–2.5 ms per frame. Application SpaceWarp costs the runtime zero estimation time because modern engines already compute perfect motion vectors for TAA/DLSS/FSR and exporting them is essentially free.
- **No estimation artifacts:** OFA guesses where things moved by comparing pixels. It cannot distinguish UI overlays from 3D geometry, and it struggles with transparency, particles, and specular highlights. App vectors know exactly what moved and by how much.
- **Perfect per-object motion:** Engine vectors capture animation, physics, and camera-relative motion with sub-pixel precision. OFA can only approximate these from rasterized output.

#### OFA Estimation (Primary Runtime Fallback)

When the application does not provide motion vectors and the GPU has NVIDIA OFA hardware:

- Runs NVIDIA OFA against adjacent Vulkan-backed history frames
- Removes head-motion bias via pose reprojection before estimation
- Produces vectors with confidence and validity metadata
- Subject to foveated estimation (see below)

This path is preferred for NVIDIA GPUs that have dedicated optical-flow accelerator silicon.

#### Compute-Shader Optical Flow (Universal Fallback)

When the application does not provide motion vectors and OFA hardware is unavailable (AMD GPUs, Intel GPUs, older NVIDIA GPUs without OFA):

- Runs a Vulkan compute-shader optical-flow implementation against adjacent history frames
- Uses the same pose-reprojection head-motion removal as the OFA path
- Produces vectors in the same common format with confidence metadata
- Subject to foveated estimation (see below)
- Expected to be slower than OFA but functionally equivalent

This path ensures motion smoothing is available on all Vulkan-capable GPUs, not just NVIDIA hardware with dedicated optical-flow silicon. The compute-shader implementation should use a block-matching or hierarchical Lucas-Kanade approach suitable for real-time VR workloads.

#### Common Vector Interface

Both app-provided and runtime-estimated paths (OFA and compute-shader) must produce motion vectors in a single internal representation before reaching synthesis (though maybe with different resolutions). The downstream pipeline (synthesis, hole filling, scheduling) must not need to know whether the vectors came from the app, from OFA, or from the compute-shader fallback. The common interface includes:

- per-pixel motion vectors in a defined coordinate space and format
- per-pixel confidence or validity when available (OFA provides this inherently; compute-shader flow produces its own confidence metric; app vectors are assumed high-confidence)
- associated depth for occlusion reasoning
- source tag for diagnostics (app-provided vs. OFA-estimated vs. compute-shader-estimated)

### Foveated Motion-Vector Estimation

Foveated estimation is a cross-cutting optimization applied to both runtime estimation backends (OFA and compute-shader). It is not used when the app provides motion vectors via Application SpaceWarp, because those vectors are already computed by the engine at full precision.

#### Rationale

Running optical flow at full native resolution for VR frames (often 4K+ per eye) is expensive. Foveated estimation exploits the fact that the user's high-acuity vision only covers a small area of the display. The rest of the field of view tolerates lower-fidelity motion vectors without perceptible quality loss.

#### Pipeline

1. **Gaze acquisition:** At `xrEndFrame`, the runtime queries `XR_EXT_eye_gaze_interaction` to obtain the current gaze point as a 2D screen coordinate per eye. When eye tracking is unavailable, the fovea defaults to the optical center of each eye's view.

2. **Region split:** The frame is divided into discrete regions of interest:
   - **Fovea (inner region):** A bounding box centered on the gaze coordinate, kept at 100% native resolution. Size is tunable but typically covers 10–15° of visual angle.
   - **Periphery (outer region):** Everything outside the fovea box.

3. **Peripheral downsample:** The periphery is downsampled to a fraction of native resolution (e.g. 25% or 10% area) using a fast Vulkan hardware blit with bilinear sampling. This step must be cheaper than the flow savings it produces; a single `vkCmdBlitImage` or equivalent compute dispatch is sufficient.

4. **Dual optical-flow dispatch:** The estimation backend (OFA or compute-shader) processes two inputs independently:
   - The full-resolution fovea region (small pixel count, high quality).
   - The downsampled periphery (large spatial coverage, low pixel count).
   Because total pixel count is a fraction of the original frame, estimation time drops proportionally.

5. **Vector rescale and composite:** The synthesis shader consults the pixel's screen position:
   - Pixels inside the fovea box read from the high-resolution motion vectors directly.
   - Pixels outside the fovea box read from the low-resolution peripheral vectors, with the vector magnitude multiplied by the downsample ratio (e.g. 4× if downsampled by 4×) to restore correct screen-space motion magnitude.

#### Critical Invariant

Peripheral vectors produced from downsampled input are physically smaller than real screen-space motion. The rescale step is mandatory. Without it, synthesized peripheral content will move at the wrong speed, producing visible tearing and judder at the fovea/periphery boundary.

#### Configuration

Foveated estimation parameters (fovea size, peripheral downsample ratio, fallback gaze center) are exposed as runtime settings and should be controllable through the companion app.

### Motion Estimation (OFA And Compute-Shader Path Details)

Responsibilities (when Application SpaceWarp vectors are not available):

- select between OFA hardware acceleration and compute-shader fallback based on device capability detection at session initialization
- compute motion vectors from adjacent runtime-owned frames
- apply foveated estimation: split into fovea and periphery, downsample periphery, run flow on both, rescale peripheral vectors
- remove head-motion bias before or during estimation
- expose confidence and validity information for downstream synthesis

The smoothing pipeline must ultimately accept D3D11, D3D12, and Vulkan app input. The intended architecture is that all of those inputs normalize into Vulkan-backed resources, and motion estimation runs there. OFA integration is one reason for that choice, but the more important point is that the smoothing stack should have one GPU execution model instead of three.

The compute-shader fallback must produce output in the same format as OFA so that downstream subsystems are backend-agnostic. Backend selection is a session-initialization decision, not a per-frame decision.

### Stereo Adaptation

Responsibilities:

- either estimate both eyes directly or derive the second eye from the first
- preserve binocular consistency well enough for headset submission

This stage should stay isolated from the scheduler so it can be changed without reworking frame pacing.

### Frame Synthesis And Hole Filling

Responsibilities:

- synthesize an intermediate image for an arbitrary fractional display time
- use depth and vector confidence to resolve occlusion conflicts
- fill disocclusion holes with a deterministic post-process stage

This stage produces runtime-owned submission-ready images rather than patching app-owned swapchain images in place.

### Runtime Pacing And Scheduling

Responsibilities:

- observe app cadence and headset cadence
- decide whether the next output should be a real frame or a synthesized frame (when neither is available, pass the most recent real frame and rely on the headset's LSR for rotational correction)
- preserve valid OpenXR and PVR frame ordering
- avoid stalling the app thread where possible
- define what `xrWaitFrame` tells the application once runtime cadence diverges from direct headset cadence
- keep application prediction, simulation timing, and headset submission timing internally coherent

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
  - master enable/disable toggle for motion smoothing
  - estimation backend selection (OFA / compute-shader / auto-detect)
  - foveated estimation toggle with adjustable fovea size and peripheral downsample ratio
  - debug overlay enable/disable
- implement a runtime debug overlay rendered into the compositor output:
  - current motion-vector source (app-provided / OFA / compute-shader)
  - synthesis latency per frame (ms)
  - app cadence vs. headset cadence
  - frame history depth and drop counts
  - fovea region visualization (optional wireframe box showing where foveated estimation is active)
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
- The architecture must tolerate missing depth by degrading to lower-quality fallback behavior rather than failing outright.
- Motion-vector estimation must not hard-depend on NVIDIA OFA. A Vulkan compute-shader optical-flow fallback must exist for non-OFA hardware (AMD, Intel, older NVIDIA).
- Foveated motion-vector estimation is the default for all runtime-estimated paths. Peripheral vectors must be rescaled by the downsample ratio before synthesis.
- When eye tracking is unavailable, foveated estimation uses the optical center of each eye's view as the fovea center rather than disabling foveation entirely.
- The scheduler must preserve valid timing semantics even when synthesis misses its deadline.
- The smoothing pipeline should have one execution backend: Vulkan.
- The runtime already translates multiple app APIs into a common submission backend. Motion smoothing should reuse or extend that translation model so all three input APIs converge into Vulkan for smoothing, then return to the headset submission path.
- Steady-state smoothing operation must not depend on unbounded Vulkan image allocation. History and intermediate resources need a pooled lifetime model and an explicit VRAM budget.
- `xrWaitFrame` is part of the scheduling contract, not just an input to it. Once runtime cadence diverges from direct headset cadence, predicted display times exposed to the app must be defined intentionally.

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
- Define the mapping from app-provided vector format into the common internal motion-vector representation used by synthesis
- Define how app-provided depth from the SpaceWarp struct relates to the depth normalization policy from Gate D
- Define validation and sanity-checking for app-provided vectors (range checks, NaN handling, coverage thresholds) so malformed input degrades to OFA fallback rather than producing corrupt synthesis output

### Gate H: Estimation Backend Selection And Capability Detection

- Define how the runtime detects OFA hardware availability at session initialization (e.g. Vulkan extension query, NVAPI, or CUDA capability check)
- Define fallback order: Application SpaceWarp → OFA → compute-shader
- Define whether backend selection is a session-lifetime decision or can change per-frame
- Recommended: backend is locked at session init; per-frame switching adds complexity without clear benefit

### Gate I: Foveated Estimation Parameters And Gaze Fallback

- Define fovea bounding-box size in pixels or degrees of visual angle
- Define peripheral downsample ratio (e.g. 4× area reduction = 2× linear reduction)
- Define gaze fallback center when `XR_EXT_eye_gaze_interaction` is unavailable
- Define the vector rescale factor and verify it matches the downsample ratio exactly
- Define whether foveated estimation can be disabled entirely via companion-app toggle for debugging

## Completion Path

The architecture should be implemented in this order:

1. Establish history ownership and capture boundaries.
2. Define the input normalization path that converts D3D11, D3D12, and Vulkan input into Vulkan-backed smoothing resources.
3. Define pooled allocation, VRAM budgeting, and overload policy for Vulkan-backed history.
4. Normalize depth and timestamp handling.
5. Advertise `XR_FB_space_warp` and implement detection and ingestion of app-provided motion vectors at `xrEndFrame`.
6. Add OFA-based motion estimation and pose reprojection in Vulkan for apps that do not provide vectors. Add a Vulkan compute-shader optical-flow fallback for GPUs without OFA.
7. Add foveated motion-vector estimation: gaze acquisition, region split, peripheral downsample, dual-dispatch flow, and vector rescale.
8. Define the common motion-vector interface that Application SpaceWarp, OFA, and compute-shader paths all feed into.
9. Add synthesis and hole filling in Vulkan (consuming the common vector interface).
10. Define how synthesized Vulkan output is handed back to the headset submission backend.
11. Define the `xrWaitFrame` pacing contract and add scheduler decisions at headset cadence.
12. Tune performance, queue strategy, fallback behavior, and diagnostics.
13. Add motion-smoothing controls to the companion app and implement a runtime debug overlay for performance monitoring.

See `docs/ROADMAP.md` for the execution phases.
