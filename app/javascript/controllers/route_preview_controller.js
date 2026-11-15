import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { geometry: Object, stops: Array }
  connect() {
    const coords = this.geometryValue.coordinates
    if (!Array.isArray(coords) || coords.length < 2) return
    const all = [...coords, ...this.stopsValue.map(stop => stop.coordinates)]
    const project = ([lng,lat]) => [lng, Math.log(Math.tan(Math.PI / 4 + Math.max(-85, Math.min(85, lat)) * Math.PI / 360)) * 180 / Math.PI]
    const points = all.map(project)
    const xs = points.map(p=>p[0]), ys = points.map(p=>p[1])
    const minX = Math.min(...xs), minY = Math.min(...ys), maxX = Math.max(...xs), maxY = Math.max(...ys)
    const scale = Math.min(740 / Math.max(maxX-minX,0.0001), 340 / Math.max(maxY-minY,0.0001))
    const xy = pair => { const [x,y] = project(pair); return [30+(x-minX)*scale,370-(y-minY)*scale] }
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
    svg.setAttribute("viewBox", "0 0 800 400")
    svg.setAttribute("aria-hidden", "true")
    const line = document.createElementNS(svg.namespaceURI,"polyline")
    line.setAttribute("points", coords.map(pair=>xy(pair).join(",")).join(" "))
    line.setAttribute("fill", "none"); line.setAttribute("stroke", "#7958b6"); line.setAttribute("stroke-width", "3")
    svg.append(line)
    this.stopsValue.forEach((stop,index)=>{
      const [x,y] = xy(stop.coordinates)
      const circle = document.createElementNS(svg.namespaceURI,"circle")
      circle.setAttribute("cx",x); circle.setAttribute("cy",y); circle.setAttribute("r",12); circle.setAttribute("fill","#252332")
      const title = document.createElementNS(svg.namespaceURI,"title"); title.textContent = `${index+1}. ${stop.name}`; circle.append(title)
      const label = document.createElementNS(svg.namespaceURI,"text")
      label.setAttribute("x",x); label.setAttribute("y",y+4); label.setAttribute("text-anchor","middle"); label.setAttribute("fill","white"); label.setAttribute("font-size","11"); label.textContent = index+1
      svg.append(circle,label)
    })
    this.element.replaceChildren(svg)
  }
}
