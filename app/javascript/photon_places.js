// Keep provider relevance within each group; parking areas remain selectable.
export function photonPlaces(features) {
  const seen = new Set()
  const priority = { mall: 0, shop: 0, parking: 2 }
  return features.map(photonPlace).filter(place => {
    if (!place || seen.has(place.key)) return false
    seen.add(place.key)
    return true
  }).sort((a, b) => (priority[a.kind] ?? 1) - (priority[b.kind] ?? 1)).slice(0, 8)
}

function photonPlace(feature) {
  if (feature?.geometry?.type !== "Point" || !Array.isArray(feature.geometry.coordinates)) return null
  const [longitude, latitude] = feature.geometry.coordinates
  if (!Number.isFinite(latitude) || Math.abs(latitude) > 90 || !Number.isFinite(longitude) || Math.abs(longitude) > 180) return null
  const properties = feature.properties || {}
  const text = key => typeof properties[key] === "string" || typeof properties[key] === "number" ? String(properties[key]).trim().slice(0, 255) : ""
  const country = text("countrycode").toLowerCase()
  if (country && !["ar", "uy"].includes(country)) return null
  const name = text("name")
  const streetName = text("street")
  const houseNumber = text("housenumber")
  const street = [streetName, houseNumber].filter(Boolean).join(" ")
  const city = text("city") || text("town") || text("village") || text("locality") || text("county")
  const parts = [...new Set([name, street, city, text("state"), text("country")].filter(Boolean))]
  const label = parts.join(", ")
  if (!label) return null
  const osmKey = text("osm_key")
  const osmValue = text("osm_value")
  let kind = "place"
  if (osmKey === "amenity" && ["parking", "parking_entrance", "parking_space"].includes(osmValue)) kind = "parking"
  else if (osmKey === "shop") kind = osmValue === "mall" ? "mall" : "shop"
  else if (text("type") === "street" || osmKey === "highway") kind = "street"
  else if (streetName && houseNumber && !name) kind = "address"
  const category = { mall: "Centro comercial", shop: "Comercio", parking: "Estacionamiento", street: "Calle", address: "Dirección", place: "Lugar" }[kind]
  const title = name || street || city || label
  // OSM identity avoids merging separate branches or a mall with its parking.
  const key = text("osm_type") && text("osm_id") ? `osm:${text("osm_type")}:${text("osm_id")}` : `${kind}:${latitude}:${longitude}:${label.toLocaleLowerCase("es")}`
  return {
    key, kind, category, latitude, longitude, name, city, label, title,
    address: (street || name || label).slice(0, 255),
    description: parts.filter(part => part !== title).join(", "),
    completeAddress: Boolean(streetName && houseNumber)
  }
}
