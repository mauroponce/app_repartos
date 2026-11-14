import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { photonPlaces } from "../../app/javascript/photon_places.js"

const boulevard = JSON.parse(readFileSync(new URL("../fixtures/files/photon_boulevard.json", import.meta.url))).features
const feature = (properties = {}, coordinates = [-58.4, -34.8]) => ({
  geometry: { type: "Point", coordinates },
  properties: { name: "Almacén", street: "Mitre", housenumber: "123", city: "Adrogué", countrycode: "AR", ...properties }
})

test("Boulevard results distinguish the mall from both parking areas and warn about missing addresses", () => {
  const places = photonPlaces(boulevard)
  assert.equal(places.length, 3)
  assert.deepEqual(places.map(place => place.category), ["Centro comercial", "Estacionamiento", "Estacionamiento"])
  assert.ok(places.every(place => !place.completeAddress))
  assert.equal(places[0].latitude, -34.8081247)
  assert.equal(places[0].longitude, -58.401075)
  assert.equal(places[2].address, "Avenida Hipólito Yrigoyen")
})

test("businesses precede other places and parking areas without reordering matches within each group", () => {
  const places = photonPlaces([boulevard[2], feature({ name: "Plaza" }), boulevard[1], boulevard[0], feature({ name: "Kiosco", osm_key: "shop", osm_value: "convenience" })])
  assert.deepEqual(places.map(place => place.title), ["Boulevard Shopping", "Kiosco", "Plaza", "Boulevard Shopping", "Boulevard Shopping"])
  assert.equal(places[3].address, "Avenida Hipólito Yrigoyen")
})

test("complete addresses preserve house numbers and distinguish title from address", () => {
  const [place] = photonPlaces([feature({ osm_key: "shop" })])
  assert.equal(place.completeAddress, true)
  assert.equal(place.category, "Comercio")
  assert.equal(place.title, "Almacén")
  assert.equal(place.address, "Mitre 123")
  assert.equal(place.description, "Mitre 123, Adrogué")
  assert.equal(place.label, "Almacén, Mitre 123, Adrogué")
})

test("deduplication removes repeated objects but preserves distinct branches and place types", () => {
  const original = feature({ osm_type: "N", osm_id: 1 })
  const branch = feature({ osm_type: "N", osm_id: 2 })
  assert.equal(photonPlaces([original, original, branch]).length, 2)
  assert.equal(photonPlaces([feature(), feature(), feature({ osm_key: "amenity", osm_value: "parking" })]).length, 2)
  assert.equal(photonPlaces([feature(), feature({}, [-58.5, -34.8])]).length, 2)
})

test("unusable coordinates and unsupported countries never become selectable results", () => {
  const invalid = [null, {}, { geometry: { type: "Polygon" } }, feature({}, null), feature({}, {}), feature({}, [null, -34]), feature({}, ["-58", -34]), feature({}, [-58, 91]), feature({}, [181, -34]), feature({}, [Infinity, -34]), feature({ countrycode: "DE" })]
  assert.deepEqual(photonPlaces(invalid), [])
  assert.equal(photonPlaces([feature({ countrycode: "uy" })]).length, 1)
})

test("an unnamed address remains usable without inventing missing street or house data", () => {
  const [address] = photonPlaces([feature({ name: "" })])
  assert.equal(address.category, "Dirección")
  assert.equal(address.title, "Mitre 123")
  assert.equal(address.description, "Adrogué")
  const [place] = photonPlaces([feature({ street: "", housenumber: "" })])
  assert.equal(place.completeAddress, false)
  assert.equal(place.address, "Almacén")
})

test("the result limit applies after ranking and deduplication", () => {
  const parking = Array.from({ length: 9 }, (_, i) => feature({ name: `Parking ${i}`, osm_key: "amenity", osm_value: "parking" }))
  const places = photonPlaces([...parking, ...parking, boulevard[0]])
  assert.equal(places.length, 8)
  assert.equal(places[0].category, "Centro comercial")
})
