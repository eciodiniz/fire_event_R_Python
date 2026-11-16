# ==== Packages ====
library(terra)       # raster and vector reading and processing
library(geobr)       # official boundaries of Brazil (IBGE): states, municipalities, biomes
library(ggplot2)     # plots
library(tidyterra)   # allows drawing terra objects in ggplot2
library(maptiles)    # downloads satellite imagery to use as the map background

# ==== 1. OPEN ====
# Data: INPE AQ1km Burned Area (monthly, ~1 km pixels, South America)
# Analysis month in YYYYMM format (Sep/2024, fire season in the Pantanal)
year_month <- "202409"

# Build the link to the month's file and download it to a temporary file
url <- paste0("https://dataserver-coids.inpe.br/queimadas/queimadas/area_queimada/AQ1km/tif/aqm1km_", year_month, ".tif")
tmp <- tempfile(fileext = ".tif")
download.file(url, tmp, mode = "wb")   # "wb": writes as a binary file (required on Windows)

# Read the raster and view the metadata: size, resolution, extent and coordinate system
r <- rast(tmp)
r

# ==== 2. REPROJECT ====
# The original raster is in degrees (WGS 84), a poor unit for measuring distances and areas
# Convert to meters: SIRGAS 2000 / Brazil Polyconic (EPSG:5880)
# method = "near": copies the value of the nearest pixel, without creating intermediate values
#   (essential for categorical data, such as burned / not burned)
# res = 1000: 1,000 m x 1,000 m pixels, equivalent to the original resolution
r_m <- project(r, "EPSG:5880", method = "near", res = 1000)

# ==== 3. CLIP ====
# Download the IBGE biomes (2019) and select the Pantanal
biomes <- read_biomes(year = 2019)

# Convert the boundary to terra format and put it in the same projection as the raster
# (raster and vector must be in the same coordinate system to overlay)
pantanal_v <- project(vect(biomes[biomes$name_biome == "Pantanal", ]), crs(r_m))

# crop(): crops the raster to the rectangle enclosing the Pantanal (reduces the data size)
# mask(): erases (NA) the pixels of that rectangle that fall outside the biome boundary
r_pant <- mask(crop(r_m, pantanal_v), pantanal_v)

# ==== 4. RESULT ====
# In AQ1km, pixel = 1 indicates burned area in the month
# Keep only these pixels; the others become NA (they do not appear on the map)
burned <- ifel(r_pant == 1, 1, NA)

# Burned area in km²: expanse() sums the actual area of each burned pixel
area_km2 <- expanse(burned, unit = "km")$area

# Background satellite imagery (Esri World Imagery, true color)
# zoom = 9: level of detail suited to a region the size of the Pantanal
# The image already comes in the same projection as the boundary; mask() keeps only the part inside the biome
sat <- get_tiles(pantanal_v, provider = "Esri.WorldImagery", zoom = 9, crop = TRUE)
sat <- mask(sat, pantanal_v)

# Map: layers are drawn in the order they appear (background first)
p <- ggplot() +
  geom_spatraster_rgb(data = sat, maxcell = Inf) +                                  # satellite (maxcell = Inf: full resolution)
  geom_spatraster(data = burned, maxcell = Inf) +                                 # burned pixels
  geom_spatvector(data = pantanal_v, fill = NA, color = "grey20", linewidth = 0.4) + # biome outline
  # Bright yellow: evokes fire, contrasts with vegetation and is readable by colorblind people
  scale_fill_gradient(low = "#FFD700", high = "#FFD700", na.value = NA,
                      breaks = 1, labels = "Burned area", name = NULL, guide = "legend") +
  coord_sf(crs = "EPSG:5880", datum = sf::st_crs(4326)) +                           # map in meters, axes in degrees
  labs(title    = "Burned area in the Pantanal (Sep/2024)",
       subtitle = paste(format(round(area_km2), big.mark = ",", decimal.mark = "."), "km² burned"),
       caption  = "Source: INPE (AQ1km) and IBGE · Imagery: Esri World Imagery",
       x = NULL, y = NULL) +
  theme_bw() +                                                                      # frame and coordinates
  theme(panel.grid = element_blank(),                                               # no internal grid lines
        legend.position = "bottom")
p

# Save the map as PNG, at 300 dpi (high resolution) with a white background
ggsave("burned_area_pantanal_202409.png", plot = p, width = 6, height = 7, dpi = 300, bg = "white")