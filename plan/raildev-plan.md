# Raildev — Game Design & Technical Architecture Plan

**Raildev** is a 2D/2.5D railway network management and economic simulation game inspired by *Railway Empire*, built with **SDL3**. It focuses purely on strategic map-scale logistics, authentic geography, track & signal engineering, trade, city growth, and scenario-based challenges—without AI competitors or 3D close-up train detail.

---

## 1. Feature Review, Clarifications & Improvements

Below is a review of the core requirements with concrete design clarifications to keep the scope focused, fun, and technically cohesive:

### 1.1 Tech & Visual Direction (SDL3, Map-View, Mountains)
- **Pure Map-View (No 3D Detail Zoom):** All gameplay takes place on a continuous, smoothly pannable and zoomable cartographic map—from a continental overview of Europe down to city junctions and station throats. Trains are represented as crisp, readable map tokens/icons (e.g., locomotive + short carriage tail or cargo badge) following track splines.
- **2.5D Mountain & Terrain Modeling:** Instead of 3D meshes, mountains can be rendered convincingly in 2D/2.5D using:
  - **Hypsometric tinting + shaded relief (hillshading):** Precomputed or shader-generated directional sunlight shading from a real-world Europe elevation heightmap (DEM).
  - **Topographic contour lines & ridgeline hatches:** Subtle contour lines at elevation intervals and stylized cartographic ridge/peak markers at high zoom-out.
  - **Gameplay integration:** Terrain slope directly dictates **track grade (%)**, construction cost, locomotive speed penalties, and automatic **bridge** (rivers/valleys) or **tunnel** (mountain ridges) generation.
- **Recommended SDL3 Stack:**
  - **Language:** C++20 (clean value semantics, fast simulation loop) + CMake.
  - **Core:** `SDL3` (windowing, input, high-DPI, `SDL_Renderer` or `SDL_GPU` for custom hillshading/map shaders).
  - **Text & Assets:** `SDL3_ttf` for crisp scalable map labels, `SDL3_image` (or `stb_image`) for heightmaps/icons.
  - **UI:** `Dear ImGui` (with SDL3 backend) for dense, responsive management panels (finances, tech tree, train schedules, city demand, overlays), styled with a clean vintage-atlas / modern-strategy theme.

### 1.2 No Competition — How Challenge & Tension Work
Removing AI competitors eliminates frustrating track-sniping and artificial rubber-banding, shifting the game into a **pure logistics & engineering challenge** (similar to *Mini Metro*, *Factorio*-style throughput, or *OpenTTD* solo challenges):
- **Geography & Capital Constraints:** Mountain passes (Alps, Pyrenees, Carpathians) and major rivers (Rhine, Danube, English Channel ferries/tunnels) are expensive to cross early on.
- **Time-Bound & Growth Challenges:** Scenarios grade players on speed, network efficiency, city population targets, and financial health.
- **Network Bottlenecks:** As traffic scales, single-track lines jam unless upgraded with passing sidings, double-tracks, and proper block signaling.

### 1.3 Track System, Signals & Stations (Clarified Mechanics)
- **Spline-Based Freeform Track (Not a Grid):** Tracks are built as smooth connected curves (cubic Bezier / circular-arc + straight segments) between nodes, enforcing minimum curve radius and maximum grade limits.
- **Double-Track & Auto-Signal Tools:**
  - A **Parallel / Double-Track toggle** lays two tracks side-by-side in one drag, automatically creating neat parallel curves.
  - **Auto-Signal placement** lets players populate a track segment with evenly spaced directional signals in one click—essential on a continental Europe map.
- **Signal Types (Simple yet Deep):**
  1. **Block Signal:** Divides track into occupancy blocks; a train stops if the next block is occupied.
  2. **Directional (One-Way) Signal:** Enforces traffic direction on double-track mainlines.
  3. **Chain / Entry Signal (Optional/Unlockable):** Prevents a train from entering a junction unless it can also exit it, eliminating gridlock at busy station throats.
- **Growable Train Stations:**
  - Stations start as a **1–2 platform Rural/Town Halt** and can be upgraded in-place to **4, 6, or 8+ platforms** as traffic grows.
  - **Station Modules (Map-level):**
    - *Maintenance Shed:* Restores locomotive condition and prevents breakdowns.
    - *Warehouse / Freight Yard:* Enables **hub-and-spoke cargo transfers** between lines (vital for a huge Europe map).
    - *Signal Box / Dispatcher:* Increases station throat throughput and platform routing flexibility.

### 1.4 Economy, Trade & City Growth
- **3-Tier Supply Chain:**
  1. **Rural Resources:** Farms (grain, livestock), Forests (timber), Mines (coal, iron ore), Quarries, Oil Wells.
  2. **City Industries:** Sawmills, Bakeries, Breweries, Steel Mills, Textile Factories, Refineries. Industries occupy finite slots in cities and can be upgraded or built as cities grow.
  3. **City Consumer Demand:** Cities consume goods based on population. Meeting a threshold (e.g., 60%+ fulfillment across core goods) triggers **City Growth** (Village → Town → City → Metropolis), unlocking more industry slots, higher demand, and more passengers/mail.
- **Demand-Driven Freight:** Cargo is only loaded onto a train if a valid destination (city or warehouse) along that train's route actually demands it—preventing pointless freight loops.

### 1.5 Tech Tree & Era Progression
- Spanning roughly **1830 to 1930** (5–6 eras, e.g., Early Steam, Iron & Coal, Steel & Express, Electrification, Modern Heavy Rail).
- **Research Currency:** Earned via **Innovation Points** generated over time + boosted by hitting trade milestones or allocating a % of profits to R&D (giving players active strategic agency).
- **Branches:**
  - *Locomotives:* Speed, tractive effort (hill-climbing power), reliability, operating cost.
  - *Infrastructure:* Iron/steel bridges, long tunnels, higher-speed trackbed, double-track discounts, electric/block signaling.
  - *Commerce & Operations:* Larger warehouses, express mail/passenger bonuses, cheaper loans, faster station turnaround.

### 1.6 Rating & Scoring System
Each scenario or challenge evaluates the player across weighted dimensions:
- **Primary Objectives:** e.g., *"Connect Paris to Lyon"*, *"Grow Milan to 120,000 inhabitants"*, *"Deliver 500t of Steel to Berlin"*.
- **Time Bonus:** Faster completion yields higher score multipliers.
- **Economic & Network Health:** Operating profit margin, debt-free status, average cargo fulfillment across connected cities.
- **Final Grade:** Medal/Rank (e.g., *Bronze / Silver / Gold / Master Railwayman*) with a post-scenario summary breakdown.

---

## 2. Europe Map & Spatial Architecture

### 2.1 Scale & Projection
- **Map Size:** High-resolution logical world (e.g., `4096 × 4096` or `8192 × 8192` km-equivalent coordinate space covering Western, Central, Southern, and parts of Northern/Eastern Europe).
- **Geography:** Built from real-world European elevation data (cropped & projected cleanly, e.g., Albers Equal-Area or Equirectangular adjusted for Europe's latitude).
- **Major Landmarks:** Alps, Pyrenees, Apennines, Carpathians, Scottish Highlands; Rhine, Danube, Seine, Po, Thames, Elbe; English Channel (ferry port or late-game Channel Tunnel challenge).

### 2.2 Rendering & Performance at Scale
- **Chunked Terrain Tiles:** Split the Europe map into `256×256` or `512×512` chunks with mipmapped LODs so zooming out to see all of Europe stays locked at 60+ FPS.
- **Spatial Indexing:** Use a uniform grid or quadtree for tracks, signals, stations, and cities so hit-testing (hover/click), culling, and station catchment queries are $O(1)$ / $O(\log N)$.
- **Map Overlays (Toggleable):**
  - Topographic / Grade heatmap (green flatlands → red steep mountain grades)
  - Supply & Demand flow arrows
  - Signal Block & Track Occupancy visualizer (color-coded blocks)
  - Station Catchment radius

---

## 3. Core Simulation Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     SDL3 Application                     │
│  Input (Pan/Zoom/Build) │ Renderer (Map/Splines/ImGui)   │
└────────────┬────────────────────────────┬────────────────┘
             │ Commands                   │ Read-only Snapshot / State
┌────────────▼────────────────────────────▼────────────────┐
│              Deterministic Simulation Core               │
│  Fixed-timestep tick (e.g., 10–20 Hz, 1x/2x/4x speed)    │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐  │
│  │ Track Graph  │ │ Train &      │ │ Economy & City   │  │
│  │ & Signals    │ │ Pathfinding  │ │ Growth Engine    │  │
│  └──────────────┘ └──────────────┘ └──────────────────┘  │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐  │
│  │ Finances &   │ │ Tech Tree    │ │ Scenario &       │  │
│  │ Loans        │ │ Progression  │ │ Rating Evaluator │  │
│  └──────────────┘ └──────────────┘ └──────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

### Key Data Models
- **Track Graph:** `TrackNode` (x, y, elevation, switch/junction connections) and `TrackEdge` (spline control points, length, max grade, speed limit, bridge/tunnel flag, list of `Signal`s, divided into `TrackBlock`s).
- **Trains & Lines:** `TrainLine` (ordered list of `Station` stops + cargo rules) and `Train` (assigned locomotive type, wagons, current `TrackBlock`/position, speed, acceleration/grade physics, cargo manifest, maintenance condition).
- **Economy:** `Settlement` (name, population, tier, demand map, industry slots, happiness/fulfillment), `ResourceNode` (type, output rate), `Warehouse` (stored goods per destination).

---

## 4. Phased Development Roadmap

### Phase 0: Project Setup & Core Skeleton
- Initialize CMake + C++20 project with `SDL3`, `SDL3_ttf`, and `Dear ImGui`.
- Implement fixed-timestep game loop (pause, 1x, 2x, 4x speed) decoupled from render FPS.
- Implement smooth camera pan/zoom (mouse drag, scroll-to-cursor zoom, keyboard shortcuts).

### Phase 1: Europe Map & 2.5D Mountain Rendering
- Prepare Europe heightmap + river/coastline mask + initial city/resource dataset (JSON/binary).
- Implement chunked terrain renderer with hypsometric coloring, contour lines, and directional hillshading for mountains.
- Render city markers, names, and population badges scaled cleanly by zoom level.

### Phase 2: Track Building, Double-Tracking & Signals
- Implement spline track placement tool with real-time preview: cost breakdown, grade %, bridge/tunnel detection.
- Add **Double-Track (parallel)** mode and **Junction/Switch** snapping.
- Implement **Signals** (Block, Directional, Auto-signal along segment) and the **Track Block** graph division.

### Phase 3: Train Physics, Pathfinding & Dispatching
- Implement A* pathfinding over the directed track-and-signal graph (respecting one-way signals and station platform routing).
- Implement train movement along splines, including **grade-based acceleration/deceleration**, breakdown/maintenance state, and block-signal stopping.
- Build Train Line & Schedule UI (assign stops, buy locomotives, view route on map).

### Phase 4: Economy, Trade & City Growth
- Implement cargo generation at rural resources and city industries.
- Implement demand-driven loading/unloading at stations and **Warehouse** hub-and-spoke transfers.
- Implement **City Growth** simulation (fulfillment tracking → population growth → new industry slots & higher passenger/mail output).

### Phase 5: Finances, Tech Tree & Station Upgrades
- Implement revenue calculation (distance, speed bonus, cargo value), track/train upkeep, and **Loans/Bonds** system.
- Implement quarterly/annual financial ledger UI.
- Build **Tech Tree** UI and progression (locomotives, infrastructure, commerce) with era unlocks.
- Add in-place **Station Upgrades** (platforms 1→8, Maintenance Shed, Warehouse, Signal Box).

### Phase 6: Scenarios, Challenges & Rating System
- Define scenario format (starting year, region bounds/full Europe, starting capital, primary/secondary objectives, time limits, medal thresholds).
- Create **3–5 handcrafted Europe Scenarios** (e.g., *1835: Industrial Heartlands (Rhine-Ruhr)*, *1855: Crossing the Alps*, *1875: Trans-European Express*, plus *Full Europe Freeplay*).
- Implement live objective tracker and end-of-scenario **Rating & Score Summary**.
- Add binary/JSON **Save & Load** system.

### Phase 7: Polish, Overlays & Audio
- Add map overlays (Grade/Slope, Supply/Demand, Signal Blocks, Catchment).
- Add subtle procedural/sample sound effects (steam whistle on dispatch, coin clink, construction, ambient map audio).
- Performance profiling on dense late-game Europe networks (hundreds of trains).

---

## 5. Recommended Directory Structure

```text
raildev/
├── CMakeLists.txt
├── plan/
│   └── raildev-plan.md
├── assets/
│   ├── maps/           # Europe heightmap, coastlines, city/resource data
│   ├── fonts/
│   └── icons/          # Map tokens, UI & cargo icons
├── data/
│   ├── locomotives.json
│   ├── goods.json
│   ├── tech_tree.json
│   └── scenarios/      # Europe campaign & freeplay definitions
├── src/
│   ├── main.cpp
│   ├── core/           # Fixed-timestep loop, camera, save/load
│   ├── map/            # Chunked terrain, hillshading, spatial index
│   ├── track/          # Splines, double-track, bridges/tunnels, signals, blocks
│   ├── sim/            # Trains, pathfinding, economy, city growth, finances, tech
│   ├── scenario/       # Objectives, rating calculator
│   └── ui/             # SDL3 renderer + ImGui panels & overlays
└── tests/              # Unit tests (track graph, pathfinding, economy, rating)
```

---

## 6. First Concrete Next Step
Start **Phase 0 + Phase 1** by setting up `CMakeLists.txt` with SDL3 + Dear ImGui and rendering a pannable/zoomable Europe heightmap with shaded-relief mountains and 10–15 major cities.
