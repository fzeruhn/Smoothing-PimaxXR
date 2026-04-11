# Runtime Motion-Smoothing Architecture

Note: the root-level `AGENTS.md`, `ARCHITECTURE.md`, and `ROADMAP.md` describe the abandoned API-layer direction. For this fork, the files under `docs/` are the source of truth.

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

## Target Direction

### High-Level Pipeline

1. The app renders into runtime-visible swapchains using D3D11, D3D12, or Vulkan.
2. At `xrEndFrame`, the runtime captures:
   - color
   - depth when available
   - render pose / view state
   - timestamps and frame identifiers
3. The runtime translates the incoming API-specific resources into Vulkan-backed smoothing resources, then copies or aliases them into runtime-owned history resources.
4. Motion estimation derives vectors between adjacent history frames.
5. Pose reprojection removes head motion from the estimation path and provides a late-stage fallback transform.
6. Frame synthesis generates an intermediate frame for the target display time.
7. A submission scheduler decides whether to submit:
   - a fresh real frame
   - a synthesized frame
   - a late reprojected fallback frame
8. The runtime packages the chosen result into the compositor submission path and completes `pvr_endFrame`.

## Subsystems

### Frame Capture And History

Responsibilities:

- capture the app-submitted frame at `xrEndFrame`
- retain color, depth, pose, and timestamps in runtime-owned history slots
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

### Motion-Vector Generation

Responsibilities:

- compute motion vectors from adjacent runtime-owned frames
- remove head-motion bias before or during estimation
- expose confidence and validity information for downstream synthesis

The smoothing pipeline must ultimately accept D3D11, D3D12, and Vulkan app input. The intended architecture is that all of those inputs normalize into Vulkan-backed resources, and motion estimation runs there. OFA integration is one reason for that choice, but the more important point is that the smoothing stack should have one GPU execution model instead of three.

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
- decide whether the next output should be a real frame, a synthesized frame, or a fallback reprojection
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

## Constraints And Invariants

- The final compositor submission path remains inside the runtime.
- `frame.cpp` stays the orchestration point for pacing and submission decisions, not the home for every smoothing algorithm.
- Runtime-owned history is required. App-owned swapchain images are not a safe long-term history source.
- D3D11, D3D12, and Vulkan app input are all in scope. The architecture must not assume a Vulkan-only application world.
- The architecture must tolerate missing depth by degrading to lower-quality fallback behavior rather than failing outright.
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

## Completion Path

The architecture should be implemented in this order:

1. Establish history ownership and capture boundaries.
2. Define the input normalization path that converts D3D11, D3D12, and Vulkan input into Vulkan-backed smoothing resources.
3. Define pooled allocation, VRAM budgeting, and overload policy for Vulkan-backed history.
4. Normalize depth and timestamp handling.
5. Add motion estimation and reprojection in Vulkan.
6. Add synthesis and hole filling in Vulkan.
7. Define how synthesized Vulkan output is handed back to the headset submission backend.
8. Define the `xrWaitFrame` pacing contract and add scheduler decisions at headset cadence.
9. Tune performance, queue strategy, fallback behavior, and diagnostics.

See `docs/ROADMAP.md` for the execution phases.
