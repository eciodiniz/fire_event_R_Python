# ==== Pacotes ====
library(terra)       # leitura e processamento de rasters e vetores
library(geobr)       # limites oficiais do Brasil (IBGE): estados, municípios, biomas
library(ggplot2)     # gráficos
library(tidyterra)   # permite desenhar objetos do terra no ggplot2
library(maptiles)    # baixa imagens de satélite para usar como fundo do mapa

# ==== 1. ABRIR ====
# Dado: Área Queimada AQ1km do INPE (mensal, pixels de ~1 km, América do Sul)
# Mês da análise no formato AAAAMM (set/2024, temporada de fogo no Pantanal)
ano_mes <- "202409"

# Montar o link do arquivo do mês e baixá-lo para um arquivo temporário
url <- paste0("https://dataserver-coids.inpe.br/queimadas/queimadas/area_queimada/AQ1km/tif/aqm1km_", ano_mes, ".tif")
tmp <- tempfile(fileext = ".tif")
download.file(url, tmp, mode = "wb")   # "wb": grava como arquivo binário (necessário no Windows)

# Ler o raster e ver os metadados: tamanho, resolução, extensão e sistema de coordenadas
r <- rast(tmp)
r

# ==== 2. REPROJETAR ====
# O raster original está em graus (WGS 84), unidade ruim para medir distâncias e áreas
# Converter para metros: SIRGAS 2000 / Policônica do Brasil (EPSG:5880)
# method = "near": copia o valor do pixel mais próximo, sem criar valores intermediários
#   (essencial para dados de categoria, como queimado / não queimado)
# res = 1000: pixels de 1.000 m x 1.000 m, equivalente à resolução original
r_m <- project(r, "EPSG:5880", method = "near", res = 1000)

# ==== 3. RECORTAR ====
# Baixar os biomas do IBGE (2019) e selecionar o Pantanal
biomas <- read_biomes(year = 2019)

# Converter o limite para o formato do terra e colocá-lo na mesma projeção do raster
# (raster e vetor precisam estar no mesmo sistema de coordenadas para se sobrepor)
pantanal_v <- project(vect(biomas[biomas$name_biome == "Pantanal", ]), crs(r_m))

# crop(): corta o raster no retângulo que envolve o Pantanal (reduz o tamanho do dado)
# mask(): apaga (NA) os pixels desse retângulo que ficam fora do limite do bioma
r_pant <- mask(crop(r_m, pantanal_v), pantanal_v)

# ==== 4. RESULTADO ====
# No AQ1km, pixel = 1 indica área queimada no mês
# Manter só esses pixels; os demais viram NA (não aparecem no mapa)
queimado <- ifel(r_pant == 1, 1, NA)

# Área queimada em km²: expanse() soma a área real de cada pixel queimado
area_km2 <- expanse(queimado, unit = "km")$area

# Imagem de satélite de fundo (Esri World Imagery, cores reais)
# zoom = 9: nível de detalhe adequado para uma região do tamanho do Pantanal
# A imagem já vem na mesma projeção do limite; mask() mantém só a parte dentro do bioma
sat <- get_tiles(pantanal_v, provider = "Esri.WorldImagery", zoom = 9, crop = TRUE)
sat <- mask(sat, pantanal_v)

# Mapa: as camadas são desenhadas na ordem em que aparecem (fundo primeiro)
p <- ggplot() +
  geom_spatraster_rgb(data = sat, maxcell = Inf) +                                  # satélite (maxcell = Inf: resolução total)
  geom_spatraster(data = queimado, maxcell = Inf) +                                 # pixels queimados
  geom_spatvector(data = pantanal_v, fill = NA, color = "grey20", linewidth = 0.4) + # contorno do bioma
  # Amarelo vivo: lembra fogo, contrasta com a vegetação e é legível por daltônicos
  scale_fill_gradient(low = "#FFD700", high = "#FFD700", na.value = NA,
                      breaks = 1, labels = "Área queimada", name = NULL, guide = "legend") +
  coord_sf(crs = "EPSG:5880", datum = sf::st_crs(4326)) +                           # mapa em metros, eixos em graus
  labs(title    = "Área queimada no Pantanal (set/2024)",
       subtitle = paste(format(round(area_km2), big.mark = ".", decimal.mark = ","), "km² queimados"),
       caption  = "Fonte: INPE (AQ1km) e IBGE · Imagem: Esri World Imagery",
       x = NULL, y = NULL) +
  theme_bw() +                                                                      # moldura e coordenadas
  theme(panel.grid = element_blank(),                                               # sem linhas de grade internas
        legend.position = "bottom")
p

# Salvar o mapa em PNG, com 300 dpi (alta resolução) e fundo branco
ggsave("area_queimada_pantanal_202409.png", plot = p, width = 6, height = 7, dpi = 300, bg = "white")