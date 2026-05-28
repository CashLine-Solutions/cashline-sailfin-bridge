import { Controller } from "@hotwired/stimulus"

// Module-level guard: cytoscape.use(fcose) mutates a global singleton. Only
// register the plugin once across the page's lifetime; subsequent Stimulus
// connects (Turbo cache replay, re-navigation) must not call .use() again.
let fcoseRegistered = false

// Renders a Cytoscape force-directed graph from a JSON endpoint.
// Lazily imports cytoscape + cytoscape-fcose; no-ops if the modules
// aren't pinned in the importmap.
export default class extends Controller {
  static values = { endpoint: String, objectPath: String }
  static targets = ["canvas", "namespaceFilter", "minRecords", "legend", "hidePlatform"]

  async connect() {
    this.alive = true
    this.abortController = new AbortController()
    try {
      const cytoscape = (await import("cytoscape")).default
      if (!this.alive) return
      try {
        const fcose = (await import("cytoscape-fcose")).default
        if (!fcoseRegistered) {
          cytoscape.use(fcose)
          fcoseRegistered = true
        }
        this.layoutName = "fcose"
      } catch (_e) {
        this.layoutName = "cose"
      }

      const resp = await fetch(this.endpointValue, {
        headers: { Accept: "application/json" },
        signal: this.abortController.signal
      })
      if (!this.alive) return
      const data = await resp.json()
      if (!this.alive) return

      // Note: do NOT assign to `this.data` — Stimulus reserves it as a
      // read-only getter wrapping the element's data-* attributes.
      // The local `data` variable is captured in the namespace-filter
      // build below; no need to stash it on the controller.
      // Stash raw data so toggles can re-filter without re-fetching.
      this.rawData = data

      this.cy = cytoscape({
        container: this.canvasTarget,
        elements: this.buildElements(data),
        layout: this.#layoutOptions(),
        minZoom: 0.1,
        maxZoom: 8,
        wheelSensitivity: 0.25,
        style: [
          {
            selector: "node",
            style: {
              "background-color": "data(color)",
              "border-width": 1,
              "border-color": "#1e293b",
              "border-opacity": 0.4,
              "width": "data(size)",
              "height": "data(size)",
              "label": "data(label)",
              "color": "#0f172a",
              "font-size": 9,
              "text-valign": "bottom",
              "text-margin-y": 2
            }
          },
          { selector: "edge", style: { "width": 1, "line-color": "#cbd5e1", "curve-style": "bezier", "opacity": 0.7, "target-arrow-color": "#cbd5e1", "target-arrow-shape": "triangle", "arrow-scale": 0.6 } }
        ]
      })
      this.cy.on("tap", "node", (evt) => {
        const apiName = evt.target.data("label")
        window.location = this.objectPathValue.replace("__API_NAME__", encodeURIComponent(apiName))
      })

      const namespaces = Array.from(new Set(data.nodes.map(n => n.namespace))).sort()
      if (this.hasNamespaceFilterTarget) {
        for (const ns of namespaces) {
          const opt = document.createElement("option")
          opt.value = ns; opt.textContent = ns
          this.namespaceFilterTarget.appendChild(opt)
        }
      }
      this.#renderLegend(data.clusters || [])
    } catch (e) {
      if (e.name === "AbortError") return
      // Distinguish import failures (CDN/importmap) from runtime errors
      // so the console message points at the right thing.
      if (e.message?.includes("Failed to fetch") || e.message?.includes("Failed to resolve module")) {
        console.warn("[graph] Cytoscape failed to load — check importmap pin", e)
      } else {
        console.error("[graph] render failed", e)
      }
    }
  }

  // Critical: tear everything down on Turbo navigation. Without this the
  // Cytoscape instance keeps a reference to a detached DOM node, the fetch
  // resolves after disconnect and writes into nothing, and the tap handler
  // accumulates on every visit.
  disconnect() {
    this.alive = false
    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
    if (this.cy) {
      try { this.cy.destroy() } catch (_e) { /* already torn down */ }
      this.cy = null
    }
  }

  buildElements(data) {
    const clusterColor = new Map((data.clusters || []).map(c => [c.id, c.color]))
    const hidePlatform = this.#hidePlatformOn()
    const visibleNodeIds = new Set()

    const nodes = data.nodes
      .filter(n => !(hidePlatform && n.platform))
      .map(n => {
        visibleNodeIds.add(n.id)
        // Bubble size scales with sqrt(field_count) so visual area ≈ field count.
        // Clamped so a 1-field stub doesn't disappear and a 438-field giant
        // doesn't blot out half the canvas.
        const size = Math.max(14, Math.min(72, Math.sqrt(Math.max(1, n.field_count || 1)) * 5))
        return {
          data: {
            id: String(n.id),
            label: n.api_name,
            namespace: n.namespace,
            cluster: n.cluster_id,
            recordCount: n.volume || 0,
            color: clusterColor.get(n.cluster_id) || "#94a3b8",
            size: size,
            platform: !!n.platform
          }
        }
      })

    const edges = (data.edges || [])
      // Drop system-owner edges (CreatedById / OwnerId / LastModifiedById /
      // RecordTypeId) when the toggle is on. These contribute ~half the
      // edges in a Salesforce schema and produce the central hairball.
      .filter(e => !(hidePlatform && e.system))
      .filter(e => visibleNodeIds.has(e.source) && visibleNodeIds.has(e.target))
      .map(e => ({ data: { id: `e${e.source}-${e.target}-${e.source_field || ""}`, source: String(e.source), target: String(e.target) } }))

    return [ ...nodes, ...edges ]
  }

  #hidePlatformOn() {
    return this.hasHidePlatformTarget ? !!this.hidePlatformTarget.checked : false
  }

  #layoutOptions() {
    // fcose defaults produce a tight central blob for 100+ nodes. These
    // parameters give more room to breathe: longer ideal edges, stronger
    // repulsion, lower gravity, and tiling of disconnected components so
    // unrelated subgraphs settle in their own neighbourhoods.
    return {
      name: this.layoutName,
      animate: false,
      randomize: true,
      tile: true,
      tilingPaddingHorizontal: 30,
      tilingPaddingVertical: 30,
      nodeRepulsion: 12000,
      idealEdgeLength: 110,
      edgeElasticity: 0.45,
      gravity: 0.08,
      gravityRange: 3.5,
      numIter: 4500,
      packComponents: true
    }
  }

  applyFilters() {
    if (!this.cy) return
    const ns = this.hasNamespaceFilterTarget ? this.namespaceFilterTarget.value : ""
    const min = this.hasMinRecordsTarget ? Number(this.minRecordsTarget.value || 0) : 0
    this.cy.nodes().forEach(n => {
      const matches = (!ns || n.data("namespace") === ns) && n.data("recordCount") >= min
      n.style("display", matches ? "element" : "none")
    })
    this.cy.edges().forEach(e => {
      const src = this.cy.getElementById(e.data("source"))
      const tgt = this.cy.getElementById(e.data("target"))
      const show = src.style("display") !== "none" && tgt.style("display") !== "none"
      e.style("display", show ? "element" : "none")
    })
  }

  // Platform toggle changes the element set itself (nodes are removed, not
  // just hidden), then re-runs the layout so the remaining graph relaxes
  // into the larger canvas. This is structurally different from the
  // namespace/min-records filter, which only hides existing nodes in place.
  togglePlatform() {
    if (!this.cy || !this.rawData) return
    this.cy.elements().remove()
    this.cy.add(this.buildElements(this.rawData))
    this.cy.layout(this.#layoutOptions()).run()
  }

  fit() {
    if (this.cy) this.cy.fit()
  }

  zoomIn() {
    if (!this.cy) return
    this.cy.zoom({ level: this.cy.zoom() * 1.4, renderedPosition: { x: this.cy.width() / 2, y: this.cy.height() / 2 } })
  }

  zoomOut() {
    if (!this.cy) return
    this.cy.zoom({ level: this.cy.zoom() / 1.4, renderedPosition: { x: this.cy.width() / 2, y: this.cy.height() / 2 } })
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
