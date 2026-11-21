# Attributions & Third-Party Licenses

Raildev's source code is licensed under the [MIT License](LICENSE).
This project builds on the following open-source libraries, tools, and open-license geospatial datasets:

## Engine, Libraries & Build Tools
- **[Godot Engine 4](https://godotengine.org/)** — MIT License. 3D rendering engine, scene runtime, and Vulkan Forward+ renderer.
- **[Simple DirectMedia Layer (SDL3, SDL3_ttf, SDL3_image)](https://libsdl.org/)** — zlib License. Used by the C++20 core & map-export tooling.
- **[Dear ImGui](https://github.com/ocornut/imgui)** by Omar Cornut — MIT License. Used by the C++ HUD prototype.
- **[CMake](https://cmake.org/)** — BSD 3-Clause License. C++ build system.
- **[Pillow (PIL Fork)](https://python-pillow.org/)** — MIT-CMU License. Python image processing used by the regional map-pack baker.
- **[ImageMagick](https://imagemagick.org/)** — Apache 2.0 License. CLI image composition and tone-grading used by the satellite texture baker.

## Open-License Geospatial & Earth Observation Data
- **Elevation & Bathymetry**: [Mapzen / AWS Open Data Terrarium Elevation Tiles](https://registry.opendata.aws/terrain-tiles/) (combining SRTM, EU-DEM, GMTED, and ETOPO1) — Public Domain / CC0.
- **Satellite Imagery**: [Sentinel-2 Cloudless 2021](https://s2maps.eu) by [EOX IT Services GmbH](https://eox.at) (contains modified Copernicus Sentinel data 2021) — [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- **Regional High-Resolution Hydrography & Land Use**: © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright) (via EOX OSM WMS) — [Open Database License (ODbL 1.0)](https://opendatacommons.org/licenses/odbl/).
- **Continental Rivers, Lakes & Coastlines**: [Natural Earth 1:10m Physical Vectors](https://www.naturalearthdata.com/) — Public Domain (CC0).
- **European Forest & Land Cover**: [Copernicus CORINE Land Cover (CLC 2018)](https://land.copernicus.eu/en/products/corine-land-cover) by the European Environment Agency (EEA) — EU Open Data.
