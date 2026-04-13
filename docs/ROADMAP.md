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

## Phase 3 - Motion Estimation Integration

### Objective

Integrate NVIDIA OFA against runtime-owned frames.

### Main Implementation Areas

- define the Vulkan motion-estimation path
- land the non-Vulkan to Vulkan normalization required to feed that estimator
- define the queue strategy for motion-estimation work
- remove or compensate for head motion before vector estimation
- produce vectors, validity, and confidence data for downstream use
- determine whether stereo uses dual estimation or adapted vectors

### Exit Criteria

- adjacent history frames produce usable motion vectors
- motion-estimation latency is measurable and stable
- compute execution strategy is defined for both dedicated-queue and shared-queue cases
- vector output is suitable for synthesis input

### Risks / Blockers

- Vulkan interop may need redesign because of current timeline-semaphore assumptions
- cross-API translation may become the real bottleneck instead of estimation itself
- a dedicated compute queue may not be available or may not be safely usable in the bound runtime device path
- stereo consistency may require extra work beyond a simple single-eye estimate

## Phase 4 - Synthesis And Hole Filling

### Objective

Generate submission-ready intermediate frames for arbitrary fractional display times.

### Main Implementation Areas

- implement bi-directional interpolation strategy
- resolve occlusions with depth and confidence inputs
- add a deterministic hole-filling stage
- produce runtime-owned synthesized output images ready for scheduler consumption
- ensure synthesized Vulkan output can be handed back to the current headset submission backend regardless of input API

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
- select between fresh real frame, synthesized frame, and fallback reprojection
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

- add late-stage reprojection fallback when synthesis is unavailable
- tune latency, queue depth, and history policy
- validate in target games, especially Vulkan titles
- add operational toggles for baseline, capture-only, synthesis, and full scheduler modes
- document repeatable test and rollback procedures

### Exit Criteria

- the runtime can fall back gracefully when synthesis misses deadline or inputs are invalid
- performance and quality are measurable on target hardware
- engineers have a repeatable install, test, and triage loop

### Risks / Blockers

- target-game behavior may expose assumptions that do not appear in synthetic tests
- fallback rules may be too slow or too visually disruptive without explicit tuning

## Priority Order

Work in this order:

1. Stabilize ownership, capture points, and timing in the current runtime.
2. Define and validate normalization of D3D11, D3D12, and Vulkan input into Vulkan-backed smoothing resources.
3. Validate and normalize depth and motion-estimation inputs.
4. Add synthesis and hole filling in Vulkan.
5. Bridge synthesized Vulkan output back into headset submission.
6. Only after that, enable aggressive cadence conversion and production tuning.

This order is mandatory. The scheduler should not be treated as the first major milestone, because it depends on reliable ownership and valid synthesis inputs.

## Validation Path

For every phase, verify:

- no design step assumes the abandoned API-layer architecture
- the implementation path maps back to actual runtime entrypoints in `pimax-openxr`
- new runtime behavior remains observable through logs and traces
- the repo can still be reasoned about without depending on uninitialized submodule contents
