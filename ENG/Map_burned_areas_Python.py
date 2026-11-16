# ==== Packages ====
import os, tempfile, urllib.request
import numpy as np
import rioxarray                          # raster reading and processing (xarray .rio accessor)
import geopandas as gpd                   # vector reading and processing
import contextily as ctx                  # downloads satellite imagery to use as the map background
import cartopy.crs as ccrs                # projected map with degree coordinates on the axes
import matplotlib.pyplot as plt           # plots
import matplotlib.ticker as mticker
from matplotlib.colors import ListedColormap
from matplotlib.patches import Patch
from pyproj import Geod, Transformer      # geodesic area calculation
from rasterio.enums import Resampling
from rasterio.features import geometry_mask
from rasterio.transform import from_bounds

# ==== 1. OPEN ====
# Data: INPE AQ1km Burned Area (monthly, ~1 km pixels, South America)
# Analysis month in YYYYMM format (Sep/2024, fire season in the Pantanal)
year_month = "202409"

# Build the link to the month's file and download it to the temporary folder
url = f"https://dataserver-coids.inpe.br/queimadas/queimadas/area_queimada/AQ1km/tif/aqm1km_{year_month}.tif"
tmp = os.path.join(tempfile.gettempdir(), f"aqm1km_{year_month}.tif")
urllib.request.urlretrieve(url, tmp)

# Read the raster (1 band) and view the metadata: size, resolution, extent and coordinate system
r = rioxarray.open_rasterio(tmp).squeeze("band", drop=True)
print(r.shape, r.rio.resolution(), r.rio.bounds(), r.rio.crs)

# ==== 2. REPROJECT ====
# The original raster is in degrees (WGS 84), a poor unit for measuring distances and areas
# Convert to meters: SIRGAS 2000 / Brazil Polyconic (EPSG:5880)
# Resampling.nearest: copies the value of the nearest pixel, without creating intermediate values
#   (essential for categorical data, such as burned / not burned)
# resolution=1000: 1,000 m x 1,000 m pixels, equivalent to the original resolution
r_m = r.rio.reproject("EPSG:5880", resolution=1000, resampling=Resampling.nearest)

# ==== 3. CLIP ====
# Download the IBGE biomes (2019) and select the Pantanal
# Official file from the geobr project (Ipea), the same one used by read_biomes() in R
url_bio = "https://github.com/ipea/geobr_prep_data/releases/download/v2.0.0/biomes_2019_simplified.parquet"
tmp_bio = os.path.join(tempfile.gettempdir(), "biomes_2019.parquet")
urllib.request.urlretrieve(url_bio, tmp_bio)
biomes = gpd.read_parquet(tmp_bio)

# Put the boundary in the same projection as the raster
# (raster and vector must be in the same coordinate system to overlay)
pantanal = biomes[biomes["name_biome"] == "Pantanal"].to_crs(r_m.rio.crs)

# clip(): crops the raster to the rectangle enclosing the Pantanal (drop=True)
#   and erases the pixels outside the biome boundary
# all_touched=True: keeps the pixels touched by the boundary (same criterion as terra::mask in R)
r_pant = r_m.rio.clip(pantanal.geometry, all_touched=True, drop=True)

# ==== 4. RESULT ====
# In AQ1km, pixel = 1 indicates burned area in the month
# Keep only these pixels; the others become NaN (they do not appear on the map)
burned = r_pant.where(r_pant == 1)

# Burned area in km²: sum of the actual (geodesic) area of each burned pixel
#   (same calculation as terra::expanse in R: pixel corners converted to lon/lat)
row, col = np.nonzero(burned.notnull().values)
half_x, half_y = [abs(v) / 2 for v in burned.rio.resolution()]
xc, yc = burned.x.values[col], burned.y.values[row]
corners_x = np.stack([xc - half_x, xc + half_x, xc + half_x, xc - half_x], axis=1)
corners_y = np.stack([yc - half_y, yc - half_y, yc + half_y, yc + half_y], axis=1)
lon, lat = Transformer.from_crs("EPSG:5880", "EPSG:4326", always_xy=True).transform(corners_x, corners_y)
geod = Geod(ellps="WGS84")
area_km2 = sum(abs(geod.polygon_area_perimeter(lo, la)[0]) for lo, la in zip(lon, lat)) / 1e6

# Background satellite imagery (Esri World Imagery, true color)
# zoom=9: level of detail suited to a region the size of the Pantanal
# The tiles come in Web Mercator (EPSG:3857): download them for the Pantanal extent and reproject to EPSG:5880
w, s, e, n = pantanal.to_crs("EPSG:3857").total_bounds
sat, ext = ctx.bounds2img(w, s, e, n, zoom=9, source=ctx.providers.Esri.WorldImagery)
sat, ext = ctx.warp_tiles(sat, ext, t_crs="EPSG:5880")   # ext = (xmin, xmax, ymin, ymax)

# Keep the image only inside the Pantanal: pixels outside the boundary become transparent
outside = geometry_mask(pantanal.geometry, out_shape=sat.shape[:2], all_touched=True,
                     transform=from_bounds(ext[0], ext[2], ext[1], ext[3], sat.shape[1], sat.shape[0]))
sat = np.dstack([sat[:, :, :3], np.where(outside, 0, 255).astype(np.uint8)])

# Map: layers are drawn in the order they appear (background first)
proj = ccrs.epsg(5880)                                    # map in meters (Polyconic)
xmin, ymin, xmax, ymax = burned.rio.bounds()

fig = plt.figure(figsize=(6, 7))
ax = fig.add_subplot(projection=proj)
ax.imshow(sat, extent=ext, origin="upper", transform=proj)               # satellite
ax.imshow(burned.values, extent=(xmin, xmax, ymin, ymax), origin="upper", transform=proj,
          interpolation="nearest", cmap=ListedColormap(["#FFD700"]))      # burned pixels
# Bright yellow: evokes fire, contrasts with vegetation and is readable by colorblind people
ax.add_geometries(pantanal.geometry, crs=proj, facecolor="none",
                  edgecolor="0.2", linewidth=1.1)                         # biome outline
x0, y0, x1, y1 = pantanal.total_bounds
ax.set_extent([x0 - 20000, x1 + 20000, y0 - 20000, y1 + 20000], crs=proj)   # 20 km margin around the biome

# Frame with coordinates in degrees, without internal grid lines
gl = ax.gridlines(draw_labels=True, linewidth=0)
gl.top_labels = gl.right_labels = False
gl.xlocator = mticker.FixedLocator(range(-60, -53))
gl.ylocator = mticker.FixedLocator(range(-23, -14))

# Titles, legend and source
area_txt = f"{round(area_km2):,}"
ax.set_title(f"Burned area in the Pantanal (Sep/2024)\n{area_txt} km² burned", loc="left", fontsize=12)
ax.legend(handles=[Patch(facecolor="#FFD700", label="Burned area")],
          loc="upper center", bbox_to_anchor=(0.5, -0.05), frameon=False)
ax.text(0.5, -0.13, "Source: INPE (AQ1km) and IBGE · Imagery: Esri World Imagery",
        transform=ax.transAxes, ha="center", va="top", fontsize=8)

# Save the map as PNG, at 300 dpi (high resolution) with a white background; then display it
fig.savefig("burned_area_pantanal_202409.png", dpi=300, facecolor="white", bbox_inches="tight")
plt.show()
