import { Controller } from "@hotwired/stimulus"

// Bubble chart: volume × centrality, sized by field count, coloured by cluster.
// Uses Cytoscape with `preset` layout so we pin nodes to data-derived (x, y)
// positions. We get pan/zoom/hover/click for free, and the canvas reflows
// when the container resizes.
//
// Axes are computed on the JS side (not in CSS) so the chart and the
// axis labels stay in sync regardless of container width.
export default class extends Controller {
  static values = { endpoint: String, objectPath: String }
  static targets = ["canvas", "tooltip", "legend"]

  async connect() {
    this.alive = true
    this.abortController = new AbortController()
    try {
      const cytoscape = (await import("cytoscape")).default
      if (!this.alive) return

      const resp = await fetch(this.endpointValue, {
        headers: { Accept: "application/json" },
        signal: this.abortController.signal
      })
      if (!this.alive) return
      const data = await resp.json()
      if (!this.alive) return

      this.#renderLegend(data.clusters)

      const { width, height } = this.#dims()
      const PADDING = { left: 60, right: 24, top: 24, bottom: 48 }
      const plot = {
        x0: PADDING.left,
        y0: PADDING.top,
        w: Math.max(100, width - PADDING.left - PADDING.right),
        h: Math.max(100, height - PADDING.top - PADDING.bottom)
      }

      const volumes = data.nodes.map(n => n.volume).filter(v => v > 0)
      const inCounts = data.nodes.map(n => n.in_count)
      const maxVol = Math.max(1, ...volumes)
      const maxIn = Math.max(1, ...inCounts)
      const minVolLog = 0
      const maxVolLog = Math.log10(maxVol + 1)
      const clusterColor = new Map(data.clusters.map(c => [c.id, c.color]))

      const elements = data.nodes.map(n => {
        // Log-scale x for volume — collapses the 0..324K range into something legible.
        const x = plot.x0 + ((Math.log10(n.volume + 1) - minVolLog) / (maxVolLog - minVolLog || 1)) * plot.w
        // Linear y for in_count, inverted (Cytoscape y grows downward; we want high inbound at top).
        const y = plot.y0 + plot.h - (n.in_count / maxIn) * plot.h
        return {
          group: "nodes",
          data: {
            id: String(n.id),
            label: n.api_name,
            color: clusterColor.get(n.cluster_id) || "#94a3b8",
            // Bubble radius scales with sqrt(field_count) so visual area ≈ field count.
            size: Math.max(6, Math.min(56, Math.sqrt(Math.max(1, n.field_count)) * 4)),
            tip: `${n.api_name}\nfields: ${n.field_count}\ninbound refs: ${n.in_count}\nvolume: ${n.volume.toLocaleString()}`,
            path: n.path
          },
          position: { x, y }
        }
      })

      this.cy = cytoscape({
        container: this.canvasTarget,
        elements,
        layout: { name: "preset" },
        wheelSensitivity: 0.2,
        style: [
          {
            selector: "node",
            style: {
              "background-color": "data(color)",
              "border-width": 1,
              "border-color": "#1e293b",
              "border-opacity": 0.6,
              "width": "data(size)",
              "height": "data(size)",
              "label": "data(label)",
              "color": "#0f172a",
              "font-size": 9,
              "text-valign": "bottom",
              "text-margin-y": 2,
              "text-opacity": 0
            }
          },
          {
            selector: "node:active, node:selected",
            style: { "text-opacity": 1 }
          }
        ]
      })

      this.#drawAxes(plot, { maxIn, maxVol })

      this.cy.on("mouseover", "node", (evt) => this.#showTooltip(evt))
      this.cy.on("mouseout", "node", () => this.#hideTooltip())
      this.cy.on("tap", "node", (evt) => {
        const apiName = evt.target.data("label")
        window.location = this.objectPathValue.replace("__API_NAME__", encodeURIComponent(apiName))
      })

      // Reflow on container resize (e.g. window resize, sidebar collapse).
      this.resizeObserver = new ResizeObserver(() => this.cy && this.cy.resize())
      this.resizeObserver.observe(this.canvasTarget)
    } catch (e) {
      if (e.name !== "AbortError") console.error("bubble-chart:", e)
    }
  }

  disconnect() {
    this.alive = false
    this.abortController.abort()
    this.resizeObserver?.disconnect()
    this.cy?.destroy()
  }

  #dims() {
    const r = this.canvasTarget.getBoundingClientRect()
    return { width: r.width, height: r.height }
  }

  #drawAxes(plot, { maxIn, maxVol }) {
    // We overlay a single SVG behind the cytoscape canvas for axes + grid.
    const ns = "http://www.w3.org/2000/svg"
    const svg = document.createElementNS(ns, "svg")
    svg.setAttribute("style", "position:absolute;inset:0;pointer-events:none;width:100%;height:100%")
    const { width, height } = this.#dims()
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
    const baseAxis = "stroke:#cbd5e1;stroke-width:1"
    const tickStyle = "fill:#475569;font-size:10px"
    const titleStyle = "fill:#334155;font-size:11px;font-weight:500"

    // X axis line
    this.#svgLine(svg, ns, plot.x0, plot.y0 + plot.h, plot.x0 + plot.w, plot.y0 + plot.h, baseAxis)
    // Y axis line
    this.#svgLine(svg, ns, plot.x0, plot.y0, plot.x0, plot.y0 + plot.h, baseAxis)

    // X ticks: 1, 10, 100, 1K, 10K, 100K, ... up to maxVol
    const xTicks = []
    let v = 1
    while (v <= maxVol * 10 && xTicks.length < 8) { xTicks.push(v); v *= 10 }
    const xLog = Math.log10(maxVol + 1) || 1
    xTicks.forEach(tv => {
      const tx = plot.x0 + (Math.log10(tv) / xLog) * plot.w
      this.#svgLine(svg, ns, tx, plot.y0 + plot.h, tx, plot.y0 + plot.h + 4, baseAxis)
      const t = document.createElementNS(ns, "text")
      t.setAttribute("x", tx); t.setAttribute("y", plot.y0 + plot.h + 16)
      t.setAttribute("text-anchor", "middle"); t.setAttribute("style", tickStyle)
      t.textContent = this.#shortNum(tv)
      svg.appendChild(t)
    })

    // Y ticks: 0, max/4, max/2, 3max/4, max
    const yTicks = [ 0, Math.round(maxIn * 0.25), Math.round(maxIn * 0.5), Math.round(maxIn * 0.75), maxIn ]
    yTicks.forEach(tv => {
      const ty = plot.y0 + plot.h - (tv / maxIn) * plot.h
      this.#svgLine(svg, ns, plot.x0 - 4, ty, plot.x0, ty, baseAxis)
      const t = document.createElementNS(ns, "text")
      t.setAttribute("x", plot.x0 - 8); t.setAttribute("y", ty + 3)
      t.setAttribute("text-anchor", "end"); t.setAttribute("style", tickStyle)
      t.textContent = String(tv)
      svg.appendChild(t)
    })

    // Axis titles
    const xTitle = document.createElementNS(ns, "text")
    xTitle.setAttribute("x", plot.x0 + plot.w / 2); xTitle.setAttribute("y", plot.y0 + plot.h + 38)
    xTitle.setAttribute("text-anchor", "middle"); xTitle.setAttribute("style", titleStyle)
    xTitle.textContent = "Records (log scale) →"
    svg.appendChild(xTitle)

    const yTitle = document.createElementNS(ns, "text")
    yTitle.setAttribute("x", -(plot.y0 + plot.h / 2)); yTitle.setAttribute("y", 16)
    yTitle.setAttribute("text-anchor", "middle"); yTitle.setAttribute("style", titleStyle)
    yTitle.setAttribute("transform", "rotate(-90)")
    yTitle.textContent = "Inbound references →"
    svg.appendChild(yTitle)

    this.canvasTarget.appendChild(svg)
  }

  #svgLine(parent, ns, x1, y1, x2, y2, style) {
    const l = document.createElementNS(ns, "line")
    l.setAttribute("x1", x1); l.setAttribute("y1", y1); l.setAttribute("x2", x2); l.setAttribute("y2", y2)
    l.setAttribute("style", style)
    parent.appendChild(l)
  }

  #shortNum(n) {
    if (n >= 1e6) return `${n / 1e6}M`
    if (n >= 1e3) return `${n / 1e3}K`
    return String(n)
  }

  #showTooltip(evt) {
    if (!this.hasTooltipTarget) return
    const pos = evt.target.renderedPosition()
    const t = this.tooltipTarget
    t.textContent = evt.target.data("tip")
    t.style.whiteSpace = "pre"
    t.style.left = `${pos.x + 12}px`
    t.style.top = `${pos.y + 12}px`
    t.classList.remove("hidden")
  }

  #hideTooltip() {
    if (this.hasTooltipTarget) this.tooltipTarget.classList.add("hidden")
  }

  #renderLegend(clusters) {
    if (!this.hasLegendTarget) return
    this.legendTarget.innerHTML = ""
    clusters.forEach(c => {
      const li = document.createElement("li")
      li.className = "flex items-center gap-2"
      li.innerHTML = `<span class="inline-block w-3 h-3 rounded-full" style="background:${c.color}"></span><span class="text-slate-700">${c.name}</span><span class="text-slate-400">(${c.size})</span>`
      this.legendTarget.appendChild(li)
    })
  }
}
