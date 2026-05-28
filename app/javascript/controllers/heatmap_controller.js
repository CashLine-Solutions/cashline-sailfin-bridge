import { Controller } from "@hotwired/stimulus"

// Field-fill density heatmap. One row per sobject, columns are the
// object's top-filled fields, cell colour encodes 1 - null_rate (darker
// means more often populated). Objects with sparse data appear as short
// rows; objects carrying real data appear as long dense bars.
//
// We render inline SVG so the chart can scale to ~123 rows × 60 cells
// without a heavyweight chart library. Click a row label to navigate to
// that object's detail page.
export default class extends Controller {
  static values = { endpoint: String, objectPath: String }
  static targets = ["canvas"]

  async connect() {
    this.alive = true
    this.abortController = new AbortController()
    try {
      const resp = await fetch(this.endpointValue, {
        headers: { Accept: "application/json" },
        signal: this.abortController.signal
      })
      if (!this.alive) return
      const data = await resp.json()
      if (!this.alive) return
      this.#render(data.heatmap || [])
    } catch (e) {
      if (e.name !== "AbortError") console.error("heatmap:", e)
    }
  }

  disconnect() {
    this.alive = false
    this.abortController.abort()
  }

  #render(rows) {
    if (!rows.length) {
      this.canvasTarget.innerHTML = `<p class="p-6 text-sm text-slate-500">No field-profile data available for this run.</p>`
      return
    }
    const CELL_W = 10
    const CELL_H = 14
    const LABEL_W = 280
    const MAX_COLS = Math.max(...rows.map(r => r.cells.length))
    const width = LABEL_W + MAX_COLS * CELL_W + 16
    const height = rows.length * CELL_H + 24

    const ns = "http://www.w3.org/2000/svg"
    const svg = document.createElementNS(ns, "svg")
    svg.setAttribute("width", width)
    svg.setAttribute("height", height)
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
    svg.style.fontFamily = "ui-sans-serif, system-ui, sans-serif"

    // Header row
    const headerText = document.createElementNS(ns, "text")
    headerText.setAttribute("x", LABEL_W - 4)
    headerText.setAttribute("y", 14)
    headerText.setAttribute("text-anchor", "end")
    headerText.setAttribute("style", "fill:#64748b;font-size:10px")
    headerText.textContent = "← most-filled fields →"
    svg.appendChild(headerText)

    rows.forEach((row, i) => {
      const y = 24 + i * CELL_H

      // Object name (clickable)
      const a = document.createElementNS(ns, "a")
      a.setAttribute("href", this.objectPathValue.replace("__API_NAME__", encodeURIComponent(row.api_name)))
      const t = document.createElementNS(ns, "text")
      t.setAttribute("x", LABEL_W - 8)
      t.setAttribute("y", y + 10)
      t.setAttribute("text-anchor", "end")
      t.setAttribute("style", "fill:#1e293b;font-size:10px;font-family:ui-monospace,Menlo,monospace")
      t.textContent = row.api_name
      a.appendChild(t)
      svg.appendChild(a)

      // Cells
      row.cells.forEach((cell, j) => {
        const rect = document.createElementNS(ns, "rect")
        rect.setAttribute("x", LABEL_W + j * CELL_W)
        rect.setAttribute("y", y)
        rect.setAttribute("width", CELL_W - 1)
        rect.setAttribute("height", CELL_H - 2)
        rect.setAttribute("fill", this.#colorFor(cell.fill))
        const title = document.createElementNS(ns, "title")
        title.textContent = `${cell.field} — ${(cell.fill * 100).toFixed(1)}% filled`
        rect.appendChild(title)
        svg.appendChild(rect)
      })
    })

    this.canvasTarget.innerHTML = ""
    this.canvasTarget.appendChild(svg)
  }

  // 0 → pale slate; 1 → deep indigo. Logarithmic-ish so the difference
  // between 5% and 50% is visible (a purely linear scale leaves the
  // low end illegible).
  #colorFor(fill) {
    const f = Math.max(0, Math.min(1, fill))
    // Two-stop interpolation between #f1f5f9 and #1e293b in HSL space
    // gives a perceptually-cleaner ramp than RGB lerp.
    const startL = 96, endL = 22
    const l = startL - (startL - endL) * Math.sqrt(f)
    return `hsl(217, 33%, ${l}%)`
  }
}
