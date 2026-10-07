# MapSpike — issue #32

A throwaway RealityKit view of Neo's real memory (48,950 points at UMAP 3-D positions), built to answer two
questions before the Map page (#34) is designed: the frame rate with instancing + bloom + edges, and whether a
single instance can be picked.

```
MapSpike -mapData <dir with neo.xyz (N×3 Float32), neo.kind (N×UInt8), neo.titles.json> [-edges 500] [-orbit 20]
```

## Measured 2026-10-07 · Apple M5 Max · macOS 27.0.1 · Xcode 27.0 · Release

| | result |
|---|---|
| points | 48,950 as instanced spheres, `MeshInstancesComponent` in 4,096-instance chunks (17 entities), built in 0.13 s |
| frame rate, 20 s orbit, bloom on, 500 edge lines | **59 fps mean (min 55, max 60)**; an earlier run with brighter materials: 53 mean (min 39) |
| memory | 187–211 MB RSS |
| `Scene.pixelCast` on instanced meshes | **never hits an instance**: 0 of 5 casts through the exact projected pixel of a known point (it returned nil, or the edge-line entity) |
| CPU pick (project all 48,950 points with `content.project`, nearest on screen) | **5 of 5 correct, 21–22 ms per pick**, 0.0 px off |
| zoom | `realityViewCameraControls(.orbit)` has no dolly; the scroll wheel scales the root instead (0.5×–12×) |
| bloom | `BloomComponent` + `BloomOptionsComponent` (macOS 27) on the root entity; emissive materials above the threshold glow, the rest must stay below it or every colour blows out to white |

## Verdict

**RealityKit.** Both gates pass: ≥ 30 fps with margin, and picking works through the CPU path (which also gives
"nearest point within 12 px", better than a ray for 3-pt spheres). `pixelCast` is not usable for instanced
meshes; do not plan on it.

What the spike does not settle (for #34): the look. Dim emissive dots read as grey, not as neurons; the
default virtual camera frames the whole bounding box so the map opens small; outliers stretch the edges. #34
owns the camera, fog, per-kind brightness, and the glow design.
